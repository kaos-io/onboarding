locals {
  # Must match internal/operators/kubeorg/phases/reconciling.go DeterministicUserID():
  # UUIDv5(namespace=7b3f9d2c-1e84-4a6b-9c5d-2f8a0e6b4d13, org_name)
  # Parity check: org "acme" → ad262e82-8256-5e2e-899e-3d8c40832b54
  # A change to this namespace or to DeterministicUserID()'s UUIDv5 call MUST be mirrored on both sides.
  zitadel_sub = uuidv5("7b3f9d2c-1e84-4a6b-9c5d-2f8a0e6b4d13", var.org_name)

  # Per-org WIF identity: pool id == provider id == "{org}-kaosid". MUST stay in parity
  # with the operator/broker helper WIFPoolName(org) and the public repo's naming rule.
  # org_name <= 19 + "-kaosid" (7) = <= 26, within GCP's 32-char pool-id limit.
  identity_name   = "${var.org_name}-kaosid"
  wif_pool_id     = local.identity_name
  wif_provider_id = local.identity_name

  crossplane_sa_email = "${var.org_name}-crossplane@${var.gcp_project_id}.iam.gserviceaccount.com"
  eso_sa_email        = "${var.org_name}-gcp-eso-sa@${var.gcp_project_id}.iam.gserviceaccount.com"
  dns_sa_email        = "${var.org_name}-gcp-dns-sa@${var.gcp_project_id}.iam.gserviceaccount.com"
  node_sa_email       = "${var.org_name}-node@${var.gcp_project_id}.iam.gserviceaccount.com"
  # account_id "{org}-gcp-gke-sa" = 11-char suffix; org_name <= 19 => <= 30 (GCP cap). Never truncate org_name.
  gke_sa_email = "${var.org_name}-gcp-gke-sa@${var.gcp_project_id}.iam.gserviceaccount.com"
  # account_id "{org}-gcp-ci-sa" = 10-char suffix; org_name <= 19 => <= 29 (GCP cap). Never truncate org_name.
  ci_sa_email = "${var.org_name}-gcp-ci-sa@${var.gcp_project_id}.iam.gserviceaccount.com"

  wif_principal = "principal://iam.googleapis.com/projects/${var.gcp_project_number}/locations/global/workloadIdentityPools/${local.wif_pool_id}/subject/${local.zitadel_sub}"

  # Standing operator (crossplane) SA — infra provisioning only. No IAM-grant / identity power.
  # DEC-GCP-03: container.admin is required for in-cluster cluster-admin via GKE's IAM->system:masters bridge.
  operator_project_roles = [
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin", # securityAdmin: firewall-rule management during VPC provisioning
    "roles/container.admin",
    "roles/dns.admin",
    "roles/storage.admin",
  ]

  # Project APIs enabled for the KAOS control plane, all unconditional.
  #   - identity/federation: used by THIS module to create the WIF identity plane.
  #   - provisioning: used LATER by the operator's Crossplane providers to build the KubeOrg
  #     network (compute, dns) and the KubePool GKE cluster (container, servicenetworking).
  # Enabling them here prepares a fresh project end-to-end with no manual step and no script.
  # No resource in this module consumes the provisioning APIs, so enabling them never blocks
  # or fails this apply (the operator uses them in a later, separate reconcile).
  required_apis = [
    # identity / federation (used by this module)
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    # provisioning (used by the operator / Crossplane after onboarding)
    "compute.googleapis.com",
    "dns.googleapis.com",
    "container.googleapis.com",
    "servicenetworking.googleapis.com",
    # PRD-247 GCP ML pricing exporter: Cloud Billing price-catalog API (SKU pricing).
    "cloudbilling.googleapis.com",
    # Secret Manager holds the GitHub App credential. On the owner-link flow this
    # module stages nothing, so nothing here consumes the API, but the platform's
    # token-broker writes the credential into this project right after the
    # verification probe. Enabling it only when the module itself stages a secret
    # left a brand-new project without it and the push failed with HTTP 403,
    # parking the onboarding at ORG_COMMITTING (seen 2026-09-28).
    "secretmanager.googleapis.com",
    # PRD-REG-994 Phase 2: per-KubeProject Artifact Registry repositories.
    "artifactregistry.googleapis.com",
  ]
}

