# Cloud Production Deployment & Roadmap 🚀

This document details the blueprint for deploying the Multi-Agent Travel Assistant to Google Cloud as a robust, secure, and production-grade web application, followed by a future engineering enhancement roadmap.

---

## 🏗️ Google Cloud Production Architecture

Deploying an ADK multi-agent system to production requires securing the ingress paths, managing authentication, and scaling dynamically. Below is the blueprint for a standard production-grade deployment on GCP.

```mermaid
graph LR
    DNS([Custom Domain]) --> LB[Global HTTPS Load Balancer]
    
    %% Security Layer
    LB --> Armor[Google Cloud Armor WAF]
    LB --> IAP[Identity-Aware Proxy / IAP]
    
    %% Backend compute
    IAP --> NEG[Serverless NEG]
    NEG --> Run[Google Cloud Run Container]
    
    %% Storage & Telemetry
    Run --> BQ[(BigQuery Telemetry)]
    Run --> Secret[GCP Secret Manager]
```

---

## 🚀 Step-by-Step Production Deployment Guide

### 📦 Phase 1: Containerizing the Application
1.  Create a production-ready `Dockerfile` in your project root:
    ```dockerfile
    FROM python:3.11-slim
    
    # Install dependencies
    WORKDIR /app
    RUN pip install uv
    COPY pyproject.toml uv.lock ./
    RUN uv pip install --system --no-cache-dir -r pyproject.toml
    
    # Copy project files
    COPY . .
    
    # Expose Fast-API app port (standard is 8080)
    EXPOSE 8080
    CMD ["uv", "run", "fastapi", "run", "app/fast_api_app.py", "--port", "8080"]
    ```

### 🚢 Phase 2: Deploying to Google Cloud Run
1.  Build and push your container image using **Google Cloud Build** or **Artifact Registry**:
    ```bash
    gcloud builds submit --tag gcr.io/YOUR_PROJECT_ID/travel-agent:latest
    ```
2.  Deploy the service to **Google Cloud Run**:
    *   **Route A (Fully Public Website)**:
        ```bash
        gcloud run deploy temp-mcp-agent \
            --image gcr.io/YOUR_PROJECT_ID/travel-agent:latest \
            --region us-east1 \
            --allow-unauthenticated
        ```
    *   **Route B (Secure Enterprise Sandbox behind Load Balancer)**:
        ```bash
        gcloud run deploy temp-mcp-agent \
            --image gcr.io/YOUR_PROJECT_ID/travel-agent:latest \
            --region us-east1 \
            --no-allow-unauthenticated
        ```

### 🌐 Phase 3: Setting Up Global Load Balancing & Custom Domains
To map a free custom domain (e.g., DuckDNS) to your application with free, Google-managed SSL certificate protection:

1.  Create a **Serverless Network Endpoint Group (NEG)** targeting your Cloud Run service:
    ```bash
    gcloud compute network-endpoint-groups create travel-neg \
        --region=us-east1 \
        --network-endpoint-type=SERVERLESS \
        --cloud-run-service=temp-mcp-agent
    ```
2.  Create a global **Compute Backend Service** and add the NEG:
    ```bash
    gcloud compute backend-services create travel-backend --global
    gcloud compute backend-services add-backend travel-backend \
        --global \
        --network-endpoint-group=travel-neg \
        --network-endpoint-group-region=us-east1
    ```
3.  Set up an **SSL Certificate** for your custom domain:
    ```bash
    gcloud compute ssl-certificates create travel-duck-cert \
        --domains=travel-nearby.duckdns.org --global
    ```
4.  Configure your **URL Map**, **Target HTTPS Proxy**, and **Global Forwarding Rule** to route incoming load balancer traffic.
5.  Point your **DuckDNS sub-domain** to the public external IP of the global forwarding rule. The SSL certificate will transition from `PROVISIONING` to `ACTIVE` automatically!

---

## 🔒 Enterprise Security Hardening (Real-World Case Study)

