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

# ==============================================================================
# 🔒 Cloud Armor WAF (Web Application Firewall)
# ==============================================================================
resource "google_compute_security_policy" "armor_policy" {
  name        = "${var.project_name}-armor-policy"
  description = "Cloud Armor Security Policy with OWASP Top 10 Protections"
  project     = var.project_id

  # Default rule: Allow all traffic
  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default rule, allows all traffic"
  }

  # Rule 1: SQL Injection Protection
  rule {
    action   = "deny(403)"
    priority = "1000"
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "OWASP SQL Injection preconfigured mitigation rule"
  }

  # Rule 2: Cross-Site Scripting (XSS) Protection
  rule {
    action   = "deny(403)"
    priority = "1010"
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "OWASP XSS preconfigured mitigation rule"
  }

  # Rule 3: Remote Code Execution (RCE) and Local File Inclusion (LFI)
  rule {
    action   = "deny(403)"
    priority = "1020"
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('rce-v33-stable') || evaluatePreconfiguredExpr('lfi-v33-stable')"
      }
    }
    description = "OWASP RCE and LFI preconfigured mitigation rules"
  }
}

# ==============================================================================
# 🌐 Global HTTP(S) Load Balancer & Serverless NEG Integration
# ==============================================================================

# 1. Allocate a global static IP address for the load balancer
resource "google_compute_global_address" "lb_ip" {
  name    = "${var.project_name}-lb-ip"
  project = var.project_id
}

# 2. Create the Serverless Network Endpoint Group (NEG) targeting Cloud Run
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "${var.project_name}-serverless-neg"
  project               = var.project_id
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.app.name
  }
}

# 3. Create the Global Backend Service linked to Serverless NEG & protected by Cloud Armor WAF
resource "google_compute_backend_service" "lb_backend" {
  name                  = "${var.project_name}-backend-service"
  project               = var.project_id
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.armor_policy.id

  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# 4. Create the global URL Map to route inbound traffic to backend
resource "google_compute_url_map" "url_map" {
  name            = "${var.project_name}-url-map"
  project         = var.project_id
  default_service = google_compute_backend_service.lb_backend.id
}

# 5. Create HTTP Target Proxy
resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "${var.project_name}-http-proxy"
  project = var.project_id
  url_map = google_compute_url_map.url_map.id
}

# 6. Global Forwarding Rule for HTTP (Port 80)
resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  name                  = "${var.project_name}-http-forwarding"
  project               = var.project_id
  target                = google_compute_target_http_proxy.http_proxy.id
  port_range            = "80"
  ip_address            = google_compute_global_address.lb_ip.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# ==============================================================================
# 🔐 (Optional) Google-Managed HTTPS Configuration (Port 443)
# To use this, create a DNS A-record pointing your custom domain to the IP
# returned in `load_balancer_ip_address` output, then uncomment the resources below!
# ==============================================================================

# variable "custom_domain" {
#   type        = string
#   description = "Your verified custom domain for SSL mapping (e.g. travel-nearby.duckdns.org)"
#   default     = "travel-nearby.duckdns.org"
# }

# resource "google_compute_managed_ssl_certificate" "google_ssl" {
#   name    = "${var.project_name}-google-managed-ssl"
#   project = var.project_id

#   managed {
#     domains = [var.custom_domain]
#   }
# }

# resource "google_compute_target_https_proxy" "https_proxy" {
#   name             = "${var.project_name}-https-proxy"
#   project          = var.project_id
#   url_map          = google_compute_url_map.url_map.id
#   ssl_certificates = [google_compute_managed_ssl_certificate.google_ssl.id]
# }

# resource "google_compute_global_forwarding_rule" "https_forwarding_rule" {
#   name                  = "${var.project_name}-https-forwarding"
#   project               = var.project_id
#   target                = google_compute_target_https_proxy.https_proxy.id
#   port_range            = "443"
#   ip_address            = google_compute_global_address.lb_ip.address
#   load_balancing_scheme = "EXTERNAL_MANAGED"
# }