resource "google_project_service" "required" {
  for_each           = toset(local.required_apis)
  project            = var.gcp_project_id
  service            = each.value
  disable_on_destroy = false # never disable APIs on destroy — the operator/Crossplane rely on them; re-enabling has propagation lag
}

resource "google_iam_workload_identity_pool" "kubecore_zitadel" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = local.wif_pool_id
  display_name              = "KubeCore Zitadel WIF"
  description               = "Trusts the Zitadel issuer; one pool per project shared by all KubeOrgs."
  depends_on                = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "kubecore_zitadel" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.kubecore_zitadel.workload_identity_pool_id
  workload_identity_pool_provider_id = local.wif_provider_id
  display_name                       = "KubeCore Zitadel"
  attribute_mapping                  = { "google.subject" = "assertion.sub" }
  oidc {
    issuer_uri        = var.zitadel_issuer
    allowed_audiences = [var.broker_app_client_id]
  }
}

resource "google_service_account" "crossplane" {
  project      = var.gcp_project_id
  account_id   = "${var.org_name}-crossplane"
  display_name = "Crossplane provisioner SA for org ${var.org_name}"
  depends_on   = [google_project_service.required]
}

# The Zitadel sub impersonates the crossplane SA (broker -> external_account chain).
resource "google_service_account_iam_member" "crossplane_token_creator" {
  service_account_id = google_service_account.crossplane.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.wif_principal
}

resource "google_project_iam_member" "operator_roles" {
  for_each = toset(local.operator_project_roles)
  project  = var.gcp_project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.crossplane.email}"
}

# The crossplane (provisioning) SA manages GCP Secret Manager Secret + SecretVersion
# Crossplane MRs for OIDC SSO credential delivery (ArgoCD/Argo-Workflows/Grafana —
# internal/operators/kubepool/compositions/gcp/oidc_publisher.go creates them via the
# org ProviderConfig, which is THIS SA). The 5 infra roles above don't include Secret
# Manager, so this scoped custom role grants the full Secret + SecretVersion lifecycle
# the provider needs (observe/create/update/delete) WITHOUT secretmanager.*.setIamPolicy
# — the SA can manage secret material but cannot grant any principal access to a secret
# (no privilege-delegation power; security-clean). Distinct from kubecoreEsoSecretWriter
# (the eso-sa's narrower runtime push/pull role).
resource "google_project_iam_custom_role" "crossplane_secret_manager" {
  # The IAM API must be on before a role can be read or created. Without this the
  # provider races the enablement on a brand-new project and fails with
  # SERVICE_DISABLED, which it reports as "must be undeleted" (seen 2026-09-28).
  depends_on = [google_project_service.required]

  project     = var.gcp_project_id
  role_id     = "kubecoreSecretManagerProvisioner"
  title       = "KubeCore Secret Manager Provisioner"
  description = "Crossplane SA: full Secret + SecretVersion lifecycle for OIDC credential delivery; no setIamPolicy (least-privilege)."
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.get",
    "secretmanager.secrets.update",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.list",
    "secretmanager.versions.add",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
    "secretmanager.versions.access",
    "secretmanager.versions.enable",
    "secretmanager.versions.disable",
    "secretmanager.versions.destroy",
  ]
}

resource "google_project_iam_member" "crossplane_secret_manager" {
  project = var.gcp_project_id
  role    = google_project_iam_custom_role.crossplane_secret_manager.name
  member  = "serviceAccount:${google_service_account.crossplane.email}"
}

