# Security posture & threat model — GCP onboarding

This document is the security reference for the `gcp/` onboarding Terraform. It exists so a
client's security team can review, in one place, **exactly what access is granted to the
KAOS platform, why, what is deliberately withheld, and what residual risks remain.**

> Scope of the trust decision this module represents: a client **federates their GCP project
> to the KAOS platform** so KAOS can stand up and operate an internal developer platform
> (GKE clusters, networking, DNS, GitOps credential delivery) inside that project. Running
> this module is the act of granting that access. Read this before you do.

---

## 1. Trust model (read this first)

- **Authentication is federated, not key-based.** The module creates a Workload Identity
  Federation (WIF) pool/provider that trusts the KAOS Zitadel OIDC issuer
  (`zitadel_issuer`, default `https://access.platform.kaos-labs.org`). **No service-account
  keys are ever created or exported.** KAOS assumes the project's service accounts by
  presenting a short-lived Zitadel OIDC token.
- **The identity provider is KAOS-controlled.** Because the trusted issuer is KAOS's own
  Zitadel, the ability to impersonate the service accounts below reduces to *"KAOS's Zitadel
  issues a token with the expected subject."* **You are trusting KAOS's token-issuance
  controls.** This is inherent to the delegated-operator model; it is called out here so it
  is an explicit, accepted decision rather than a hidden one.
- **The federated subject is not a secret.** The impersonation bindings are scoped to the
  subject `uuidv5(<public-namespace>, org_name)`. The namespace is public (it lives in this
  repository), so the subject value is derivable by anyone. Security therefore does **not**
  rest on the subject being unguessable — it rests on (a) Zitadel refusing to mint a token
  with that subject for anyone but the legitimate org control plane, and (b) the per-SA IAM
  bindings. A token that federates into the pool **without** a matching SA binding obtains no
  permissions.
- **Blast radius is the target GCP project.** Every grant in this module is project-scoped.
  The design assumes a **dedicated, empty project per org** (`INV-GCP-01`). That assumption
  is *not enforced by Terraform* — see §4.1.

---

## 2. What is granted (identity inventory)

The module creates four service accounts. None have exported keys; all are assumed via WIF.

| Service account | Purpose | Project roles | Notable capability |
|---|---|---|---|
| `{org}-crossplane` | Infra provisioner (Crossplane) | `compute.networkAdmin`, `compute.securityAdmin`, `container.admin`, `dns.admin`, `storage.admin`, + custom `kubecoreSecretManagerProvisioner`, + custom `kubecoreWorkloadIdentityBinder` (on eso/dns SAs only), + `serviceAccountUser`/`Viewer` on node/eso/dns SAs | **`container.admin` grants in-cluster `cluster-admin`** on GKE clusters via the IAM→`system:masters` bridge. Impersonable by KAOS. |
| `{org}-gcp-eso-sa` | External Secrets Operator | custom `kubecoreEsoSecretWriter`, `monitoring.viewer` (+ BigQuery reader/jobUser **only if** `enable_cost_export=true`) | Project-wide `secretmanager.versions.access` (read any secret). Impersonable by KAOS. |
| `{org}-gcp-dns-sa` | ExternalDNS | `dns.admin` | Full Cloud DNS control in the project. |
| `{org}-node` | GKE node identity | `logging.logWriter`, `monitoring.metricWriter`, `monitoring.viewer`, `stackdriver.resourceMetadata.writer` | Documented GKE least-privilege node set. Not impersonable by KAOS. |

**Impersonation grants (WIF → SA):**
- KAOS (`wif_principal`) → `serviceAccountTokenCreator` on `{org}-crossplane`.
- KAOS (`wif_principal`) → `workloadIdentityUser` on `{org}-gcp-eso-sa`.

**Secrets staged (optional):**
- `{org}-github-provider-credentials` — dedicated GitHub App creds (opt-in via `github_app_id`).
- `meluxina-ssh-key` — Meluxina HPC key (opt-in via `enable_meluxina_ssh_key`). **Deterministic,
  org-independent id: the same shared institutional credential is staged in every tenant's
  project.**

