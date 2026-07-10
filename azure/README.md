# Azure org onboarding (Terraform)

Run once per KubeOrg, in your Azure subscription, by a subscription admin, before creating the
KubeOrg.

## What this creates

Identity plane provisioned per org (all in a single foundation resource group):

| Resource                                    | Name                              | Purpose                                                                        |
|------------------------------------------------|------------------------------------|---------------------------------------------------------------------------------|
| `azurerm_resource_group.org`                  | `rg-kaos-{org}`                    | Org foundation RG; observed by the azureprovider composition                    |
| `azurerm_user_assigned_identity.crossplane`   | `{org}-crossplane`                 | Standing provisioning identity; federates via Zitadel FIC (broker audience)     |
| `azurerm_user_assigned_identity.eso`          | `{org}-eso-uami`                   | ESO workload identity; FIC subject owned by the azureprovider composition       |
| `azurerm_key_vault.org`                       | `{org}-{hash6}`                    | TF-owned org Key Vault, RBAC-authorized, purge-protected                        |
| `azurerm_key_vault_secret.github_app`         | `{org}-github-provider-credentials`| Dedicated GitHub App `{appId,installationId,privateKey}`; only when staged      |
| `azurerm_role_definition.rg_lifecycle`        | `kaos-{org}-rg-lifecycle`          | Custom role: subscription-scoped RG create/read/delete (AKS per-cluster RGs)    |
| `azurerm_role_assignment.crossplane_roles`    | —                                   | Subscription-scoped builtin provisioning roles on the crossplane UAMI          |
| `azurerm_role_assignment.crossplane_eso_fic_writer` | —                             | FIC-writer grant scoped to the ESO UAMI only (composition manages its FIC)      |
| `azurerm_role_assignment.eso_kv_officer`      | —                                   | Resource-scoped Key Vault Secrets Officer for ESO on the org KV                 |
| `azurerm_role_assignment.eso_dns_contributor` | —                                   | RG-scoped DNS Zone Contributor for ESO                                          |

This replaces the legacy subscription-scope Owner grant with subscription- and
resource-scoped least-privilege roles.

## Prerequisites

- An Azure subscription (`subscription_id`) and its AD tenant (`tenant_id`).
- Run by a principal with `Microsoft.Authorization/roleDefinitions/write` at subscription scope
  — i.e. **Owner** or **User Access Administrator** — since the module creates a custom role
  definition and grants both builtin and custom role assignments.
- `az login` to the target subscription before running Terraform:
  ```bash
  az login
  az account set --subscription <SUBSCRIPTION_ID>
  ```

## Run

```bash
git clone https://github.com/kaos-io/onboarding
cd onboarding/azure

# Save the terraform.tfvars the KAOS dashboard generated (see terraform.tfvars.example) here, then:
terraform init
terraform apply -var-file=terraform.tfvars

# Dedicated-app orgs: pass the GitHub App id/installation/key at apply time (kept out of
# terraform.tfvars and out of state — do NOT put PEM material in the tfvars file):
#   terraform apply -var-file=terraform.tfvars \
#     -var "github_app_id=123456" \
#     -var "github_app_installation_id=987654" \
#     -var "github_app_private_key=$(cat /path/to/key.pem)"
```

Re-running is a no-op (idempotent).

## Outputs -> KubeOrg mapping

| Output                       | KubeOrg field                        |
|-------------------------------|---------------------------------------|
| `crossplane_uami_client_id`   | `spec.azureConfig.clientId`            |
| `tenant_id`                   | `spec.azureConfig.tenantId`            |
| `subscription_id`              | `spec.azureConfig.subscriptionId`      |
| — (by convention, not an output) | `spec.azureConfig.providerConfig` = `{org}-azure` |

`zitadel_sub`, `resource_group_name`, `key_vault_name`, and `github_app_secret_name` are not fed
into the KubeOrg spec directly — they exist for the parity checks below and for the
azureprovider composition, which observes the RG/KV/UAMIs by their deterministic names.

## Parity

The azureprovider composition **observes** (does not create) the TF-owned resource group,
ESO UAMI, and Key Vault by exact name. Two formulas must stay in sync between this module and
the operator/composition:

- `terraform output zitadel_sub` MUST equal the operator's `DeterministicUserID(org_name)`
  — both sides compute `UUIDv5(namespace=7b3f9d2c-1e84-4a6b-9c5d-2f8a0e6b4d13, org_name)`. A
  change to this namespace or to `DeterministicUserID()`'s UUIDv5 call MUST be mirrored on
  both sides.
- The Key Vault name MUST equal `{org}-{substr(sha256(subscriptionId), 0, 6)}` — a change to
  this formula on either side (this module's `local.kv_name` or the composition's observed
  external-name) breaks the observe path and MUST be mirrored on both.

Verify: org `acme` -> sub `ad262e82-8256-5e2e-899e-3d8c40832b54` (subscription id dependent for
the KV hash, so no fixed golden vector for `key_vault_name`).

## Role-set extension rule

`local.crossplane_subscription_roles` (Network Contributor, Azure Kubernetes Service Contributor
Role, DNS Zone Contributor, Key Vault Contributor) is the working set derived from the
composition audit. Extend this list **only** on a verified `AuthorizationFailed` error observed
during a live Stage-1/Stage-2 run — never speculatively. Record every addition here:

- (none yet — initial working set as of this module's authoring)

## Security

- The onboarding runner needs only a transient Key Vault Secrets Officer grant to stage the
  GitHub App secret at apply time; no long-lived elevated credential is created for it.
- The dedicated GitHub App private key is staged **write-only** (`value_wo` /
  `value_wo_version`) — it reaches Key Vault but is never persisted in Terraform state.
- No service-principal secrets or static cloud keys are created. The control plane
  authenticates keyless via Zitadel-issued OIDC tokens federated into the `{org}-crossplane`
  UAMI (`azurerm_federated_identity_credential`), audience-scoped to the shared broker
  clientId.
- The org Key Vault has purge protection **on** and a 7-day soft-delete retention, and is
  intentionally left out of any destroy path that would purge it — it is designed to survive
  KubeOrg/org deletion so secret history isn't lost to an accidental teardown.
