output "zitadel_sub" {
  value       = local.zitadel_sub
  description = "Deterministic Zitadel machine-user sub; must equal operator DeterministicUserID(org_name)."
}

output "crossplane_uami_client_id" {
  value       = azurerm_user_assigned_identity.crossplane.client_id
  description = "Feed into KubeOrg spec.azureConfig.clientId (OIDCTokenFile ProviderConfig)."
}

output "eso_uami_client_id" {
  value       = azurerm_user_assigned_identity.eso.client_id
  description = "ESO UAMI client id. Feed into KubeOrg spec.azureConfig.esoClientId (the composition emits it to status; both org- and child-cluster ESO consumers read it)."
}

output "tenant_id" {
  value       = var.tenant_id
  description = "Feed into KubeOrg spec.azureConfig.tenantId."
}

output "subscription_id" {
  value       = var.subscription_id
  description = "Feed into KubeOrg spec.azureConfig.subscriptionId."
}

output "resource_group_name" {
  value       = azurerm_resource_group.org.name
  description = "Org foundation RG (rg-kaos-{org}); observed by the azureprovider composition."
}

output "key_vault_name" {
  value       = azurerm_key_vault.org.name
  description = "Org Key Vault ({org}-{hash6}); observed by the azureprovider composition."
}

output "github_app_secret_name" {
  value       = local.stage_github_app ? azurerm_key_vault_secret.github_app[0].name : ""
  description = "KV secret holding the dedicated GitHub App {appId,installationId,privateKey}; empty for shared-app orgs."
}

output "aks_uami_id" {
  value       = azurerm_user_assigned_identity.aks.id
  description = "ARM id of the org AKS control-plane UAMI (the aks composition templates this literally)."
}
