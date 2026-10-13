variable "org_name" {
  type        = string
  description = "KubeOrg name. Passed to the gcp module."
}

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID. Passed to the gcp module."
}

variable "gcp_project_number" {
  type        = string
  description = "GCP project number. Passed to the gcp module."
}

variable "zitadel_issuer" {
  type        = string
  description = "Zitadel OIDC issuer URL. Passed to the gcp module."
}

variable "broker_app_client_id" {
  type        = string
  description = "Broker-app clientId (the WIF allowed audience). Passed to the gcp module."
}

variable "attribute_condition" {
  type        = string
  default     = null
  description = "Optional CEL condition on the WIF provider. Passed to the gcp module."
}
