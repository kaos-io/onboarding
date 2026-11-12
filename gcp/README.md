# GCP org onboarding (Terraform)

Run once per KubeOrg, in your GCP project, by an IAM-admin, before creating the KubeOrg.

## Prerequisites
- A GCP project with a **linked billing account**.
- Run by a principal with `serviceusage.services.enable` plus the onboarding admin roles
  (or `roles/owner` for the onboarding run).
- The module enables every API the platform needs for you ,  both the **identity/federation**
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

The guided script is the primary path. It checks your gcloud auth, resolves and validates
the project, checks your IAM permissions, installs terraform on Cloud Shell if needed, then
runs init/plan/apply with a confirmation step:

```bash
git clone https://github.com/kaos-io/onboarding
cd onboarding/gcp

# Uses the active project of your gcloud session and reads its number itself.
./onboard.sh --org acme --broker-client-id 376257051585676814
```

Before it changes anything it shows the project id, its display name and its number
in a banner and asks you to type the project id back. Nothing is created until you do,
so a session left pointed at the wrong project cannot quietly onboard it. Pass `--project-id` when your session
points somewhere else, and `--project-number` only if you want it asserted rather than
read. Both values come from the KAOS wizard's cloud step, which shows the command with
them already filled in. Run `./onboard.sh --help` for the full flag list, including
`--plan-only` and `--yes`. A few things this script exists to catch:

- **Project ID vs display name.** GCP projects have an immutable, globally unique ID and a
  separate, editable display name; Terraform needs the ID. GCP only appends digits to the ID
  when your chosen name is already taken globally, so the two are sometimes identical and
  sometimes not. A project displayed as "integration-test" can have the ID
  `integration-test-509613`. Passing the display name where the ID is expected fails every
  resource with `Project 'projects/integration-test' not found or deleted`; the script
  detects this case and tells you the correct `--project-id` to use.
- **Google Cloud Shell does not preinstall terraform**, and anything installed with `apt`
  there does not survive past the current session (only `$HOME` does). The script detects
  Cloud Shell and offers to install a pinned terraform into `$HOME/bin`, which does persist.
- **A project that already hosts another KAOS organisation** fails apply on the four
  project-level custom roles (`kubecoreArtifactRegistryProvisioner`, `kubecoreEsoSecretWriter`,
  `kubecoreSecretManagerProvisioner`, `kubecoreWorkloadIdentityBinder`), which have fixed,
  org-independent ids and so already exist. The script recognises this failure and prints the
  exact `terraform import` commands to adopt the existing roles before you rerun apply.

After a successful apply (including a rerun where terraform finds nothing to change), the
script's last line of output is `kaos:gcp:<org>:<project-id>:<project-number>`; paste that
line into the KAOS wizard and it fills in the project id and number for you. It is not
printed by `--plan-only`, since nothing was applied.

### Manual path (pipeline / advanced)

For CI pipelines or anyone who wants to run terraform directly instead of through the script:

```bash
git clone https://github.com/kaos-io/onboarding
cd onboarding/gcp

# Auth to your project
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)

# Save the terraform.tfvars the KAOS UI generated (see terraform.tfvars.example) here, then:
terraform init
terraform apply -var-file=terraform.tfvars
```

You do not need to supply a GitHub App key. KAOS receives it directly from GitHub when you
create the App, and writes it to your Secret Manager itself once your cloud account is
verified. The `github_app_id`, `github_app_installation_id` and `github_app_private_key`
variables are deprecated and kept only for orgs still on the older manual flow, where a
private key was passed at apply time; leave them empty on a new onboarding run.

Creates a per-org WIF pool/provider `<org>-kaosid` and the `<org>-crossplane / -gcp-eso-sa /
-gcp-dns-sa / -node` service accounts with narrowed roles. Re-running is a no-op (idempotent).

