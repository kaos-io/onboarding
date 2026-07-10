locals {
  # Must match internal/operators/kubeorg/phases/reconciling.go DeterministicUserID():
  # UUIDv5(namespace=7b3f9d2c-1e84-4a6b-9c5d-2f8a0e6b4d13, org_name)
  # Parity check: org "acme" -> ad262e82-8256-5e2e-899e-3d8c40832b54
  # A change to this namespace or to DeterministicUserID()'s UUIDv5 call MUST be mirrored on both sides.
  zitadel_sub = uuidv5("7b3f9d2c-1e84-4a6b-9c5d-2f8a0e6b4d13", var.org_name)

  # Names MUST match the azureprovider composition (it observes these objects):
  #   RG:   crossplane.io/external-name "rg-kaos-{org}"
  #   UAMI: forProvider.name "{org}-eso-uami"
  #   KV:   external-name "{org}-{sha256(subscriptionId)|trunc6}" (CON-AZ-01, revised 2026-05-01)
  rg_name              = "rg-kaos-${var.org_name}"
  crossplane_uami_name = "${var.org_name}-crossplane"
  eso_uami_name        = "${var.org_name}-eso-uami"
  kv_name              = var.key_vault_name_override != "" ? var.key_vault_name_override : "${var.org_name}-${substr(sha256(var.subscription_id), 0, 6)}"

  # Secret id MUST match buildXGithubProviderParameters(): {org}-github-provider-credentials
  github_secret_name = "${var.org_name}-github-provider-credentials"
  stage_github_app   = var.github_app_id != ""

  subscription_scope = "/subscriptions/${var.subscription_id}"
}
