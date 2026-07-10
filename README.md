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
- Your GitHub App private key (dedicated-app orgs) is written **only** to your GCP Secret
  Manager and is kept out of Terraform state (`secret_data_wo`). It never transits the KAOS UI.
- Terraform state is yours and stays local by default; configure a remote encrypted backend
  if you prefer. No secret material is stored in state.
