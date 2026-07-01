output "zitadel_sub" {
  value = local.zitadel_sub
}

output "wif_principal" {
  value = local.wif_principal
}

output "crossplane_sa_email" {
  value = local.crossplane_sa_email
}

output "eso_sa_email" {
  value = local.eso_sa_email
}

output "dns_sa_email" {
  value = local.dns_sa_email
}

output "node_sa_email" {
  value = local.node_sa_email
}

output "github_app_secret_id" {
  value       = local.stage_github_app ? google_secret_manager_secret.github_app[0].secret_id : ""
  description = "GSM secret id holding the dedicated GitHub App {appId,privateKey}; empty for shared-app orgs."
}

output "wif_pool_id" {
  value       = local.wif_pool_id
  description = "Per-org WIF pool/provider id ({org}-kaosid). Must match the operator/broker derivation."
}

output "billing_export_dataset_id" {
  value       = var.enable_cost_export ? google_bigquery_dataset.billing_export[0].dataset_id : ""
  description = "BigQuery dataset id the in-client billing reader queries for cost actuals; empty when cost export is disabled. The system binds to this."
}
