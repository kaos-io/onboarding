locals {
  # Must match internal/operators/kubeorg/phases/reconciling.go DeterministicUserID():
  # UUIDv5(namespace=7b3f9d2c-1e84-4a6b-9c5d-2f8a0e6b4d13, org_name)
  # Parity check: org "acme" -> ad262e82-8256-5e2e-899e-3d8c40832b54
  # A change to this namespace or to DeterministicUserID()'s UUIDv5 call MUST be mirrored on both sides.
  zitadel_sub = uuidv5("7b3f9d2c-1e84-4a6b-9c5d-2f8a0e6b4d13", var.org_name)

  # Names MUST match the azureprovider composition (it observes these objects):
  #   RG:   crossplane.io/external-name "rg-kaos-{org}"
  #   UAMI: forProvider.name "{org}-eso-uami"
  #   KV:   external-name "{org}-{sha256(subscriptionId)|trunc6}" (CON-AZ-01, revised 2026-05-01)
  rg_name              = "rg-kaos-${var.org_name}"
  crossplane_uami_name = "${var.org_name}-crossplane"
  eso_uami_name        = "${var.org_name}-eso-uami"
  kv_name              = var.key_vault_name_override != "" ? var.key_vault_name_override : "${var.org_name}-${substr(sha256(var.subscription_id), 0, 6)}"

  # Secret id MUST match buildXGithubProviderParameters(): {org}-github-provider-credentials
  github_secret_name = "${var.org_name}-github-provider-credentials"
  stage_github_app   = var.github_app_id != ""
}

resource "azurerm_resource_group" "org" {
  name     = local.rg_name
  location = var.location
  tags = {
    Organization = var.org_name
    ManagedBy    = "kaos-onboarding"
    Purpose      = "org-foundation"
  }
}

# Standing provisioning identity — infra only. No role-assignment / identity power
# beyond the single resource-scoped FIC-writer grant on the ESO UAMI (Task 3).
resource "azurerm_user_assigned_identity" "crossplane" {
  name                = local.crossplane_uami_name
  location            = var.location
  resource_group_name = azurerm_resource_group.org.name
  tags = {
    Organization = var.org_name
    ManagedBy    = "kaos-onboarding"
    Purpose      = "crossplane-provisioning"
  }
}

# The Zitadel org machine user (sub = local.zitadel_sub) federates into this UAMI.
# Audience is the SHARED broker clientId (aud=broker, sub=per-org — PRD-352 trust model);
# the legacy per-org audience kubecore-{org}-xcloud is retired.
resource "azurerm_federated_identity_credential" "crossplane_zitadel" {
  name                = "kubecore-${var.org_name}-zitadel"
  resource_group_name = azurerm_resource_group.org.name
  parent_id           = azurerm_user_assigned_identity.crossplane.id
  issuer              = var.zitadel_issuer
  subject             = local.zitadel_sub
  audience            = [var.broker_app_client_id]
}

# ESO workload identity. Its FIC is NOT created here: the FIC subject is
# system:serviceaccount:{org}:{org}-eso-sa against the CONTROL-PLANE OIDC issuer,
# which is platform-side and changes on control-plane migration — the azureprovider
# composition owns it (same rationale as GCP's composition-owned WI bindings, PR #550).
resource "azurerm_user_assigned_identity" "eso" {
  name                = local.eso_uami_name
  location            = var.location
  resource_group_name = azurerm_resource_group.org.name
  tags = {
    Organization = var.org_name
    ManagedBy    = "kaos-onboarding"
    Purpose      = "ESO-WIF"
  }
}

# TF-owned so the dedicated GitHub App key stages single-pass at onboarding (GSM parity).
# Field values MUST match the azureprovider composition's (now observed) Vault:
# RBAC authorization, purge protection ON, 7-day soft delete, sku standard.
resource "azurerm_key_vault" "org" {
  name                       = local.kv_name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.org.name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  tags = {
    Organization = var.org_name
    ManagedBy    = "kaos-onboarding"
    Purpose      = "org-secrets"
  }
}

# The onboarding runner needs data-plane write to stage the secret (RBAC mode).
resource "azurerm_role_assignment" "runner_kv_officer" {
  scope                = azurerm_key_vault.org.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault_secret" "github_app" {
  count        = local.stage_github_app ? 1 : 0
  name         = local.github_secret_name
  key_vault_id = azurerm_key_vault.org.id
  content_type = "application/json"
  # Write-only: sent to Azure, never persisted in Terraform state (GSM secret_data_wo parity).
  value_wo = jsonencode({
    appId          = var.github_app_id
    installationId = var.github_app_installation_id
    privateKey     = var.github_app_private_key
  })
  value_wo_version = 1
  depends_on       = [azurerm_role_assignment.runner_kv_officer]
}

# ---------------------------------------------------------------------------
# Least-priv grants (replaces the legacy subscription-scope Owner).
# All crossplane provisioning grants scoped to the org RG (rg-kaos-{org}).
# Network+AKS+DNS all create their resources IN this RG (post-A4 compositions);
# nothing creates a resource group, so no subscription scope and no rg-lifecycle role.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "crossplane_network_rg" {
  scope                = azurerm_resource_group.org.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.crossplane.principal_id
}

resource "azurerm_role_assignment" "crossplane_dns_rg" {
  scope                = azurerm_resource_group.org.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.crossplane.principal_id
}

# NODE-RG CAVEAT: AKS auto-creates a `MC_*` node resource group outside rg-kaos-{org}.
# Whether the crossplane identity needs any permission there to create the cluster is
# UNKNOWN and settled only by the live A-4d test. This grant is RG-scoped only
# (aspirational zero-subscription end-state); if A-4d shows AuthorizationFailed on the
# node RG, a follow-up will add the minimal grant there. Do not pre-emptively widen this.
resource "azurerm_role_assignment" "crossplane_aks_rg" {
  scope                = azurerm_resource_group.org.id
  role_definition_name = "Azure Kubernetes Service Contributor Role"
  principal_id         = azurerm_user_assigned_identity.crossplane.principal_id
}

# KV is Observe-only (crossplane never writes it) but Observe still needs vaults/read,
# which the Contributor roles above don't cover. Reader @ RG grants */read incl. KV read.
# (Live-verify in A-4d that Reader satisfies provider-azure's Observe GET; if a narrower
#  "Key Vault Reader" is preferred, swap the role name — same scope.)
resource "azurerm_role_assignment" "crossplane_reader_rg" {
  scope                = azurerm_resource_group.org.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.crossplane.principal_id
}

# FIC-writer: composition manages the ESO FIC on this ONE identity (wi_binder analogue).
resource "azurerm_role_assignment" "crossplane_eso_fic_writer" {
  scope                = azurerm_user_assigned_identity.eso.id
  role_definition_name = "Managed Identity Contributor"
  principal_id         = azurerm_user_assigned_identity.crossplane.principal_id
}

# ESO data-plane: read/write org secrets in the org KV (resource-scoped).
resource "azurerm_role_assignment" "eso_kv_officer" {
  scope                = azurerm_key_vault.org.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}

# DNS record management for the org zone (zone lives in the org RG; RG scope).
resource "azurerm_role_assignment" "eso_dns_contributor" {
  scope                = azurerm_resource_group.org.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}