Secret *values* are written with write-only `secret_data_wo` and **never persist in Terraform
state**.

---

## 3. Protections designed in (what the module deliberately does right)

These are compensating controls the security team can credit:

1. **No exported SA keys** — WIF only; no long-lived key material to leak.
2. **No project-IAM self-escalation** — **no** SA holds `resourcemanager.projects.setIamPolicy`
   or any `owner`/IAM-admin role. A compromised/abused KAOS identity **cannot grant itself or
   anyone else additional _project_ roles.** Escalation is bounded to resource-level policy on
   the resource types below (§4.3).
3. **Secret values out of state** — `secret_data_wo` (requires provider `>= 6.23`).
4. **Least-privilege custom roles** where feasible:
   - `kubecoreSecretManagerProvisioner` and `kubecoreEsoSecretWriter` **deliberately omit
     `secretmanager.*.setIamPolicy`** — neither SA can grant a principal access to a secret.
   - `kubecoreWorkloadIdentityBinder` grants `get/setIamPolicy` on **only the eso/dns SA
     resources**, not project IAM.
5. **Minimal node SA** — the GKE node identity holds only the documented telemetry-writer set;
   `artifactregistry.reader` is intentionally excluded.
6. **Input validation** — `org_name` is length- and charset-constrained.
7. **SA-scoped impersonation** — impersonation bindings target specific SA resources, not
   project-wide `iam.serviceAccountTokenCreator`.

---

## 4. Known concerns & open questions (for the security review)

Ordered by severity. Each item states the concern and the question a reviewer should ask.
Nothing here is a claim that the platform is unsafe — these are the accepted risks and the
decisions that require sign-off.

### 4.1 Safety depends on the "dedicated project" invariant, which Terraform does not enforce — HIGH
Every grant is a **project-scoped predefined role** (`storage.admin`, `container.admin`,
`compute.networkAdmin`/`securityAdmin`, `dns.admin`, project-wide secret read). If this module
is applied to a project that already contains other workloads, KAOS can read/modify **every**
bucket, GKE cluster, DNS zone, firewall, and secret in it.
- **Q:** What guarantees the target project is empty/dedicated (org policy, naming guardrail,
  pre-flight check)? What is the blast radius if it is not?

### 4.2 Tenant isolation rests on KAOS-side token issuance — HIGH
The WIF provider trusts the entire Zitadel issuer, the audience (`broker_app_client_id`) is
**shared across all orgs**, the subject is publicly derivable, and the provider has **no
`attribute_condition`**.
- **Q:** What prevents a KAOS insider — or a compromise of KAOS's Zitadel — from minting a
  token for our org's subject and assuming `crossplane`/`eso` in our project? Why is the
  audience shared rather than per-org? Can an `attribute_condition` be added to reject
  unexpected subjects/claims at the pool door?

### 4.3 Resource-level privilege delegation is available (despite the "no-setIamPolicy" note) — HIGH
The `crossplane` SA — impersonable by KAOS — holds `storage.admin` (includes
`storage.buckets.setIamPolicy`), `compute.securityAdmin` (firewall control), and `dns.admin`.
So while it cannot touch *project* IAM (§3.2) or *secret* IAM (§3.4), it **can** grant an
external principal access to a bucket, or open a firewall to the internet — a data-exfil /
network-exposure path. The "security-clean / no privilege delegation" framing in the code
comments is true **only for secrets**.
- **Q:** Can `storage.admin` and the compute/DNS admin roles be scoped (IAM Conditions,
  per-bucket/zone) so resource-level `setIamPolicy` is not project-wide?

### 4.4 `container.admin` = standing cluster-admin on all GKE clusters — HIGH
Via GKE's IAM→`system:masters` bridge, anyone who can impersonate `crossplane` (i.e. KAOS) has
in-cluster root on every GKE cluster in the project.
- **Q:** Is this scoped to KAOS-managed clusters or project-wide? Can a narrower role + explicit
  RBAC replace `container.admin`?

### 4.5 Project-wide secret read on two impersonable SAs — HIGH
Both `crossplane` and `eso` can read **every** secret in the project, not just KAOS's.
- **Q:** Can secret access be scoped by resource (condition on `{org}-*` / `meluxina-*`
  prefixes) instead of project-wide `versions.access`?

