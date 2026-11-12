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

run "eso_writer_can_label_but_not_delete" {
  command = plan

  assert {
    condition     = contains(google_project_iam_custom_role.eso_secret_writer.permissions, "secretmanager.secrets.update")
    error_message = "kubecoreEsoSecretWriter needs secretmanager.secrets.update: ESO PushSecret calls UpdateSecret to write the C1 kaos-* labels."
  }

  assert {
    condition = length(setintersection(google_project_iam_custom_role.eso_secret_writer.permissions, [
      "secretmanager.secrets.delete",
      "secretmanager.secrets.list",
      "secretmanager.secrets.setIamPolicy",
      "secretmanager.versions.destroy",
    ])) == 0
    error_message = "kubecoreEsoSecretWriter must stay least-privilege: no delete, list, setIamPolicy or version destroy."
  }
}

# Pending owner approval (kaos PRD 695). ESO's gcpsm provider checks existence for
# `updatePolicy: IfNotExists` by listing versions, not by getting the secret (live
# probe on 2026-09-28: PushSecret failed with "Permission 'secretmanager.versions.list'
# denied"). Used by the operator's override-slot placeholders.
run "eso_writer_can_list_versions_for_ifnotexists" {
  command = plan

  assert {
    condition     = contains(google_project_iam_custom_role.eso_secret_writer.permissions, "secretmanager.versions.list")
    error_message = "kubecoreEsoSecretWriter needs secretmanager.versions.list: ESO's gcpsm PushSecret checks existence for updatePolicy: IfNotExists by listing versions."
  }
}

# PRD 1533 F-52: the OSR Cloud Logging footprint is opt-in.
run "osr_cloud_logging_off_by_default" {
  command = plan

  assert {
    condition = (length(google_service_account.osr) == 0 && length(google_logging_log_view.osr_k8s) == 0
      && length(google_logging_log_view_iam_member.osr_view_accessor) == 0
      && length(google_service_account_iam_member.crossplane_wi_binder_osr) == 0
      && length(google_service_account_iam_member.operator_view_osr) == 0
    && length(google_project_service.osr_logging) == 0)
    error_message = "enable_osr_cloud_logging defaults to false: no OSR resource may be planned."
  }

  assert {
    condition     = output.osr_sa_email == "" && output.osr_log_view == ""
    error_message = "OSR outputs must be empty when the footprint is off."
  }
}

run "osr_cloud_logging_view_scoped_only" {
  command = plan

  variables {
    enable_osr_cloud_logging = true
  }

  assert {
    condition     = google_service_account.osr[0].account_id == "acme-gcp-osr-sa"
    error_message = "OSR SA account_id must be {org}-gcp-osr-sa."
  }

  assert {
    condition     = output.osr_log_view == "projects/acme-prod/locations/global/buckets/_Default/views/acme-osr-k8s"
    error_message = "osr_log_view must be the full _Default view name the read API's config expects."
  }

  assert {
    condition     = google_logging_log_view.osr_k8s[0].filter == "SOURCE(\"projects/acme-prod\") AND ((resource.type=\"k8s_container\" AND (LOG_ID(\"stdout\") OR LOG_ID(\"stderr\"))) OR ((resource.type=\"k8s_pod\" OR resource.type=\"k8s_cluster\") AND LOG_ID(\"events\")))"
    error_message = "OSR log view filter changed."
  }

  assert {
    condition     = google_logging_log_view_iam_member.osr_view_accessor[0].role == "roles/logging.viewAccessor"
    error_message = "The OSR SA's only grant is view-level roles/logging.viewAccessor."
  }
}
