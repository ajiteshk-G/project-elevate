locals {
  required_services = toset([
    "agentregistry.googleapis.com",
    "aiplatform.googleapis.com",
    "apphub.googleapis.com",
    "apptopology.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudapiregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudtrace.googleapis.com",
    "compute.googleapis.com",
    "dataform.googleapis.com",
    "discoveryengine.googleapis.com",
    "dlp.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamconnectors.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "modelarmor.googleapis.com",
    "monitoring.googleapis.com",
    "networksecurity.googleapis.com",
    "networkservices.googleapis.com",
    "notebooks.googleapis.com",
    "observability.googleapis.com",
    "secretmanager.googleapis.com",
    "securitycenter.googleapis.com",
    "saasservicemgmt.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "telemetry.googleapis.com",
    "texttospeech.googleapis.com",
  ])

  audit_services = toset([
    "aiplatform.googleapis.com",
    "discoveryengine.googleapis.com",
    "modelarmor.googleapis.com",
    "networkservices.googleapis.com",
    "secretmanager.googleapis.com",
  ])
}

resource "google_project" "test" {
  project_id          = var.project_id
  name                = var.project_name
  org_id              = var.organization_id
  billing_account     = var.billing_account
  auto_create_network = false
  labels              = var.labels
  deletion_policy     = "DELETE"
}

