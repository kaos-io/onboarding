# KAOS Onboarding (client-run Terraform)

Run **once per KubeOrg, in your own GCP project, by an IAM-admin**, before you create the
KubeOrg. It pre-creates the per-org identity plane (a dedicated Workload Identity Federation
pool/provider named `<org>-kaosid`, the `<org>-crossplane`/`-gcp-eso-sa`/`-gcp-dns-sa`/`-node`
service accounts, narrowed IAM + Workload-Identity bindings) so the KAOS control plane needs
**zero standing IAM-admin access** to your project — it federates keyless via OIDC.

## Clouds
- `gcp/` — supported. See `gcp/README.md`.
- `azure/` — supported. See `azure/README.md`.
- `aws/` — coming soon.

## Security
- Keyless: no service-account keys are created or exported. The control plane impersonates
  `<org>-crossplane` only via a deterministic federated subject.
- Your GitHub App private key is delivered by GitHub straight to the KAOS control plane when
  you create the App, held there until your cloud account is federated and verified, then
  written into your own secret store (`<org>-github-provider-credentials`) by the same
  `<org>-crossplane` identity this module federates, and removed from the KAOS side. It never
  transits this Terraform or the KAOS UI. Legacy: the `github_app_*` input variables in `gcp/`
  and `azure/` still exist, deprecated and empty by default, for orgs onboarded before this
  changed.
- Terraform state is yours and stays local by default; configure a remote encrypted backend
  if you prefer. No secret material is stored in state.
