# Plan-time assertions. The google provider is mocked, so no credentials are
# needed and nothing is created. Run from gcp/: terraform init -backend=false && terraform test
#
# NOTE: the mocked provider plans against an empty state, so it cannot exercise the
# `removed { from = google_project_service.secretmanager }` /
# `removed { from = google_secret_manager_secret[_version].meluxina_ssh_key }` blocks in
# main.tf — there is nothing at those addresses to remove. Zero-destroy behavior against a
# real onboarded state that still holds those addresses is asserted in Task 3's real
# `terraform plan` run, not here.
mock_provider "google" {}

variables {
  org_name             = "acme"
  gcp_project_id       = "acme-prod"
  gcp_project_number   = "123456789012"
  broker_app_client_id = "376257051585676814"
}

run "secret_manager_api_is_always_enabled" {
  command = plan

  assert {
    condition     = contains(keys(google_project_service.required), "secretmanager.googleapis.com")
    error_message = "secretmanager.googleapis.com must be in local.required_apis: KAOS writes user-managed secrets to every org's Secret Manager, not only owned-app orgs."
  }
}

run "golden_vectors_unchanged" {
  command = plan

  assert {
    condition     = output.zitadel_sub == "ad262e82-8256-5e2e-899e-3d8c40832b54"
    error_message = "zitadel_sub parity with the operator's DeterministicUserID(\"acme\") broke."
  }

  assert {
    condition     = output.wif_pool_id == "acme-kaosid"
    error_message = "wif_pool_id parity with WIFPoolName(\"acme\") broke."
  }
}
