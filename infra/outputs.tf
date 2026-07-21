output "project_id" {
  value = google_project.test.project_id
}

output "project_number" {
  value = data.google_project.test.number
}

output "region" {
  value = var.region
}

output "policy_bucket" {
  value = google_storage_bucket.policy.name
}

output "staging_bucket" {
  value = google_storage_bucket.agent_staging.name
}

output "policy_object_uri" {
  value = "gs://${google_storage_bucket.policy.name}/${google_storage_bucket_object.policy_handbook.name}"
}

output "data_store_id" {
  value = google_discovery_engine_data_store.hr_policy.data_store_id
}

output "data_store_name" {
  value = google_discovery_engine_data_store.hr_policy.name
}

output "search_engine_name" {
  value = google_discovery_engine_search_engine.hr_policy.name
}

output "mcp_secret_name" {
  value = google_secret_manager_secret.mcp_token.name
}

output "ingress_model_armor_template" {
  value = google_model_armor_template.ingress.name
}

output "egress_model_armor_template" {
  value = google_model_armor_template.egress.name
}
