#!/usr/bin/env bash
# Guided GCP onboarding for KAOS.
#
# Wraps the terraform module in this directory with the preflight checks and
# error interpretation an operator would otherwise have to do by hand: telling
# a project DISPLAY NAME apart from a project ID, installing terraform on a
# Cloud Shell session that does not ship it, checking the caller actually has
# the IAM permissions the module needs before wasting a plan/apply cycle, and
# recognising the "this project already hosts another KAOS org" apply failure
# and handing back the exact import commands instead of a raw GCP error.
set -euo pipefail

# Always run terraform against the files in this directory, regardless of
# where the script was invoked from (cloned repo, curl-ed single file, etc).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Defaults / flags
# ---------------------------------------------------------------------------
ORG_NAME=""
PROJECT_ID=""
PROJECT_NUMBER=""
BROKER_CLIENT_ID=""
ZITADEL_ISSUER="https://access.platform.kaos-labs.org"
ASSUME_YES="false"
PLAN_ONLY="false"

TERRAFORM_MIN_VERSION="1.7"
PINNED_TERRAFORM_VERSION="1.13.5"

usage() {
  cat <<'EOF'
Usage: onboard.sh --org NAME --project-id ID --project-number NUMBER \
                   --broker-client-id CLIENT_ID [options]

Guided onboarding of a GCP project to the KAOS platform. Runs the Terraform
module in this directory (gcp/) after checking the values it needs and the
caller's permissions, then walks through plan, confirmation, and apply.

All four required values come from the KAOS wizard's cloud step (the "Connect
GCP" screen shows the exact command to paste, prefilled for your org).

Required:
  --org NAME                 KubeOrg name (<=19 chars, lowercase alnum/hyphen).
  --project-id ID            GCP project ID (NOT the display name; see below).
  --project-number NUMBER    GCP project number (numeric).
  --broker-client-id ID      Shared broker-app OIDC client id (the WIF
                              allowed audience).

Options:
  --issuer URL                Zitadel OIDC issuer (default:
                               https://access.platform.kaos-labs.org).
  --yes                       Skip the apply confirmation prompt; also allow
                               overwriting an existing, differing
                               terraform.tfvars; also skip the Cloud Shell
                               terraform-install prompt.
  --plan-only                 Stop after "terraform plan"; do not apply.
  -h, --help                  Show this help and exit.

Project ID vs display name:
  GCP gives every project both a project ID (immutable, globally unique,
  what Terraform and this script need) and a display name (editable, can
  collide with other projects, NOT what Terraform needs). GCP appends
  digits to the ID only when your chosen name is already taken globally, so
  the two are sometimes identical and sometimes not: a project named
  "integration-test" can have the ID "integration-test-509613". Run
  `gcloud projects list` or check the GCP Console project picker if unsure.
  This script tries to catch the mismatch for you in preflight check 2.

Exit codes:
  0  success (or --plan-only completed)
  2  usage: --help, or missing/invalid flags
  1  preflight or terraform failure
EOF
}

die_usage() {
  printf '%s\n\n' "$1" >&2
  usage >&2
  exit 2
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

info() {
  printf '%s\n' "$1"
}

# ---------------------------------------------------------------------------
# Flag parsing (long form only; --flag value and --flag=value both accepted)
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --org|--project-id|--project-number|--broker-client-id|--issuer)
      [ "$#" -ge 2 ] || die_usage "Missing value for $arg"
      val="$2"
      shift 2
      ;;
    --org=*|--project-id=*|--project-number=*|--broker-client-id=*|--issuer=*)
      val="${arg#*=}"
      arg="${arg%%=*}"
      shift
      ;;
    --yes)
      ASSUME_YES="true"
      shift
      continue
      ;;
    --plan-only)
      PLAN_ONLY="true"
      shift
      continue
      ;;
    -h|--help)
      usage
      exit 2
      ;;
    *)
      die_usage "Unknown argument: $arg"
      ;;
  esac

  case "$arg" in
    --org) ORG_NAME="$val" ;;
    --project-id) PROJECT_ID="$val" ;;
    --project-number) PROJECT_NUMBER="$val" ;;
    --broker-client-id) BROKER_CLIENT_ID="$val" ;;
    --issuer) ZITADEL_ISSUER="$val" ;;
  esac
done