### 4.6 Shared Meluxina credential across all tenants — MEDIUM
One signed HPC private key, identical value, is replicated into every client project and is
readable by that project's KAOS SAs. Compromise of any **single** client project leaks the
shared credential for **all** Meluxina users.
- **Q:** Why a shared institutional key per tenant rather than per-org keys? What is the
  rotation/revocation story after a breach?

### 4.7 Broader-than-needed federation role for crossplane — MEDIUM
KAOS→`crossplane` uses `serviceAccountTokenCreator` (includes `signBlob`/`signJwt`), while
KAOS→`eso` uses the narrower, standard `workloadIdentityUser`.
- **Q:** Why not `workloadIdentityUser` for both?

### 4.8 Terraform state & plan hygiene — MEDIUM
State is **local** by default (no remote backend, no locking, no encryption at rest) and lives
with whoever runs the apply. Secret values are write-only (not in state), but resource metadata
is. Historical state artifacts may accumulate in the working directory.
- **Q:** Where does state live, who holds it, is it encrypted, and are stray `*.tfstate.*`
  backups handled?

### 4.9 Offboarding / revocation is undefined — MEDIUM
`disable_on_destroy = false` leaves APIs enabled; SAs and grants persist. There is no documented
"cut KAOS off completely" procedure.
- **Q:** How does a client fully revoke KAOS access and verify it is gone? (See §6.)

### 4.10 No cost/DoS or egress guardrails — MEDIUM
With `container.admin` + `compute.*Admin`, an abused identity can create expensive compute
(crypto-mining) or egress data. The module sets no VPC Service Controls, budgets, or quotas.
- **Q:** Are VPC-SC / budget alerts / quotas required as compensating controls?

### 4.11 Hygiene — LOW
- No IAM Conditions anywhere (underlies 4.1/4.3/4.5).
- No Cloud Audit **Data Access** logging enabled for these high-privilege SAs — limits
  after-the-fact attribution.
- `eso` holds `serviceAccountTokenCreator` **on itself** (self-impersonation) — benign but
  worth an explicit justification.
- Secret replication is `auto{}` (Google multi-region); for EU-residency (e.g. the Meluxina
  key) consider `user_managed` pinned regions.
- `gcp_project_id` / `gcp_project_number` are unvalidated.

---

## 5. Residual risk summary

The design **prevents project-IAM self-escalation and avoids exported keys**, which closes the
most severe standing-credential and escalation paths. The accepted residual risks are:

1. **Delegated trust in KAOS's Zitadel** for token issuance (§4.2).
2. **Project-scoped, not resource-scoped, privileges** — safe only under the dedicated-project
   invariant (§4.1), with resource-level delegation and cluster-admin reachable by the
   KAOS-impersonable `crossplane` SA (§4.3, §4.4).
3. **A shared Meluxina credential** replicated per-tenant (§4.6).

These are the items requiring explicit sign-off before onboarding a production project.

---

## 6. Revoking KAOS access

To cut KAOS off from a project (until a first-class offboarding path exists):

1. **Break federation** — delete the WIF pool/provider (`{org}-kaosid`) or remove the
   `serviceAccountTokenCreator`/`workloadIdentityUser` bindings on `{org}-crossplane` and
   `{org}-gcp-eso-sa`. This alone stops all KAOS impersonation immediately.
2. **Remove standing identities** — delete the `{org}-crossplane`, `-gcp-eso-sa`, `-gcp-dns-sa`,
   `-node` service accounts and their role bindings.
3. **Rotate staged secrets** — rotate the GitHub App key and the **shared Meluxina key** (the
   latter affects all tenants).
4. `terraform destroy` performs 1–2 but leaves APIs enabled (`disable_on_destroy = false`) and
   does not rotate secrets — do steps 3 manually.

---

## 7. Reporting a vulnerability

Report suspected vulnerabilities in this onboarding module privately to the KAOS security
contact rather than opening a public issue. Include the module path (`gcp/`), the affected
resource, and a description of the impact.
