variable "org_name" {
  type        = string
  description = "KubeOrg name == org namespace (invariant D-10)."
  validation {
    # CON-AZ-01: <=17 chars so the Key Vault name {org}-{6-char hash} stays <=24 (Azure limit).
    condition     = length(var.org_name) <= 17 && can(regex("^[a-z][a-z0-9-]{0,15}[a-z0-9]$", var.org_name))
    error_message = "org_name must be <=17 chars, lowercase alnum/hyphen, start+end alnum (CON-AZ-01: KV name {org}-{hash6} <= 24)."
  }
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription UUID where org infrastructure is provisioned."
}

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant UUID of the subscription."
}

variable "location" {
  type        = string
  default     = "westeurope"
  description = "Azure region for the org bootstrap resources (RG, UAMIs, Key Vault)."
}

variable "zitadel_issuer" {
  type        = string
  default     = "https://access.platform.kaos-labs.org"
  description = "Zitadel OIDC issuer URL (prod)."
}

variable "broker_app_client_id" {
  type        = string
  description = "Shared broker-app clientId = the FIC allowed audience (from the KAOS dashboard)."
}

variable "github_app_id" {
  type        = string
  default     = ""
  description = "Dedicated GitHub App ID. When empty, no GitHub App secret is staged (shared-app org)."
}

variable "github_app_installation_id" {
  type        = string
  default     = ""
  description = "Dedicated GitHub App installation ID for this org; without it the ExternalSecret sync fails atomically."
}

variable "github_app_private_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Dedicated GitHub App private key (PEM). Staged write-only in the org Key Vault."
}

variable "key_vault_name_override" {
  type        = string
  default     = ""
  description = "Override the deterministic KV name ({org}-{sha256(subscriptionId)[0:6]}) only to escape a global-name/purge-lock collision. MUST then also be overridden platform-side; leave empty normally."
}