missing=""
[ -n "$ORG_NAME" ] || missing="${missing}  --org NAME (from the KAOS wizard's cloud step)\n"
[ -n "$PROJECT_ID" ] || missing="${missing}  --project-id ID (from the KAOS wizard's cloud step; see the project ID vs display name note in --help)\n"
[ -n "$PROJECT_NUMBER" ] || missing="${missing}  --project-number NUMBER (from the KAOS wizard's cloud step)\n"
[ -n "$BROKER_CLIENT_ID" ] || missing="${missing}  --broker-client-id ID (from the KAOS wizard's cloud step)\n"

if [ -n "$missing" ]; then
  printf 'Missing required flags:\n%b\n' "$missing" >&2
  usage >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
check() {
  # $1 = label, printed before the check runs.
  printf '[preflight] %s ... ' "$1"
}

ok() {
  printf 'ok\n'
}

fail() {
  # $1 = plain-English explanation, printed instead of a Terraform stack trace.
  printf 'FAILED\n'
  printf '%s\n' "$1" >&2
  exit 1
}

check "gcloud on PATH and an active account"
if ! command -v gcloud >/dev/null 2>&1; then
  fail "gcloud was not found on PATH. Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
fi
active_account="$(gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null || true)"
if [ -z "$active_account" ]; then
  fail "No active gcloud account. Run: gcloud auth login
Then, unless you are on Cloud Shell, also run: gcloud auth application-default login"
fi
ok

is_cloud_shell="false"
if [ -n "${CLOUDSHELL:-}" ] || [ -n "${GOOGLE_CLOUD_SHELL:-}" ] || [ -d "/google/devshell" ]; then
  is_cloud_shell="true"
fi

check "project '$PROJECT_ID' resolves"
project_describe="$(gcloud projects describe "$PROJECT_ID" --format='value(projectId,projectNumber,name)' 2>/dev/null || true)"
if [ -z "$project_describe" ]; then
  # Before giving up, see if the caller gave us a display name instead of an
  # ID. This is the single most common mistake this script exists to catch.
  by_name="$(gcloud projects list --filter="name:${PROJECT_ID}" --format='value(projectId,name)' 2>/dev/null || true)"
  match_count="$(printf '%s\n' "$by_name" | grep -c . || true)"
  if [ "$match_count" -eq 1 ]; then
    found_id="$(printf '%s\n' "$by_name" | cut -f1)"
    fail "\"${PROJECT_ID}\" is the display name of a project whose ID is \"${found_id}\". Rerun with --project-id ${found_id}."
  fi
  fail "Could not resolve project '$PROJECT_ID' with gcloud projects describe. Confirm the project ID (not display name) and that your account has access to it."
fi
ok

resolved_project_number="$(printf '%s' "$project_describe" | cut -f2)"

check "project number matches --project-number"
if [ "$resolved_project_number" != "$PROJECT_NUMBER" ]; then
  fail "Project number mismatch: you passed --project-number ${PROJECT_NUMBER}, but project '${PROJECT_ID}' actually has number ${resolved_project_number}. Rerun with --project-number ${resolved_project_number}."
fi
ok

check "billing is enabled on the project"
billing_output="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>&1 || true)"
case "$billing_output" in
  True)
    ok
    ;;
  False)
    fail "Billing is not enabled on project '${PROJECT_ID}'. Link a billing account, then rerun."
    ;;
  *)
    printf 'warning: could not check billing (insufficient permission or API error); continuing.\n'
    ;;
esac

check "caller has the required IAM permissions"
required_permissions=(
  resourcemanager.projects.setIamPolicy
  iam.serviceAccounts.create
  iam.roles.create
  iam.workloadIdentityPools.create
  serviceusage.services.enable
  secretmanager.secrets.create
)
permissions_csv="$(IFS=,; echo "${required_permissions[*]}")"
if ! permissions_test_output="$(gcloud projects test-iam-permissions "$PROJECT_ID" --permissions="$permissions_csv" --format='value(permissions)' 2>&1)"; then
  printf 'warning: could not run test-iam-permissions (%s); continuing without a permission check.\n' "$permissions_test_output"
else
  missing_permissions=""
  for perm in "${required_permissions[@]}"; do
    case "$permissions_test_output" in
      *"$perm"*) ;;
      *) missing_permissions="${missing_permissions}  ${perm}\n" ;;
    esac
  done
  if [ -n "$missing_permissions" ]; then
    fail "$(printf 'Your account is missing these permissions on %s:\n%b\nAsk your GCP admin to grant an equivalent role (e.g. roles/owner or a custom role covering these) before rerunning.' "$PROJECT_ID" "$missing_permissions")"
  fi
  ok