# PRD-REG-994 Phase 2: the crossplane (provisioning) SA creates one Artifact Registry
# repository per KubeProject in the org's own GCP project. Repository lifecycle only
# (create/get/update/delete/list) — Option C (PRD-REG-994): repositories are created
# dynamically per KubeProject, so there is no Terraform-time resource to scope a
# repository-level setIamPolicy grant against. Granting it would have to be
# project-scoped, letting the holder open every repository present and future to any
# principal — a worse escalation than the per-repository isolation buys. Pull/push
# authorization is therefore granted at the project level instead (see the node SA's
# artifactregistry.reader and the ci SA's artifactregistry.writer, below), never via
# repository IAM policies. Distinct from kubecoreSecretManagerProvisioner (above): same
# shape, different service.
resource "google_project_iam_custom_role" "crossplane_artifact_registry" {
  # The IAM API must be on before a role can be read or created. Without this the
  # provider races the enablement on a brand-new project and fails with
  # SERVICE_DISABLED, which it reports as "must be undeleted" (seen 2026-09-28).
  depends_on = [google_project_service.required]

  project     = var.gcp_project_id
  role_id     = "kubecoreArtifactRegistryProvisioner"
  title       = "KubeCore Artifact Registry Provisioner"
  description = "Crossplane SA: create/get/update/delete/list Artifact Registry repositories; no setIamPolicy (least-privilege, PRD-REG-994)."
  permissions = [
    "artifactregistry.repositories.create",
    "artifactregistry.repositories.get",
    "artifactregistry.repositories.update",
    "artifactregistry.repositories.delete",
    "artifactregistry.repositories.list",
  ]
}

resource "google_project_iam_member" "crossplane_artifact_registry" {
  project = var.gcp_project_id
  role    = google_project_iam_custom_role.crossplane_artifact_registry.name
  member  = "serviceAccount:${google_service_account.crossplane.email}"
}

# --- ESO SA (org-shared) ---
resource "google_service_account" "eso" {
  project      = var.gcp_project_id
  account_id   = "${var.org_name}-gcp-eso-sa"
  display_name = "ESO SA for ${var.org_name}"
  depends_on   = [google_project_service.required]
}

# Secret Manager: ESO PushSecret needs create/get + version add/access, NOT delete → custom role.
# roles/secretmanager.secretCreator does not exist in GCP (returns 400 in live e2e); covered by .secrets.create below.
resource "google_project_iam_custom_role" "eso_secret_writer" {
  # The IAM API must be on before a role can be read or created. Without this the
  # provider races the enablement on a brand-new project and fails with
  # SERVICE_DISABLED, which it reports as "must be undeleted" (seen 2026-09-28).
  depends_on = [google_project_service.required]

  project     = var.gcp_project_id
  role_id     = "kubecoreEsoSecretWriter"
  title       = "KubeCore ESO Secret Writer"
  description = "ESO PushSecret: create/get secrets + add/access versions; no delete (least-privilege)."
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.get",
    "secretmanager.versions.add",
    "secretmanager.versions.access",
  ]
}

resource "google_project_iam_member" "eso_secret_writer" {
  project = var.gcp_project_id
  role    = google_project_iam_custom_role.eso_secret_writer.name
  member  = "serviceAccount:${google_service_account.eso.email}"
}

resource "google_project_iam_member" "eso_monitoring_viewer" {
  project = var.gcp_project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.eso.email}"
}

# NOTE: the previous `eso_compute_viewer` (roles/compute.viewer on eso-sa) was REMOVED —
# it was the I1 anti-pattern (a live-compute capability piled onto the shared eso-sa, which
# every KSA bound to eso-sa silently inherits). The only consumer was the ML live-compute
# probe/healer, whose compute.viewer now lives on the dedicated {org}-gcp-gke-sa
# (gke_compute_viewer, below). The observability-cost exporter needs only
# roles/monitoring.viewer (eso_monitoring_viewer, above) + the Cloud Billing Catalog API,
# not compute.viewer — so removing this grant does not affect cost dashboards.

