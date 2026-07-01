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

variable "github_app_installation_id" {
  type        = string
  default     = ""
  description = "Dedicated GitHub App installation ID for this org. Staged alongside github_app_id so ESO consumers (ArgoCD repo-creds/push-creds) can resolve it; without it the ExternalSecret sync fails atomically."
}

variable "github_app_private_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Dedicated GitHub App private key (PEM). Staged alongside github_app_id in GCP Secret Manager."
}

variable "enable_meluxina_ssh_key" {
  type        = bool
  default     = false
  description = "Stage the Meluxina HPC SSH key in GCP Secret Manager under the deterministic, org-independent id 'meluxina-ssh-key'. Default false (opt-in). When true, meluxina_ssh_key_path must point at the signed private key file; its raw bytes are pushed as the secret value (write-only, never persisted in state)."
}

variable "meluxina_ssh_key_path" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Absolute path to the signed Meluxina private key file (RSA/ed25519). Read via file() and pushed verbatim as the 'meluxina-ssh-key' secret value. Required when enable_meluxina_ssh_key is true; ignored otherwise."
}

variable "enable_cost_export" {
  type        = bool
  default     = false
  description = "Provision the deterministic cost-export footprint: enable the BigQuery API, create the kaos_billing_export dataset, and grant the org ESO service account read + job access so the in-client KAOS billing reader can query cost actuals. Default false — the footprint is inert until the billing-account metrics-consumption path is built (FUTURE WORK; the Cloud Billing -> BigQuery export that populates the dataset is a Console-only billing-admin step with no API/Terraform resource, so the dataset stays empty on its own). Set true to opt in to the footprint once that path exists."
}

variable "billing_export_location" {
  type        = string
  default     = "EU"
  description = "BigQuery location for the kaos_billing_export dataset (e.g. \"EU\", \"US\", or a region). Default \"EU\" for EU data residency. The Cloud Billing export target dataset must match a location BigQuery billing export supports."
}