When deploying inside corporate, multi-tenant GCP organizations, several security constraints govern resource accessibility. Below are key security integration patterns implemented during our project design:

### 1. Google Cloud Armor (WAF Protection)
Protect your load balancer backend from common web application exploits (OWASP Top 10) by configuring a Cloud Armor security policy:
```bash
gcloud compute security-policies create travel-armor-policy
```
Add standard pre-configured rules to block SQL Injection (SQLi), Cross-Site Scripting (XSS), and Remote Code Execution (RCE/LFI):
*   *SQLi block (Priority 2000)*: `evaluatePreconfiguredExpr('sqli-v33-stable')`
*   *XSS block (Priority 2010)*: `evaluatePreconfiguredExpr('xss-v33-stable')`

### 2. Identity-Aware Proxy (IAP) & Organization Policy Isolation
Enterprise projects often restrict anonymous internet ingress via organization policy constraints such as **`constraints/iam.allowedPolicyMemberDomains`**. This explicitly blocks granting the `run.invoker` role to `allUsers` (the general public) and restricts account additions to approved domains.

To bypass this safely and permit secure, authorized access for corporate employees:
1.  **Enable IAP** on your backend service:
    ```bash
    gcloud compute backend-services update travel-backend --iap=enabled --global
    ```
2.  **Apply Granular Backend IAM Bindings**: Grant the `roles/iap.httpsResourceAccessor` role specifically to the backend service resource rather than at the project root level to enforce the principle of least privilege:
    ```bash
    gcloud iap web add-iam-policy-binding \
        --resource-type=backend-services \
        --service=travel-backend \
        --member="user:employee@yourdomain.com" \
        --role="roles/iap.httpsResourceAccessor"
    ```
3.  **OAuth Consent Screen Domain Isolation**: Note that if the project's parent organization is a partner/support domain (such as `telus.premium-cloud-support.com`) and the IAP OAuth Brand is set to `orgInternalOnly: true`, identities outside that specific G-Suite workspace (even `@google.com` or `@gmail.com` accounts with IAP roles) will be blocked from logging in. For public access, deployment should be isolated to an independent, personal GCP sandbox.

---

## 📈 Future Engineering Enhancements (Project Roadmap)

To expand this system from a working prototype to a highly scalable, enterprise-grade cognitive platform, the following roadmap is planned:

### 1. Distributed State & Multi-Session Persistence (Scalability)
*   **Problem**: The current ADK prototype uses local, in-memory session tracking. When autoscaling multiple Cloud Run instances, requests from the same user session hitting different instances will lose conversational context.
*   **Enhancement**: Integrate **Google Cloud Memorystore (Redis)** as a fast, centralized cache layer to store active agent session trees and state parameters.
*   **Database**: Set up **Cloud Spanner** or **Cloud SQL (PostgreSQL)** to persist historical transaction threads and analytical reporting over time across regions.

### 2. Retrieval-Augmented Generation (RAG) Integration
*   **Problem**: The travel assistant currently relies on real-time web scrapers and external REST APIs, which are highly volatile and rate-limited.
*   **Enhancement**: Establish a **Vertex AI Agent Builder Datastore** (Search and Vector Search) pre-populated with curated regional travel catalogs, airline schedules, and PDF brochures. 
*   **Execution**: Connect the datastore tool directly to the `activities_travel_agent` to ground suggestions in verified, cached corporate travel repositories.

### 3. Automated CI/CD Pipeline (DevOps)
*   **Enhancement**: Configure a **GitHub Actions workflow** or **Google Cloud Build trigger** that fires on every git merge.
*   **Pipeline Tasks**:
    1.  Lints code format with `ruff` and runs type validation with `mypy`.
    2.  Executes local unit tests with `pytest`.
    3.  Automates systematic quality checks by triggering the `agents-cli eval run` suite.
    4.  Builds the container image, publishes it to Artifact Registry, and deploys it as a revision to Cloud Run upon successful evaluation scores.
