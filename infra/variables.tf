variable "project_id" {
  description = "Globally unique test project ID."
  type        = string
}

variable "project_name" {
  description = "Human-readable test project name."
  type        = string
  default     = "M3 HR Agent Test"
}

variable "organization_id" {
  description = "Google Cloud organization ID."
  type        = string
  default     = "284355623615"
}

variable "billing_account" {
  description = "Billing account ID attached to the isolated test project."
  type        = string
  default     = "01A926-85D162-ACA6CD"
}

variable "region" {
  description = "Agent Runtime, Agent Gateway, Agent Registry, and Model Armor region."
  type        = string
  default     = "us-central1"
}

variable "data_store_location" {
  description = "Vertex AI Search multi-region."
  type        = string
  default     = "global"
}

variable "labels" {
  description = "Labels applied to resources that support them."
  type        = map(string)
  default = {
    environment = "test"
    workload    = "m3-hr-agent"
    managed-by  = "terraform"
  }
}

variable "enable_platform_service_agent_bindings" {
  description = "Enable only after Agent Gateway and Agent Runtime have created their managed service identities."
  type        = bool
  default     = false
}