# ---------------------------------------------------------------------------
# Cost export (kaos-cost): deterministic BigQuery footprint for the in-client
# billing reader. Terraform OWNS the dataset (onboarding runs on an empty project
# before anything else, so the dataset cannot be assumed to pre-exist). Opt-in via
# enable_cost_export (default FALSE — FUTURE WORK: the billing-account metrics-
# consumption path is not built yet, and the Cloud Billing -> BigQuery export that
# would populate this dataset is a Console-only billing-admin step with no API/
# Terraform resource, so the footprint stays inert on its own). Left in place so the
# footprint can be re-enabled in one flag flip once that path exists.
# ---------------------------------------------------------------------------

# BigQuery API — must be enabled before the dataset is created on a fresh project.
resource "google_project_service" "bigquery" {
  count              = var.enable_cost_export ? 1 : 0
  project            = var.gcp_project_id
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

# The billing-export dataset. Fixed id so the system binds deterministically via the
# billing_export_dataset_id output. Cloud Billing export writes cost tables here.
resource "google_bigquery_dataset" "billing_export" {
  count                      = var.enable_cost_export ? 1 : 0
  project                    = var.gcp_project_id
  dataset_id                 = "kaos_billing_export"
  location                   = var.billing_export_location
  friendly_name              = "KAOS billing export"
  description                = "Cloud Billing BigQuery export target, read by the in-client KAOS billing reader. Populated out-of-band by a billing-admin (Cloud Billing -> BigQuery export)."
  delete_contents_on_destroy = true

  depends_on = [google_project_service.bigquery]
}

# Read-only, dataset-scoped access to the billing data for the org ESO SA.
resource "google_bigquery_dataset_iam_member" "eso_billing_dataset_reader" {
  count      = var.enable_cost_export ? 1 : 0
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.billing_export[0].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.eso.email}"
}

# Job-creation access so the billing reader can RUN queries (dataViewer alone cannot
# execute SQL). jobUser grants no data access on its own — dataViewer remains the data guard.
resource "google_project_iam_member" "eso_bigquery_job_user" {
  count   = var.enable_cost_export ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.eso.email}"
}

# Zitadel sub impersonates eso-sa (control-plane ESO via broker)
resource "google_service_account_iam_member" "eso_wif_user" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_principal
}



# SA-level token-creator (replaces today's project-wide grant)
resource "google_service_account_iam_member" "eso_token_creator" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.eso.email}"
}

# --- DNS SA (org-shared) ---
resource "google_service_account" "dns" {
  project      = var.gcp_project_id
  account_id   = "${var.org_name}-gcp-dns-sa"
  display_name = "ExternalDNS SA for ${var.org_name}"
  depends_on   = [google_project_service.required]
}

resource "google_project_iam_member" "dns_admin" {
  project = var.gcp_project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.dns.email}"
}


# --- GKE-developer SA (org-shared, single job: cluster/node-pool K8s-API access) ---
# Carries the container.developer capability the ML live-compute workloads need
# (autoscaler-healer + create/destroy-nodegroups: clear stale autoscaler backoff on
# scale-to-zero pools, create ephemeral per-pipeline node pools). Dedicated SA per
# invariant I1 (one SA, one job): granting container.developer on the shared eso-sa
# would silently escalate every KSA already bound to eso-sa (external-secrets/{org}-eso-sa,
# argo-workflows/ml-compute-probe-sa, operate-workflow-sa) to K8s-API access on ALL
# clusters in the project. This SA is distributed to child clusters via the pool
# composition's dedicated KSA ({org}-gke-sa) + per-cluster Workload Identity binding.
resource "google_service_account" "gke" {
  project      = var.gcp_project_id
  account_id   = "${var.org_name}-gcp-gke-sa"
  display_name = "GKE developer SA for ${var.org_name}"
  depends_on   = [google_project_service.required]
}