fi

check "terraform on PATH, version >= ${TERRAFORM_MIN_VERSION}"
terraform_ok="false"
if command -v terraform >/dev/null 2>&1; then
  tf_version="$(terraform version -json 2>/dev/null | grep -o '"terraform_version":[^,]*' | grep -o '[0-9][0-9.]*' | head -n1 || true)"
  if [ -z "$tf_version" ]; then
    tf_version="$(terraform version 2>/dev/null | head -n1 | grep -o 'v[0-9][0-9.]*' | tr -d 'v' || true)"
  fi
  if [ -n "$tf_version" ]; then
    tf_major="$(printf '%s' "$tf_version" | cut -d. -f1)"
    tf_minor="$(printf '%s' "$tf_version" | cut -d. -f2)"
    min_major="$(printf '%s' "$TERRAFORM_MIN_VERSION" | cut -d. -f1)"
    min_minor="$(printf '%s' "$TERRAFORM_MIN_VERSION" | cut -d. -f2)"
    if [ "$tf_major" -gt "$min_major" ] || { [ "$tf_major" -eq "$min_major" ] && [ "$tf_minor" -ge "$min_minor" ]; }; then
      terraform_ok="true"
    fi
  fi
fi

if [ "$terraform_ok" = "true" ]; then
  ok
else
  printf 'FAILED\n'
  if [ "$is_cloud_shell" = "true" ]; then
    printf 'terraform >= %s was not found (Cloud Shell does not preinstall it, and apt-installed packages do not survive between sessions).\n' "$TERRAFORM_MIN_VERSION"
    do_install="$ASSUME_YES"
    if [ "$do_install" != "true" ]; then
      printf 'Install pinned terraform %s into %s/bin now? [y/N] ' "$PINNED_TERRAFORM_VERSION" "$HOME"
      read -r reply || reply=""
      case "$reply" in
        y|Y|yes|YES) do_install="true" ;;
        *) do_install="false" ;;
      esac
    fi
    if [ "$do_install" != "true" ]; then
      die "terraform is required. Install it yourself, then rerun."
    fi
    install_dir="${HOME}/bin"
    mkdir -p "$install_dir"
    tmp_zip="$(mktemp -d)/terraform.zip"
    tf_url="https://releases.hashicorp.com/terraform/${PINNED_TERRAFORM_VERSION}/terraform_${PINNED_TERRAFORM_VERSION}_linux_amd64.zip"
    printf 'Downloading %s\n' "$tf_url"
    curl -fsSL -o "$tmp_zip" "$tf_url"
    unzip -o -q "$tmp_zip" -d "$install_dir"
    chmod +x "${install_dir}/terraform"
    export PATH="${install_dir}:${PATH}"
    if ! command -v terraform >/dev/null 2>&1; then
      die "terraform install into ${install_dir} did not put it on PATH. Add ${install_dir} to PATH yourself and rerun."
    fi
    printf 'Installed terraform %s into %s (persists under the home directory between Cloud Shell sessions; add %s to PATH in future sessions).\n' "$PINNED_TERRAFORM_VERSION" "$install_dir" "$install_dir"
  else
    printf 'terraform >= %s was not found on PATH. Install it: https://developer.hashicorp.com/terraform/install\n' "$TERRAFORM_MIN_VERSION" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Write terraform.tfvars
# ---------------------------------------------------------------------------
TFVARS_FILE="terraform.tfvars"
new_tfvars_content="$(cat <<EOF
# Generated by onboard.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Safe to regenerate; not committed (gitignored).
org_name             = "${ORG_NAME}"
gcp_project_id       = "${PROJECT_ID}"
gcp_project_number   = "${PROJECT_NUMBER}"
broker_app_client_id = "${BROKER_CLIENT_ID}"
zitadel_issuer       = "${ZITADEL_ISSUER}"
EOF
)"

if [ -f "$TFVARS_FILE" ]; then
  existing_content="$(cat "$TFVARS_FILE")"
  if [ "$existing_content" != "$new_tfvars_content" ] && [ "$ASSUME_YES" != "true" ]; then
    die "An existing ${TFVARS_FILE} in $(pwd) has different contents than what --org/--project-id/... would write. Refusing to overwrite without --yes. Remove or back up the file, or pass --yes, then rerun."
  fi
fi

