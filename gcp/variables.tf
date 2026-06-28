variable "org_name" {
  type        = string
  description = "KubeOrg name == org namespace (invariant D-10). Used to derive all per-org resource names and the deterministic Zitadel sub."
  validation {
    condition     = length(var.org_name) <= 19 && can(regex("^[a-z][a-z0-9-]{0,17}[a-z0-9]$", var.org_name))
    error_message = "org_name must be <=19 chars, lowercase alnum/hyphen, start+end alnum. Bounds: SA account_id (30 - 11-char suffix = 19) and WIF pool id '{org}-kaosid' (19 + 7 = 26 <= 32)."
  }
}

variable "gcp_project_id" {
  type        = string
  description = "Client GCP project ID where org infrastructure is provisioned."
}

variable "gcp_project_number" {
  type        = string
  description = "Client GCP project NUMBER (used in the WIF principal path)."
}

variable "zitadel_issuer" {
  type        = string
  description = "Zitadel OIDC issuer URL (prod: https://access.platform.kaos-labs.org)."
  default     = "https://access.platform.kaos-labs.org"
}

variable "broker_app_client_id" {
  type        = string
  description = "Shared broker-app clientId = the WIF allowed-audience (from setup-zitadel-broker-identity.sh)."
}

variable "eso_namespace" {
  type        = string
  default     = "external-secrets"
  description = "Fixed K8s namespace of the child-cluster ESO ServiceAccount (must match the system composition)."
}

variable "external_dns_namespace" {
  type        = string
  default     = "external-dns"
  description = "Fixed K8s namespace of the child-cluster ExternalDNS ServiceAccount (must match the system composition)."
}

variable "observability_namespace" {
  type        = string
  default     = "observability"
  description = "Fixed K8s namespace of the child-cluster observability-cost exporter ServiceAccount (must match the observability-cost composition's observabilityNamespace default)."
}

variable "github_app_id" {
  type        = string
  default     = ""
  description = "Dedicated GitHub App ID. When empty, no GitHub App secret is staged (shared-app org)."
}

variable "github_app_private_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Dedicated GitHub App private key (PEM). Staged alongside github_app_id in GCP Secret Manager."
}