# container.developer bridges GCP IAM to in-cluster Kubernetes RBAC on EVERY cluster in
# the project (the GKE IAM->RBAC bridge). Held ONLY by this dedicated SA — documented for
# the security team alongside DEC-GCP-03. Needed by the autoscaler-healer (node-pool
# min-count bump/revert) + create-nodegroups (ephemeral pool create/destroy).
resource "google_project_iam_member" "gke_container_developer" {
  project = var.gcp_project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.gke.email}"
}

# Read-only Compute visibility: the autoscaler-healer/nodepool-janitor enumerate node
# pools + resolve the cluster's zonal location via the Compute/Container APIs. Moved here
# from eso-sa (the eso_compute_viewer grant is the anti-pattern I1 rules out going forward);
# lives on this dedicated SA so the compute-read capability travels with container.developer.
resource "google_project_iam_member" "gke_compute_viewer" {
  project = var.gcp_project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.gke.email}"
}


# --- Node SA (org-shared, replaces per-pool {pool}-node) ---
resource "google_service_account" "node" {
  project      = var.gcp_project_id
  account_id   = "${var.org_name}-node"
  display_name = "GKE node SA for ${var.org_name}"
  depends_on   = [google_project_service.required]
}

resource "google_project_iam_member" "node_roles" {
  # GKE custom-node-SA documented minimum (Google "use least privilege SA for nodes"):
  # logWriter + metricWriter + monitoring.viewer + stackdriver.resourceMetadata.writer.
  # Without the latter two the gke node monitoring/metadata agents degrade silently
  # (nodes register but system components are unhealthy). artifactregistry.reader:
  # PRD-REG-994 Phase 2 revises D-13 — GAR now backs KubeApp images (kubelet pulls what
  # in-cluster CI pushes) alongside in-cluster Zot. The grant is project-level and
  # deliberate: repositories are per-KubeProject (Option C, PRD-REG-994), but there is
  # no Terraform-time per-repository resource to scope IAM against, so pull is
  # org-scoped rather than KubeProject-scoped. Still a large improvement over today,
  # where Zot's anonymousPolicy:["read"] on "**" makes pull unauthenticated-readable.
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])
  project = var.gcp_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.node.email}"
}

# Operator may launch nodes running as the node SA (actAs — identity-use, not grant)
resource "google_service_account_iam_member" "operator_actas_node" {
  service_account_id = google_service_account.node.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.crossplane.email}"
}

# --- CI push SA (org-shared) ---
# PRD-REG-994 Phase 2: in-cluster CI pushes application images to Artifact Registry.
# Dedicated per invariant I1 (one SA, one job) — granting artifactregistry.writer on the
# shared eso-sa or crossplane SA would pile a live-push capability onto SAs with other
# jobs. Two-step binding, same pattern as eso/dns/gke below: Terraform here creates the
# SA and authorises the crossplane SA to bind it (wi_binder target, below); the actual
# KSA<->GSA Workload Identity binding is created later by a composition, because the
# {projectId}.svc.id.goog WI pool does not exist until the first GKE cluster does.
resource "google_service_account" "ci" {
  project      = var.gcp_project_id
  account_id   = "${var.org_name}-gcp-ci-sa"
  display_name = "CI push SA for ${var.org_name}"
  depends_on   = [google_project_service.required]
}

# roles/artifactregistry.writer is a predefined role that includes read, so this SA can
# push and pull without a custom role. Project-level grant, same Option C rationale as
# the node SA's artifactregistry.reader above: no per-repository Terraform-time resource
# exists to scope against, so push is org-scoped rather than KubeProject-scoped.
resource "google_project_iam_member" "ci_artifact_registry_writer" {
  project = var.gcp_project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# The provisioning (crossplane) SA must READ the eso/dns SAs to OBSERVE/adopt them:
# the gcpprovider composition tracks them with managementPolicies:["Observe"], and
# Crossplane's observe path calls iam.serviceAccounts.get. serviceAccountViewer is
# read-only (get), SA-scoped — no actAs, no write, non-escalating. (The node SA is
# already covered by operator_actas_node's serviceAccountUser, which includes get.)
resource "google_service_account_iam_member" "operator_view_eso" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.serviceAccountViewer"
  member             = "serviceAccount:${google_service_account.crossplane.email}"
}

