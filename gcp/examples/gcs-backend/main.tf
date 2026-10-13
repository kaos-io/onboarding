# Run the gcp onboarding module with its state in a GCS bucket instead of a local file.
#
# This is an opt-in wrapper. The gcp/ module itself declares no backend, so onboard.sh
# and every existing onboarding keep their local state and are not affected.
#
# The backend block is partial on purpose: the bucket and prefix come from a
# *.gcs.tfbackend file at init time, so one wrapper serves any org:
#
#   terraform init -backend-config=kaos-io-dev.gcs.tfbackend
terraform {
  required_version = ">= 1.7.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.23, < 7.0"
    }
  }
}

module "kaos_onboarding" {
  source = "../.."

  org_name             = var.org_name
  gcp_project_id       = var.gcp_project_id
  gcp_project_number   = var.gcp_project_number
  zitadel_issuer       = var.zitadel_issuer
  broker_app_client_id = var.broker_app_client_id
  attribute_condition  = var.attribute_condition
}

output "onboarding" {
  value = {
    wif_pool_id         = module.kaos_onboarding.wif_pool_id
    wif_principal       = module.kaos_onboarding.wif_principal
    zitadel_sub         = module.kaos_onboarding.zitadel_sub
    crossplane_sa_email = module.kaos_onboarding.crossplane_sa_email
    eso_sa_email        = module.kaos_onboarding.eso_sa_email
    dns_sa_email        = module.kaos_onboarding.dns_sa_email
    node_sa_email       = module.kaos_onboarding.node_sa_email
    gke_sa_email        = module.kaos_onboarding.gke_sa_email
    ci_sa_email         = module.kaos_onboarding.ci_sa_email
  }
}
