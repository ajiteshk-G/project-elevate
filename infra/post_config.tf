resource "terraform_data" "policy_import" {
  triggers_replace = {
    object_md5 = google_storage_bucket_object.policy_handbook.md5hash
    data_store = google_discovery_engine_data_store.hr_policy.name
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/import_policy.sh"
    environment = {
      PROJECT_ID        = google_project.test.project_id
      DATA_STORE_ID     = google_discovery_engine_data_store.hr_policy.data_store_id
      POLICY_OBJECT_URI = "gs://${google_storage_bucket.policy.name}/${google_storage_bucket_object.policy_handbook.name}"
    }
  }
}

resource "terraform_data" "platform_bootstrap" {
  triggers_replace = {
    project_id      = google_project.test.project_id
    region          = var.region
    script_sha      = filesha256("${path.module}/../scripts/bootstrap_platform.sh")
    workweek_sha    = filesha256("${path.module}/../gateway-config/workweek-toolspec.json")
    service_now_sha = filesha256("${path.module}/../gateway-config/serviceimmediately-toolspec.json")
    gateway_config_sha = sha256(join("", [
      for filename in fileset("${path.module}/../gateway-config", "*.yaml.tmpl") :
      filesha256("${path.module}/../gateway-config/${filename}")
    ]))
    ingress_template = google_model_armor_template.ingress.name
    egress_template  = google_model_armor_template.egress.name
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/bootstrap_platform.sh"
    environment = {
      PROJECT_ID     = google_project.test.project_id
      PROJECT_NUMBER = data.google_project.test.number
      REGION         = var.region
      CONFIG_DIR     = "${path.module}/../gateway-config"
    }
  }

  depends_on = [
    google_model_armor_template.ingress,
    google_model_armor_template.egress,
  ]
}

resource "terraform_data" "agent_runtime" {
  triggers_replace = {
    agent_sha        = filesha256("${path.module}/../hr_agent/agent.py")
    guardrails_sha   = filesha256("${path.module}/../hr_agent/guardrails.py")
    requirements_sha = filesha256("${path.module}/../hr_agent/requirements.txt")
    deploy_py_sha    = filesha256("${path.module}/../scripts/deploy_agent.py")
    deploy_sh_sha    = filesha256("${path.module}/../scripts/deploy_agent.sh")
    platform_id      = terraform_data.platform_bootstrap.id
    search_engine    = google_discovery_engine_search_engine.hr_policy.name
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/deploy_agent.sh"
    environment = {
      PROJECT_ID     = google_project.test.project_id
      PROJECT_NUMBER = data.google_project.test.number
      REGION         = var.region
      STAGING_BUCKET = google_storage_bucket.agent_staging.name
      PYTHON_BIN     = "${path.module}/../.venv/bin/python"
    }
  }

  depends_on = [
    terraform_data.platform_bootstrap,
    terraform_data.policy_import,
    google_discovery_engine_search_engine.hr_policy,
  ]
}