resource "google_service_account_iam_member" "operator_view_dns" {
  service_account_id = google_service_account.dns.name
  role               = "roles/iam.serviceAccountViewer"
  member             = "serviceAccount:${google_service_account.crossplane.email}"
}

# The crossplane SA must READ the gke SA to OBSERVE/adopt it (the gcpprovider composition
# tracks it with managementPolicies:["Observe"]). serviceAccountViewer is read-only (get),
# SA-scoped — no actAs, no write, non-escalating. Same rule as operator_view_eso/dns.
resource "google_service_account_iam_member" "operator_view_gke" {
  service_account_id = google_service_account.gke.name
  role               = "roles/iam.serviceAccountViewer"
  member             = "serviceAccount:${google_service_account.crossplane.email}"
}

# --- Workload-Identity binder (resource-scoped to the eso/dns/gke/ci SAs only) ---
# The four GKE WI bindings (KSA -> {org}-gcp-eso-sa / -dns-sa / -gke-sa / -ci-sa)
# reference the {projectId}.svc.id.goog pool, which GCP only materializes after the
# first GKE cluster exists. They therefore CANNOT be created at greenfield onboarding
# time; the KubePool `system` / `observability-cost` compositions create the eso/dns/gke
# bindings post-cluster (level-triggered, self-healing), and a future composition binds
# the ci SA's KSA the same way once it exists (PRD-REG-994: the CI push SA needs a
# KSA<->GSA binding too, for the same post-cluster reason). To let the operator's
# standing {org}-crossplane SA create EXACTLY those bindings and nothing more, grant it
# get/setIamPolicy on ONLY the four target SA resources (eso, dns, gke, ci) via this
# minimal custom role — the role's POWERS are unchanged (still just get/setIamPolicy);
# only its TARGETS grow, most recently by the ci SA (PRD-REG-994).
#
# Blast radius (security): get/setIamPolicy on four low-privilege runtime SAs in the
# client's own project (INV-GCP-01). Cannot create/delete/modify any SA, cannot touch
# project IAM, cannot reach any other SA. Self-impersonating eso/dns/gke via this role
# reaches nothing crossplane doesn't already hold except roles/monitoring.viewer
# (read-only) — crossplane already holds dns.admin + broader Secret Manager +
# storage.admin + container.admin. Self-impersonating the ci SA (PRD-REG-994) also
# reaches roles/artifactregistry.writer — push/pull on every Artifact Registry
# repository in the project, which crossplane's own kubecoreArtifactRegistryProvisioner
# role does NOT include (repository lifecycle only, no artifact read/write). That is a
# real, project-scoped capability gain, not merely cosmetic — it still does not reach
# project IAM, other SAs, or anything outside Artifact Registry. Documented for the
# security team alongside DEC-GCP-03.
resource "google_project_iam_custom_role" "wi_binder" {
  # The IAM API must be on before a role can be read or created. Without this the
  # provider races the enablement on a brand-new project and fails with
  # SERVICE_DISABLED, which it reports as "must be undeleted" (seen 2026-09-28).
  depends_on = [google_project_service.required]

  project     = var.gcp_project_id
  role_id     = "kubecoreWorkloadIdentityBinder"
  title       = "KubeCore Workload Identity Binder"
  description = "Crossplane SA: get/set IAM policy on the org eso/dns/gke SAs only, to create GKE Workload Identity bindings post-cluster. No create/delete; no project IAM."
  permissions = [
    "iam.serviceAccounts.getIamPolicy",
    "iam.serviceAccounts.setIamPolicy",
  ]
}

