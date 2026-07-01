# GCP org onboarding (Terraform)

Run once per KubeOrg, in your GCP project, by an IAM-admin, before creating the KubeOrg.

## Prerequisites
- A GCP project with a **linked billing account**.
- Run by a principal with `serviceusage.services.enable` plus the onboarding admin roles
  (or `roles/owner` for the onboarding run).
- The module enables every API the platform needs for you — both the **identity/federation**
  APIs it uses directly and the **provisioning** APIs the operator/Crossplane use afterward to
  build the KubeOrg network and KubePool cluster (so a fresh project works end-to-end). If your
  org pre-provisions APIs via policy or pipeline, enable them yourself first:
  ```bash
  gcloud services enable \
    iam.googleapis.com cloudresourcemanager.googleapis.com iamcredentials.googleapis.com \
    sts.googleapis.com secretmanager.googleapis.com \
    compute.googleapis.com dns.googleapis.com container.googleapis.com servicenetworking.googleapis.com \
    --project <PROJECT>
  ```

## Run
```bash
git clone https://github.com/kaos-io/onboarding
cd onboarding/gcp

# Auth to your project
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)

# Save the terraform.tfvars the KAOS UI generated (see terraform.tfvars.example) here, then:
terraform init
terraform apply -var-file=terraform.tfvars

# Dedicated-app orgs: pass the GitHub App private key locally (kept out of state & UI):
#   terraform apply -var-file=terraform.tfvars -var="github_app_private_key=$(cat ./your-app.pem)"
```

Creates a per-org WIF pool/provider `<org>-kaosid` and the `<org>-crossplane / -gcp-eso-sa /
-gcp-dns-sa / -node` service accounts with narrowed roles. Re-running is a no-op (idempotent).

## Parity
`terraform output zitadel_sub` MUST equal the operator's `DeterministicUserID(org_name)`, and
`terraform output wif_pool_id` MUST equal the operator/broker `WIFPoolName(org_name)`.
Verify: org `acme` -> sub `ad262e82-8256-5e2e-899e-3d8c40832b54`, pool `acme-kaosid`.

## Verification
Verified against scratch project `wwwe-500812` on 2026-06-28 with `hashicorp/google` 6.50.0
(provider floor `>= 6.23, < 7.0`, required for write-only `secret_data_wo`):
- `terraform apply` (shared-app path) created the per-org identity plane (30 resources), clean.
- Golden vectors matched exactly: `zitadel_sub = ad262e82-8256-5e2e-899e-3d8c40832b54`,
  `wif_pool_id = acme-kaosid`. WIF pool `acme-kaosid` ACTIVE; the four `acme-*` SAs present.
- Re-plan was a no-op (`-detailed-exitcode` = 0): idempotent without any import/wrapper script.
- `terraform destroy` removed all 30 resources; project left clean.
- Owned-app path verified on a billing-enabled project: `terraform apply` with a throwaway
  `github_app_id`/`github_app_private_key` wrote the secret to GCP Secret Manager (secret
  `acme-github-provider-credentials`, version `1` ENABLED), while `grep -c "PRIVATE KEY"
  terraform.tfstate` was `0` — `secret_data_wo` is write-only, so the key reached GSM but is
  absent from Terraform state. Destroyed clean afterward.

## Cost export (disabled by default — future work)

> **Status: FUTURE WORK, disabled by default (`enable_cost_export = false`).**
> The billing-account metrics-consumption path is not built yet, so the footprint below is
> **not provisioned** on a normal onboarding run. The Terraform is kept intact so the whole
> footprint can be turned on with a single flag flip once that path lands. Leave the default
> as-is; do not set `enable_cost_export = true` until the consumption path exists.

When enabled (`enable_cost_export = true`), onboarding deterministically provisions the
footprint the KAOS cost dashboard needs to read invoice-accurate cost actuals for this org:

- enables the BigQuery API,
- creates the `kaos_billing_export` BigQuery dataset (`billing_export_location`, default
  `EU`),
- grants the org ESO service account read-only, dataset-scoped `roles/bigquery.dataViewer`
  on it, plus project-scoped `roles/bigquery.jobUser` so it can run queries,
- exposes the dataset id as the `billing_export_dataset_id` output.

**Why it can't be fully automated (the blocker that makes this future work):** even with the
dataset in place, the Cloud Billing -> BigQuery export that populates it is a **Console-only**
billing-admin step — GCP exposes no API, `gcloud`, or Terraform resource for the export
config. So the dataset stays empty until a human wires it, and the dashboard shows no actuals.
Consuming billing metrics end-to-end (e.g. reading directly from the billing account) is the
outstanding design work tracked here.

The grants are read-only and dataset-scoped for data; the only project-scoped grant is
`jobUser` (job creation, no data access on its own). Nothing touches the billing account or
other datasets.

## Meluxina HPC SSH key

Optional, disabled by default. When enabled, onboarding stages the signed private key that
binds this deployment to a Meluxina HPC account in GCP Secret Manager under the
**deterministic, org-independent** id `meluxina-ssh-key` (identical for every org — it is a
single shared institutional credential, not per-org). ESO reads it via the org eso-sa's
existing project-level Secret Manager access (no extra IAM).

```bash
terraform apply -var-file=terraform.tfvars \
  -var="enable_meluxina_ssh_key=true" \
  -var="meluxina_ssh_key_path=/absolute/path/to/meluxina_private_key"
```

The key's raw bytes are pushed via write-only `secret_data_wo`, so they reach GSM but are
never persisted in Terraform state. `terraform output meluxina_ssh_key_secret_id` returns
`meluxina-ssh-key` when enabled, empty otherwise. Enabling this also enables the Secret
Manager API if it is not already on. Set `enable_meluxina_ssh_key = false` (the default) to
stage nothing.
