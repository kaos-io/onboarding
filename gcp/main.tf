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
}

resource "google_iam_workload_identity_pool" "kubecore_zitadel" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = local.wif_pool_id
  display_name              = "KubeCore Zitadel WIF"
  description               = "Trusts the Zitadel issuer; one pool per project shared by all KubeOrgs."
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

# --- ESO SA (org-shared) ---
resource "google_service_account" "eso" {
  project      = var.gcp_project_id
  account_id   = "${var.org_name}-gcp-eso-sa"
  display_name = "ESO SA for ${var.org_name}"
}

# Secret Manager: ESO PushSecret needs create/get + version add/access, NOT delete → custom role.
# roles/secretmanager.secretCreator does not exist in GCP (returns 400 in live e2e); covered by .secrets.create below.
resource "google_project_iam_custom_role" "eso_secret_writer" {
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
}

resource "google_project_iam_member" "dns_admin" {
  project = var.gcp_project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.dns.email}"
}


# --- Node SA (org-shared, replaces per-pool {pool}-node) ---
resource "google_service_account" "node" {
  project      = var.gcp_project_id
  account_id   = "${var.org_name}-node"
  display_name = "GKE node SA for ${var.org_name}"
}

resource "google_project_iam_member" "node_roles" {
  # GKE custom-node-SA documented minimum (Google "use least privilege SA for nodes"):
  # logWriter + metricWriter + monitoring.viewer + stackdriver.resourceMetadata.writer.
  # Without the latter two the gke node monitoring/metadata agents degrade silently
  # (nodes register but system components are unhealthy). artifactregistry.reader is
  # intentionally NOT included — images come from in-cluster Zot / ACR, not GCP AR (D-13).
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
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

# --- Workload-Identity binder (resource-scoped to the eso/dns SAs only) ---
# The three GKE WI bindings (KSA -> {org}-gcp-eso-sa / -dns-sa) reference the
# {projectId}.svc.id.goog pool, which GCP only materializes after the first GKE
# cluster exists. They therefore CANNOT be created at greenfield onboarding time;
# the KubePool `system` / `observability-cost` compositions create them post-cluster
# (level-triggered, self-healing). To let the operator's standing {org}-crossplane SA
# create EXACTLY those bindings and nothing more, grant it get/setIamPolicy on ONLY
# the two target SA resources via this minimal custom role.
#
# Blast radius (security): get/setIamPolicy on two low-privilege runtime SAs in the
# client's own project (INV-GCP-01). Cannot create/delete/modify any SA, cannot touch
# project IAM, cannot reach any other SA. The only capability reachable by abusing it
# (granting self impersonation on eso/dns SA) that crossplane does not already hold is
# roles/monitoring.viewer (read-only) — crossplane already holds dns.admin + broader
# Secret Manager + storage.admin + container.admin. Non-escalating; documented for the
# security team alongside DEC-GCP-03.
resource "google_project_iam_custom_role" "wi_binder" {
  project     = var.gcp_project_id
  role_id     = "kubecoreWorkloadIdentityBinder"
  title       = "KubeCore Workload Identity Binder"
  description = "Crossplane SA: get/set IAM policy on the org eso/dns SAs only, to create GKE Workload Identity bindings post-cluster. No create/delete; no project IAM."
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

# --- Dedicated GitHub App credential (staged for the githubprovider composition's pull) ---
# Created only when a dedicated App is supplied. The org eso-sa already holds project-level
# secretmanager.secrets.get + versions.access (kubecoreEsoSecretWriter), so no extra IAM here.
# Secret id MUST match buildXGithubProviderParameters(): {org}-github-provider-credentials.
locals {
  stage_github_app = var.github_app_id != ""
}

resource "google_secret_manager_secret" "github_app" {
  count     = local.stage_github_app ? 1 : 0
  project   = var.gcp_project_id
  secret_id = "${var.org_name}-github-provider-credentials"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "github_app" {
  count  = local.stage_github_app ? 1 : 0
  secret = google_secret_manager_secret.github_app[0].id
  # Write-only: the value is sent to GCP but never persisted in Terraform state.
  secret_data_wo = jsonencode({
    appId      = var.github_app_id
    privateKey = var.github_app_private_key
  })
  secret_data_wo_version = 1
}