resource "google_service_account_iam_member" "crossplane_wi_binder_eso" {
  service_account_id = google_service_account.eso.name
  role               = google_project_iam_custom_role.wi_binder.name
  member             = "serviceAccount:${google_service_account.crossplane.email}"
}

resource "google_service_account_iam_member" "crossplane_wi_binder_dns" {
  service_account_id = google_service_account.dns.name
  role               = google_project_iam_custom_role.wi_binder.name
  member             = "serviceAccount:${google_service_account.crossplane.email}"
}

resource "google_service_account_iam_member" "crossplane_wi_binder_gke" {
  service_account_id = google_service_account.gke.name
  role               = google_project_iam_custom_role.wi_binder.name
  member             = "serviceAccount:${google_service_account.crossplane.email}"
}

# PRD-REG-994 Phase 2: adds the ci SA as a fourth wi_binder target so the crossplane SA
# can later create the KSA<->GSA Workload Identity binding for in-cluster CI push. The
# binder role's powers are unchanged (still just get/setIamPolicy) — only its targets grow.
resource "google_service_account_iam_member" "crossplane_wi_binder_ci" {
  service_account_id = google_service_account.ci.name
  role               = google_project_iam_custom_role.wi_binder.name
  member             = "serviceAccount:${google_service_account.crossplane.email}"
}

# --- Dedicated GitHub App credential (staged for the githubprovider composition's pull) ---
# Created only when a dedicated App is supplied. The org eso-sa already holds project-level
# secretmanager.secrets.get + versions.access (kubecoreEsoSecretWriter), so no extra IAM here.
# Secret id MUST match buildXGithubProviderParameters(): {org}-github-provider-credentials.
locals {
  stage_github_app = var.github_app_id != ""
}

resource "google_secret_manager_secret" "github_app" {
  count      = local.stage_github_app ? 1 : 0
  project    = var.gcp_project_id
  secret_id  = "${var.org_name}-github-provider-credentials"
  depends_on = [google_project_service.required]
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "github_app" {
  count  = local.stage_github_app ? 1 : 0
  secret = google_secret_manager_secret.github_app[0].id
  # Write-only: the value is sent to GCP but never persisted in Terraform state.
  secret_data_wo = jsonencode({
    appId          = var.github_app_id
    installationId = var.github_app_installation_id
    privateKey     = var.github_app_private_key
  })
  # Bumped to 2 to push a new secret version carrying installationId (added 2026-06-29).
  secret_data_wo_version = 2
}

# --- Meluxina HPC SSH key (opt-in, org-independent) ---
# Deterministic id 'meluxina-ssh-key' — IDENTICAL across all orgs (not org-prefixed):
# a single shared Meluxina institutional credential. Opt-in via enable_meluxina_ssh_key.
# The org eso-sa already holds project-level secretmanager.secrets.get + versions.access
# (kubecoreEsoSecretWriter), so no extra IAM is needed for ESO to read it.
resource "google_secret_manager_secret" "meluxina_ssh_key" {
  count      = var.enable_meluxina_ssh_key ? 1 : 0
  project    = var.gcp_project_id
  secret_id  = "meluxina-ssh-key"
  depends_on = [google_project_service.required]
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "meluxina_ssh_key" {
  count  = var.enable_meluxina_ssh_key ? 1 : 0
  secret = google_secret_manager_secret.meluxina_ssh_key[0].id
  # Write-only: the raw key bytes are sent to GCP but never persisted in Terraform state.
  secret_data_wo         = file(var.meluxina_ssh_key_path)
  secret_data_wo_version = 1

  lifecycle {
    precondition {
      condition     = trimspace(var.meluxina_ssh_key_path) != ""
      error_message = "meluxina_ssh_key_path must be set (path to the signed private key file) when enable_meluxina_ssh_key is true."
    }
  }
}
