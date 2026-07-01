# Meluxina HPC SSH key secret — design

**Date:** 2026-07-01
**Module:** `gcp/` (per-org GCP onboarding Terraform)
**Status:** Approved

## Problem

The Meluxina HPC integration requires a signed private RSA/ed25519 key (bound to the
user's Meluxina account) to live in GCP Secret Manager so in-cluster consumers (via ESO)
can read it. Today the onboarding module stages one optional secret — the dedicated
GitHub App credential (`{org}-github-provider-credentials`). We need a second optional
secret for the Meluxina key.

Reference (manual equivalent the developer runs today):

```
gcloud secrets create meluxina-ssh-key --project <proj> --replication-policy automatic
gcloud secrets versions add meluxina-ssh-key --project <proj> --data-file /path/to/key
```

## Requirements

1. **Disabled by default**, user opts in.
2. **Deterministic name, identical for all organisations:** `meluxina-ssh-key`
   (NOT org-prefixed — unlike the github secret). This is a single shared Meluxina
   institutional credential.
3. Automatic replication policy.
4. Payload is the **raw** key file bytes (matches `--data-file`), not JSON-wrapped.
5. Key material must **not** be persisted in Terraform state.

## Design

### Variables (`variables.tf`)

- `enable_meluxina_ssh_key` — `bool`, default `false`. Opt-in gate.
- `meluxina_ssh_key_path` — `string`, default `""`, `sensitive`. Absolute path to the
  signed private key file. Read via `file()` at plan time.

### Resources (`main.tf`)

- `google_secret_manager_secret.meluxina_ssh_key`
  - `count = var.enable_meluxina_ssh_key ? 1 : 0`
  - `secret_id = "meluxina-ssh-key"` (hardcoded, not org-derived)
  - `replication { auto {} }`
  - `depends_on = [google_project_service.secretmanager]`
- `google_secret_manager_secret_version.meluxina_ssh_key`
  - `secret_data_wo = file(var.meluxina_ssh_key_path)` (write-only → never in state)
  - `secret_data_wo_version = 1`
  - `precondition`: when `enable_meluxina_ssh_key` is true, `meluxina_ssh_key_path`
    must be non-empty (fail fast with a clear message).

### Secret Manager API gate (`main.tf`)

`google_project_service.secretmanager` currently has `count = stage_github_app ? 1 : 0`.
Widen to enable the API whenever **either** secret is staged:

```
count = (local.stage_github_app || var.enable_meluxina_ssh_key) ? 1 : 0
```

### Output (`outputs.tf`)

- `meluxina_ssh_key_secret_id` — secret id when enabled, `""` otherwise.
  Mirrors `github_app_secret_id`.

### IAM / consumption

None required. The org `eso-sa` already holds project-level
`secretmanager.secrets.get` + `versions.access` (via `kubecoreEsoSecretWriter`), so ESO
can read the new secret with no additional grant.

### Docs

Add both new vars to `terraform.tfvars.example` and the `gcp/README.md` var table for
parity with existing variables.

## Caveat

Because the secret id is a fixed `meluxina-ssh-key` (not `{org}-...`), onboarding two
different orgs into the **same** GCP project would target the same secret. This is the
intended shared-credential semantics, documented here for awareness.

## Testing plan

Against `novelcore-test` (state on branch `feat/enable-provisioning-apis`):

```
terraform plan  -var-file=terraform.tfvars \
  -var="enable_meluxina_ssh_key=true" \
  -var="meluxina_ssh_key_path=/Users/abstractversion/Downloads/meluxina"

terraform apply <same vars>
```

Verify:

```
gcloud secrets describe meluxina-ssh-key --project novelcore-test
gcloud secrets versions access latest --secret=meluxina-ssh-key --project novelcore-test \
  | diff - /Users/abstractversion/Downloads/meluxina   # expect no diff
```