resource "google_project_service" "required" {
  for_each = local.required_services

  project            = google_project.test.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "test" {
  project_id = google_project.test.project_id

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "policy" {
  project                     = google_project.test.project_id
  name                        = "${google_project.test.project_id}-hr-policy"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = var.labels

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "agent_staging" {
  project                     = google_project.test.project_id
  name                        = "${google_project.test.project_id}-agent-staging"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = var.labels

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket_object" "policy_handbook" {
  name         = "approved/altostrat-singapore-employee-policy-handbook.pdf"
  bucket       = google_storage_bucket.policy.name
  source       = "${path.module}/../project-specs/ALTOSTRAT SINGAPORE EMPLOYEE POLICY HANDBOOK & CONDUCT GUIDELINES.pdf"
  content_type = "application/pdf"
}

resource "google_secret_manager_secret" "mcp_token" {
  project   = google_project.test.project_id
  secret_id = "external-mcp-token"
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_discovery_engine_data_store" "hr_policy" {
  project                      = google_project.test.project_id
  location                     = var.data_store_location
  data_store_id                = "hr-policy-data-store"
  display_name                 = "HR Policy Data Store"
  industry_vertical            = "GENERIC"
  content_config               = "CONTENT_REQUIRED"
  solution_types               = ["SOLUTION_TYPE_SEARCH"]
  create_advanced_site_search  = false
  skip_default_schema_creation = false
  deletion_policy              = "DELETE"

  lifecycle {
    ignore_changes = [document_processing_config]
  }

  depends_on = [google_project_service.required]
}

resource "google_discovery_engine_search_engine" "hr_policy" {
  project           = google_project.test.project_id
  location          = var.data_store_location
  collection_id     = "default_collection"
  engine_id         = "hr-policy-search"
  display_name      = "HR Policy Enterprise Search"
  industry_vertical = "GENERIC"
  data_store_ids    = [google_discovery_engine_data_store.hr_policy.data_store_id]
  disable_analytics = false
  deletion_policy   = "DELETE"

  search_engine_config {
    search_tier    = "SEARCH_TIER_ENTERPRISE"
    search_add_ons = ["SEARCH_ADD_ON_LLM"]
  }

  common_config {
    company_name = "AltoStrat"
  }
}

resource "google_model_armor_template" "ingress" {
  project     = google_project.test.project_id
  location    = var.region
  template_id = "hr-agent-ingress"
  labels      = var.labels

  filter_config {
    rai_settings {
      dynamic "rai_filters" {
        for_each = toset(["HATE_SPEECH", "HARASSMENT", "DANGEROUS", "SEXUALLY_EXPLICIT"])
        content {
          filter_type      = rai_filters.value
          confidence_level = "MEDIUM_AND_ABOVE"
        }
      }
    }

    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }

    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "MEDIUM_AND_ABOVE"
    }

    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
  }

  template_metadata {
    enforcement_type                         = "INSPECT_AND_BLOCK"
    log_template_operations                  = true
    log_sanitize_operations                  = true
    ignore_partial_invocation_failures       = false
    custom_prompt_safety_error_code          = 400
    custom_prompt_safety_error_message       = "Request blocked by enterprise AI safety policy."
    custom_llm_response_safety_error_code    = 500
    custom_llm_response_safety_error_message = "Response blocked by enterprise AI safety policy."
    multi_language_detection {
      enable_multi_language_detection = true
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_model_armor_template" "egress" {
  project     = google_project.test.project_id
  location    = var.region
  template_id = "hr-agent-egress"
  labels      = var.labels

  filter_config {
    rai_settings {
      dynamic "rai_filters" {
        for_each = toset(["HATE_SPEECH", "HARASSMENT", "DANGEROUS", "SEXUALLY_EXPLICIT"])
        content {
          filter_type      = rai_filters.value
          confidence_level = "MEDIUM_AND_ABOVE"
        }
      }
    }

    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }

    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "MEDIUM_AND_ABOVE"
    }

    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
  }

  template_metadata {
    enforcement_type                         = "INSPECT_AND_BLOCK"
    log_template_operations                  = true
    log_sanitize_operations                  = true
    ignore_partial_invocation_failures       = false
    custom_prompt_safety_error_code          = 400
    custom_prompt_safety_error_message       = "Tool request blocked by enterprise AI safety policy."
    custom_llm_response_safety_error_code    = 502
    custom_llm_response_safety_error_message = "Tool response blocked by enterprise AI safety policy."
    multi_language_detection {
      enable_multi_language_detection = true
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_project_iam_audit_config" "data_access" {
  for_each = local.audit_services

  project = google_project.test.project_id
  service = each.value

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }

  depends_on = [google_project_service.required]
}

locals {
  gateway_service_agent = "serviceAccount:service-${data.google_project.test.number}@gcp-sa-dep.iam.gserviceaccount.com"
  runtime_service_agent = "serviceAccount:service-${data.google_project.test.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"

  model_armor_bindings = {
    "gateway-callout"  = { member = local.gateway_service_agent, role = "roles/modelarmor.calloutUser" }
    "gateway-user"     = { member = local.gateway_service_agent, role = "roles/modelarmor.user" }
    "gateway-consumer" = { member = local.gateway_service_agent, role = "roles/serviceusage.serviceUsageConsumer" }
    "runtime-callout"  = { member = local.runtime_service_agent, role = "roles/modelarmor.calloutUser" }
    "runtime-user"     = { member = local.runtime_service_agent, role = "roles/modelarmor.user" }
  }
}

resource "google_project_iam_member" "model_armor" {
  for_each = var.enable_platform_service_agent_bindings ? local.model_armor_bindings : {}

  project = google_project.test.project_id
  member  = each.value.member
  role    = each.value.role

  depends_on = [
    google_model_armor_template.ingress,
    google_model_armor_template.egress,
  ]
}

locals {
  governed_google_endpoints = {
    "vertex-ai-regional" = {
      display_name = "${var.region}-aiplatform.googleapis.com"
      url          = "https://${var.region}-aiplatform.googleapis.com"
    }
    "vertex-ai-regional-mtls" = {
      display_name = "${var.region}-aiplatform.mtls.googleapis.com"
      url          = "https://${var.region}-aiplatform.mtls.googleapis.com"
    }
    "vertex-ai-global" = {
      display_name = "aiplatform.googleapis.com"
      url          = "https://aiplatform.googleapis.com"
    }
    "vertex-ai-global-mtls" = {
      display_name = "aiplatform.mtls.googleapis.com"
      url          = "https://aiplatform.mtls.googleapis.com"
    }
    "discovery-engine" = {
      display_name = "discoveryengine.googleapis.com"
      url          = "https://discoveryengine.googleapis.com"
    }
    "discovery-engine-mtls" = {
      display_name = "discoveryengine.mtls.googleapis.com"
      url          = "https://discoveryengine.mtls.googleapis.com"
    }
    "secret-manager" = {
      display_name = "secretmanager.googleapis.com"
      url          = "https://secretmanager.googleapis.com"
    }
    "secret-manager-mtls" = {
      display_name = "secretmanager.mtls.googleapis.com"
      url          = "https://secretmanager.mtls.googleapis.com"
    }
    "telemetry" = {
      display_name = "telemetry.googleapis.com"
      url          = "https://telemetry.googleapis.com"
    }
    "telemetry-mtls" = {
      display_name = "telemetry.mtls.googleapis.com"
      url          = "https://telemetry.mtls.googleapis.com"
    }
    "cloud-resource-manager" = {
      display_name = "cloudresourcemanager.googleapis.com"
      url          = "https://cloudresourcemanager.googleapis.com"
    }
    "cloud-resource-manager-mtls" = {
      display_name = "cloudresourcemanager.mtls.googleapis.com"
      url          = "https://cloudresourcemanager.mtls.googleapis.com"
    }
  }
}

resource "google_agent_registry_service" "google_endpoint" {
  for_each = local.governed_google_endpoints

  project      = google_project.test.project_id
  location     = var.region
  service_id   = each.key
  display_name = each.value.display_name
  description  = "Google API endpoint approved for governed HR Agent egress."

  interfaces {
    url              = each.value.url
    protocol_binding = "HTTP_JSON"
  }

  endpoint_spec {
    type = "NO_SPEC"
  }

  depends_on = [google_project_service.required]
}
