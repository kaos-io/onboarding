# kaos-cost Onboarding Slice — BigQuery Billing-Export Read (Terraform)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, dataset-scoped, read-only BigQuery grant to the GCP onboarding Terraform so the in-client billing reader can query the client's billing-export dataset (cost actuals) from within the client's own project. Absent the opt-in variable, greenfield onboarding is byte-for-byte unchanged.

**Architecture:** A single `count`-gated `google_bigquery_dataset_iam_member` granting `roles/bigquery.dataViewer` on the billing-export dataset to the existing `{org}-gcp-eso-sa` service account. No new SA, no billing-account IAM, no project-wide roles. The billing reader workload (and its Workload-Identity binding) is operator/composition-side and out of scope here — this slice only provisions the standing IAM grant, matching the repo's "standing platform IAM in Terraform, post-cluster workload bindings in Crossplane compositions" split.

**Tech Stack:** Terraform `>= 1.7.0`, `hashicorp/google >= 6.23, < 7.0` (single `gcp/main.tf` + `variables.tf`).

## Global Constraints

- **Opt-in:** the grant is `count`-gated on a new `billing_export_dataset_id` variable defaulting to `""`. When empty, `count = 0` → zero new resources, greenfield unchanged (the README's "re-running is a no-op / 30 resources" invariant must still hold with the var unset).
- **Least-privilege intact:** dataset-scoped `roles/bigquery.dataViewer` (read-only) only. No `roles/billing.viewer`, no billing-account IAM, no project-wide predefined roles, no `setIamPolicy`. Reuse the existing `google_service_account.eso` — do NOT create a new SA.
- **Prerequisite (out of band):** the BigQuery billing export must already be enabled by the client's billing-admin (a one-time manual step the onboarding deliberately excludes). The grant references an existing dataset; supplying the variable is the client's signal that the dataset exists.
- The dataset may live in a different project than the cluster project — support an optional dataset-project override defaulting to `gcp_project_id`.

---

## File Structure

- `gcp/variables.tf` — two new variables: `billing_export_dataset_id` (gate) and `billing_export_dataset_project` (override).
- `gcp/main.tf` — one new `google_bigquery_dataset_iam_member` resource, placed near the existing `eso_*` IAM bindings (after `eso_monitoring_viewer` at `:174-177`).
- `gcp/README.md` — document the new optional variable + the billing-admin prerequisite.

---

## Task 1: Add the opt-in variables

**Files:**
- Modify: `gcp/variables.tf` (append after the last variable, `github_app_private_key` ~`:61`)

**Interfaces:**
- Produces: `var.billing_export_dataset_id` (string, default `""`); `var.billing_export_dataset_project` (string, default `""`).

- [ ] **Step 1: Append the variables**

Append to `gcp/variables.tf`:

```hcl
variable "billing_export_dataset_id" {
  type        = string
  default     = ""
  description = "BigQuery billing-export dataset ID (e.g. \"billing_export\"). Optional. When set, grants the org ESO service account read-only access so the in-client billing reader can query cost actuals. Empty = no grant (greenfield unchanged). Supply only after the client's billing-admin has enabled the export."
}

variable "billing_export_dataset_project" {
  type        = string
  default     = ""
  description = "Project that holds the billing-export dataset, if different from gcp_project_id. Empty = use gcp_project_id."
}
```

- [ ] **Step 2: Format + validate**

Run:
```bash
cd gcp && terraform fmt && terraform init -backend=false && terraform validate
```
Expected: `terraform validate` prints "Success! The configuration is valid." (variables alone do not change the plan.)

- [ ] **Step 3: Commit**

```bash
git add gcp/variables.tf
git commit -m "feat(onboarding-gcp): add opt-in billing_export_dataset_id variables"
```

---

## Task 2: Add the dataset-scoped read grant

**Files:**
- Modify: `gcp/main.tf` (after `google_project_iam_member "eso_monitoring_viewer"` ~`:174-177`)

**Interfaces:**
- Consumes: `var.billing_export_dataset_id`, `var.billing_export_dataset_project` (Task 1); existing `google_service_account.eso`, `var.gcp_project_id`.
- Produces: `google_bigquery_dataset_iam_member.eso_billing_dataset_reader` (count 0 or 1).

- [ ] **Step 1: Add the resource**

In `gcp/main.tf`, immediately after the `eso_monitoring_viewer` block (`:174-177`), add:

```hcl
# Cost export (kaos-cost): read-only access to the billing-export BigQuery dataset so the
# in-client billing reader can query cost actuals. Opt-in (count-gated), dataset-scoped,
# read-only. Reuses the org ESO SA — no new SA, no billing-account IAM. Out of band: the
# client's billing-admin must have enabled the BigQuery billing export first.
resource "google_bigquery_dataset_iam_member" "eso_billing_dataset_reader" {
  count      = var.billing_export_dataset_id != "" ? 1 : 0
  project    = var.billing_export_dataset_project != "" ? var.billing_export_dataset_project : var.gcp_project_id
  dataset_id = var.billing_export_dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.eso.email}"
}
```

- [ ] **Step 2: Format + validate**

Run:
```bash
cd gcp && terraform fmt && terraform init -backend=false && terraform validate
```
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Plan — gate OFF (var unset) shows no new resource**

Run (against the repo's test project, mirroring the README verification):
```bash
cd gcp && terraform plan \
  -var org_name=acme -var gcp_project_id=wwwe-500812 -var gcp_project_number=000000000000 \
  -var zitadel_issuer=https://access.platform.kaos-labs.org -var broker_app_client_id=test \
  | grep -c "google_bigquery_dataset_iam_member"
```
Expected: `0` — with `billing_export_dataset_id` defaulting to `""`, `count = 0`, no `google_bigquery_dataset_iam_member` appears (greenfield 30-resource invariant intact).

- [ ] **Step 4: Plan — gate ON (var set) shows exactly one new resource**

Run:
```bash
cd gcp && terraform plan \
  -var org_name=acme -var gcp_project_id=wwwe-500812 -var gcp_project_number=000000000000 \
  -var zitadel_issuer=https://access.platform.kaos-labs.org -var broker_app_client_id=test \
  -var billing_export_dataset_id=billing_export \
  | grep "google_bigquery_dataset_iam_member.eso_billing_dataset_reader"
```
Expected: the plan shows `google_bigquery_dataset_iam_member.eso_billing_dataset_reader[0] will be created` with `role = "roles/bigquery.dataViewer"` and the member set to the `{org}-gcp-eso-sa` service account.

- [ ] **Step 5: Commit**

```bash
git add gcp/main.tf
git commit -m "feat(onboarding-gcp): opt-in dataset-scoped bigquery.dataViewer for cost actuals"
```

---

## Task 3: Document the prerequisite + variable

**Files:**
- Modify: `gcp/README.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Add a "Cost export (optional)" section to `gcp/README.md`**

Document: (a) the one-time billing-admin step to enable the BigQuery billing export into the client's project; (b) that `billing_export_dataset_id` (and optional `billing_export_dataset_project`) opt the org into the read grant; (c) that leaving it unset is a no-op (greenfield unchanged); (d) that the grant is read-only and dataset-scoped (`roles/bigquery.dataViewer`), no billing-account access.

```markdown
## Cost export (optional)

To let the KAOS cost dashboard read invoice-accurate cost actuals for this org:

1. **Billing-admin (one-time, out of band):** enable a BigQuery billing export
   into a dataset in this project (Cloud Billing → Billing export → BigQuery export).
2. **Re-apply with the dataset ID:** set `billing_export_dataset_id` (and
   `billing_export_dataset_project` if the dataset is in another project). This grants
   the org ESO service account read-only, dataset-scoped `roles/bigquery.dataViewer`.

Leaving `billing_export_dataset_id` unset is a no-op — onboarding is unchanged. The grant
is read-only and dataset-scoped; it never touches the billing account or project-wide IAM.
```

- [ ] **Step 2: Commit**

```bash
git add gcp/README.md
git commit -m "docs(onboarding-gcp): document opt-in cost-export billing dataset grant"
```

---

## Self-Review

**Spec coverage (against `2026-06-28-kaos-cost-finops-design.md` §7 + §8 onboarding bullet):**
- One optional, `count`-gated `google_bigquery_dataset_iam_member` (dataViewer) keyed on `billing_export_dataset_id` → Task 2. ✓
- Absent the var, greenfield unchanged (count 0) → Task 2 Step 3. ✓
- No new SA, no billing-account IAM, no `billing.viewer`, no project-wide roles → only the dataset-scoped grant added; reuses `google_service_account.eso`. ✓
- Dataset may be cross-project → `billing_export_dataset_project` override → Task 1. ✓
- Billing-admin export-enable stays out of Terraform (documented, not provisioned) → Task 3. ✓
- The billing reader workload + its WI binding are operator/composition-side → explicitly out of scope (noted in Architecture). ✓

**Placeholder scan:** plan commands use the README's real test project (`wwwe-500812`) and concrete `-var` values; the grep assertions are exact resource addresses. No vague steps.

**Type consistency:** `billing_export_dataset_id` / `billing_export_dataset_project` / `google_bigquery_dataset_iam_member.eso_billing_dataset_reader` / `google_service_account.eso.email` used consistently across Tasks 1–3.
