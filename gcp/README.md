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