printf '%s\n' "$new_tfvars_content" > "$TFVARS_FILE"
info "Wrote ${TFVARS_FILE}:"
printf -- '----\n%s\n----\n' "$new_tfvars_content"

# ---------------------------------------------------------------------------
# init / plan
# ---------------------------------------------------------------------------
info "Running terraform init..."
terraform init -input=false

info "Running terraform plan..."
set +e
terraform plan -input=false -out=tfplan -var-file="$TFVARS_FILE"
plan_status=$?
set -e
if [ "$plan_status" -ne 0 ]; then
  die "terraform plan failed. See the output above."
fi

plan_summary="$(terraform show -no-color tfplan 2>/dev/null | grep -E '^Plan:' || true)"
printf '\n%s\n\n' "${plan_summary:-Plan: (no changes)}"

if [ "$PLAN_ONLY" = "true" ]; then
  info "Stopping here (--plan-only). Nothing was applied."
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [ "$ASSUME_YES" != "true" ]; then
  printf '\nThis will create the KAOS identity plane (a Workload Identity Federation pool and six\n'
  printf 'service accounts) inside your project %s. It creates no GitHub App key and stores no\n' "$PROJECT_ID"
  printf 'secret in terraform.tfvars.\n\n'
  printf 'Type "apply" to proceed: '
  read -r confirmation || confirmation=""
  if [ "$confirmation" != "apply" ]; then
    printf 'nothing was created\n'
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
info "Running terraform apply..."
set +e
apply_output="$(terraform apply -input=false tfplan 2>&1)"
apply_status=$?
set -e
printf '%s\n' "$apply_output"

if [ "$apply_status" -ne 0 ]; then
  if printf '%s' "$apply_output" | grep -q 'kubecore'; then
    printf '\nIt looks like this project already hosts another KAOS organisation: the four\n'
    printf 'project-level custom roles below have fixed, org-independent ids, so Terraform\n'
    printf 'cannot create them again. Import the existing roles into this state, then rerun\n'
    printf 'terraform apply -var-file=%s:\n\n' "$TFVARS_FILE"
    printf '  terraform import google_project_iam_custom_role.crossplane_artifact_registry projects/%s/roles/kubecoreArtifactRegistryProvisioner\n' "$PROJECT_ID"
    printf '  terraform import google_project_iam_custom_role.eso_secret_writer projects/%s/roles/kubecoreEsoSecretWriter\n' "$PROJECT_ID"
    printf '  terraform import google_project_iam_custom_role.crossplane_secret_manager projects/%s/roles/kubecoreSecretManagerProvisioner\n' "$PROJECT_ID"
    printf '  terraform import google_project_iam_custom_role.wi_binder projects/%s/roles/kubecoreWorkloadIdentityBinder\n\n' "$PROJECT_ID"
  fi
  die "terraform apply failed. See the output above."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
wif_pool_id="$(terraform output -raw wif_pool_id 2>/dev/null || true)"
wif_principal="$(terraform output -raw wif_principal 2>/dev/null || true)"
crossplane_sa_email="$(terraform output -raw crossplane_sa_email 2>/dev/null || true)"
eso_sa_email="$(terraform output -raw eso_sa_email 2>/dev/null || true)"
dns_sa_email="$(terraform output -raw dns_sa_email 2>/dev/null || true)"
node_sa_email="$(terraform output -raw node_sa_email 2>/dev/null || true)"
gke_sa_email="$(terraform output -raw gke_sa_email 2>/dev/null || true)"
ci_sa_email="$(terraform output -raw ci_sa_email 2>/dev/null || true)"
state_path="$(pwd)/terraform.tfstate"

printf '\nOnboarding complete.\n\n'
printf 'WIF pool id: %s\n' "$wif_pool_id"
printf 'WIF principal: %s\n\n' "$wif_principal"
printf 'Service accounts:\n'
printf '  crossplane: %s\n' "$crossplane_sa_email"
printf '  eso:        %s\n' "$eso_sa_email"
printf '  dns:        %s\n' "$dns_sa_email"
printf '  node:       %s\n' "$node_sa_email"
printf '  gke:        %s\n' "$gke_sa_email"
printf '  ci:         %s\n\n' "$ci_sa_email"
printf 'Terraform state: %s\n' "$state_path"
printf 'Keep this file. It is what removes this setup later.\n\n'
printf 'Next: return to the KAOS wizard and run the verification probe.\n'
