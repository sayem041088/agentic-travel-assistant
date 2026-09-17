# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
import os

import google.auth
from fastapi import FastAPI
from google.adk.cli.fast_api import get_fast_api_app
from google.cloud import logging as google_cloud_logging

from app.app_utils.telemetry import setup_telemetry
from app.app_utils.typing import Feedback

setup_telemetry()
_, project_id = google.auth.default()
logging_client = google_cloud_logging.Client()
logger = logging_client.logger(__name__)
allow_origins = (
    os.getenv("ALLOW_ORIGINS", "").split(",") if os.getenv("ALLOW_ORIGINS") else None
)

# Artifact bucket for ADK (created by Terraform, passed via env var)
logs_bucket_name = os.environ.get("LOGS_BUCKET_NAME")

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# In-memory session configuration - no persistent storage
session_service_uri = None

artifact_service_uri = f"gs://{logs_bucket_name}" if logs_bucket_name else None

from fastapi import Request, HTTPException
from fastapi.responses import FileResponse
import jwt
import requests

IAP_JWKS_URL = "https://www.gstatic.com/iap/verify/public_key-jwk"
cached_public_keys = {}

def get_iap_public_key(key_id: str):
    global cached_public_keys
    if key_id not in cached_public_keys:
        try:
            response = requests.get(IAP_JWKS_URL, timeout=5)
            jwks = response.json()
            for key in jwks["keys"]:
                cached_public_keys[key["kid"]] = key
        except Exception as e:
            logger.log_struct({"error": f"Failed to fetch IAP JWKS: {str(e)}"}, severity="WARNING")
    return cached_public_keys.get(key_id)

def verify_iap_jwt(iap_jwt: str) -> dict:
    try:
        unverified_header = jwt.get_unverified_header(iap_jwt)
        kid = unverified_header.get("kid")
        public_key = get_iap_public_key(kid)
        if not public_key:
            return None
        
        # Verify ES256 signature
        decoded_token = jwt.decode(
            iap_jwt,
            public_key,
            algorithms=["ES256"],
            options={"verify_aud": False}
        )
        return decoded_token
    except Exception as e:
        logger.log_struct({"error": f"IAP JWT verification failed: {str(e)}"}, severity="WARNING")
        return None

app: FastAPI = get_fast_api_app(
    agents_dir=AGENT_DIR,
    web=True,
    artifact_service_uri=artifact_service_uri,
    allow_origins=allow_origins,
    session_service_uri=session_service_uri,
    otel_to_cloud=True,
)
app.title = "temp-mcp-agent"
app.description = "API for interacting with the Agent temp-mcp-agent"


@app.middleware("http")
async def validate_passcode_middleware(request: Request, call_next):
    # Protect only the run and feedback endpoints from anonymous queries
    if request.url.path in ["/agent/run", "/chat", "/runs", "/feedback"]:
        iap_jwt = request.headers.get("x-goog-iap-jwt-assertion")
        if iap_jwt:
            # We are running behind IAP and GCIP! Verify Google's cryptographic signature.
            user_info = verify_iap_jwt(iap_jwt)
            if not user_info:
                raise HTTPException(status_code=401, detail="Unauthorized: Invalid Google Identity Token")
            # Audit log the authenticated end-user
            logger.log_struct({
                "message": "User request authenticated via Google IAP/GCIP",
                "email": user_info.get("email"),
                "phone_number": user_info.get("phone_number"),
                "user_id": user_info.get("sub")
            }, severity="INFO")
        else:
            # Fallback to passcode for local testing & direct proxies
            passcode = request.headers.get("X-Passcode")
            if passcode != "sayem123":
                raise HTTPException(status_code=401, detail="Unauthorized: Invalid Passcode or Identity Token")
    response = await call_next(request)
    return response


@app.get("/")
def read_root():
    return FileResponse(os.path.join(AGENT_DIR, "static", "index.html"))


@app.post("/feedback")
def collect_feedback(feedback: Feedback) -> dict[str, str]:
    """Collect and log feedback.

    Args:
        feedback: The feedback data to log

    Returns:
        Success message
    """
    logger.log_struct(feedback.model_dump(), severity="INFO")
    return {"status": "success"}


# Main execution
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