Re-run it after upgrading the module: newer revisions can widen a KAOS custom role (for
example, `kubecoreEsoSecretWriter` gained `secretmanager.secrets.update` so External Secrets
can label the secrets KAOS writes). The re-run needs `iam.roles.update`, which `onboard.sh`
checks for.

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
  terraform.tfstate` was `0` ,  `secret_data_wo` is write-only, so the key reached GSM but is
  absent from Terraform state. Destroyed clean afterward.

Re-verified on two further scratch projects, 2026-09-22 and 2026-09-24, at module commit
`39aa98b` with `hashicorp/google` 6.50.0: on a fresh project with Owner, `terraform plan`
plans **51 to add, 0 to change, 0 to destroy** (the module has grown since the 2026-06-28
run above). Treat 51 as the current expected plan size on a fresh project; the resource
count will keep moving as the module gains scope, so check the plan output itself rather
than assuming either number.

## Cost export (disabled by default ,  future work)

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
billing-admin step ,  GCP exposes no API, `gcloud`, or Terraform resource for the export
config. So the dataset stays empty until a human wires it, and the dashboard shows no actuals.
Consuming billing metrics end-to-end (e.g. reading directly from the billing account) is the
outstanding design work tracked here.

The grants are read-only and dataset-scoped for data; the only project-scoped grant is
`jobUser` (job creation, no data access on its own). Nothing touches the billing account or
other datasets.

## OSR Cloud Logging read path (opt-in, off by default)

> **Status: opt-in (`enable_osr_cloud_logging = false` by default).** Leave it off unless
> KAOS asks you to turn it on. With it off nothing below is created.

The pool's OSR read API normally serves pipeline step logs and run events from the cluster
itself. With this on, it can also read older ones from this project's Cloud Logging, through
one log view and nothing else. `enable_osr_cloud_logging = true` creates:

- the `logging.googleapis.com` API enablement (kept on destroy; GKE already needs it),
- the service account `<org>-gcp-osr-sa`, with **no project-level role**,
- the log view `<org>-osr-k8s` on this project's `_Default` log bucket (location
  `osr_log_view_location`, default `global`), filtered to Kubernetes container
  `stdout`/`stderr` and Kubernetes pod and cluster `events` of this project:

  ```
  SOURCE("projects/<PROJECT>") AND ((resource.type="k8s_container" AND (LOG_ID("stdout") OR LOG_ID("stderr"))) OR ((resource.type="k8s_pod" OR resource.type="k8s_cluster") AND LOG_ID("events")))
  ```

- `roles/logging.viewAccessor` for `<org>-gcp-osr-sa` on that view's own IAM policy, so it
  reaches this view only. It is never granted `roles/logging.viewer` on the project, which
  would expose every log in it,
- `roles/iam.serviceAccountViewer` and the `kubecoreWorkloadIdentityBinder` role for
  `<org>-crossplane` on `<org>-gcp-osr-sa`, so KAOS can observe the account and, after the
  pool's cluster exists, bind it with Workload Identity to the OSR read API. The binding
  itself is made by KAOS, not here, for the same reason as the ESO/DNS/GKE/CI bindings.

Outputs: `osr_sa_email` and `osr_log_view` (the full view name,
`projects/<PROJECT>/locations/<loc>/buckets/_Default/views/<org>-osr-k8s`). Both are empty
when the flag is off.

The read API checks its own permissions when it starts and every five minutes after. If
`<org>-gcp-osr-sa` holds any project-level log, secret, token, exec or storage-read
permission, it refuses to use Cloud Logging. Do not add grants to this account.

Known limit: Cloud Logging cannot tell which KubeOrg a cluster belongs to before the cluster
exists, so the view covers every GKE cluster in this project. If several KubeOrgs share the
project, each org's account can read the others' Kubernetes container logs at the IAM level;
the read API filters every request and re-checks every entry against the pool's own
project, location, cluster, namespace and pod.

If your `_Default` bucket is not in `global` (an organisation-wide default storage location
can move it), set `osr_log_view_location` to its location. Check with
`gcloud logging buckets list --project <PROJECT>`.

## Meluxina HPC SSH key (removed)

This module no longer stages the Meluxina HPC SSH key. Enter the key in the KAOS console
as a project secret of type SSH key and select it on the project's HPC settings. The value
goes straight to your Secret Manager and never passes through Terraform.

**Upgrading from a revision that had `enable_meluxina_ssh_key`:**

- Remove `enable_meluxina_ssh_key` and `meluxina_ssh_key_path` from your `terraform.tfvars`
  and from any `-var` flags. Terraform rejects an undeclared `-var` on the command line; a
  leftover entry left in `terraform.tfvars` instead is only a warning and is silently ignored.
- The next `terraform apply` reports the `meluxina-ssh-key` secret as "will no longer be
  managed by Terraform" and destroys nothing. The secret stays in your Secret Manager so
  HPC projects that still read it keep working.
- Once every HPC project has moved to its console-managed key, delete the old secret
  yourself: `gcloud secrets delete meluxina-ssh-key --project <PROJECT>`. KAOS never deletes
  it: the External Secrets service account that writes project secrets has no delete
  permission, and KAOS only manages ids starting with `kaos_`.
