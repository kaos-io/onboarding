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

output "gke_sa_email" {
  value       = local.gke_sa_email
  description = "GKE-developer SA ({org}-gcp-gke-sa) holding container.developer + compute.viewer; adopted Observe-only by the gcpprovider composition and bound to the {org}-gke-sa KSA per pool."
}

output "ci_sa_email" {
  value       = local.ci_sa_email
  description = "CI push SA ({org}-gcp-ci-sa) holding artifactregistry.writer (PRD-REG-994 Phase 2). Consumed by the Phase 2 composition to create the Workload Identity binding for the CI build KSA in {project}-ci; the binding itself is created by the composition, not here, because the WI pool doesn't exist until the first GKE cluster."
}

output "gar_read_sa_email" {
  value       = local.gar_read_sa_email
  description = "GAR read SA ({org}-gcp-gar-read-sa) holding artifactregistry.reader only (kubecore-operator#1116). Impersonated via Workload Identity by the ML env's argo-workflow KSA so MeluXina submit pods can mint read-only registry tokens for off-cluster Apptainer pulls; the WI binding is created by the projectenvmlstack composition, not here."
}

output "github_app_secret_id" {
  value       = local.stage_github_app ? google_secret_manager_secret.github_app[0].secret_id : ""
  description = "GSM secret id holding the dedicated GitHub App {appId,privateKey}; empty for shared-app orgs."
}

output "meluxina_ssh_key_secret_id" {
  value       = var.enable_meluxina_ssh_key ? google_secret_manager_secret.meluxina_ssh_key[0].secret_id : ""
  description = "GSM secret id holding the Meluxina HPC SSH key ('meluxina-ssh-key'); empty when the integration is disabled."
}

output "wif_pool_id" {
  value       = local.wif_pool_id
  description = "Per-org WIF pool/provider id ({org}-kaosid). Must match the operator/broker derivation."
}

output "billing_export_dataset_id" {
  value       = var.enable_cost_export ? google_bigquery_dataset.billing_export[0].dataset_id : ""
  description = "BigQuery dataset id the in-client billing reader queries for cost actuals; empty when cost export is disabled. The system binds to this."
}
