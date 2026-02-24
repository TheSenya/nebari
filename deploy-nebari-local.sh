#!/usr/bin/env bash
#
# deploy-nebari-local.sh
# ======================
# Deploys Nebari locally using Terraform (not OpenTofu).
# Creates a Kind cluster with all Nebari services.
#
# Usage:
#   ./deploy-nebari-local.sh                 Deploy all stages
#   ./deploy-nebari-local.sh --plan-only     Plan only (no apply)
#   ./deploy-nebari-local.sh --destroy       Destroy in reverse order
#   ./deploy-nebari-local.sh --stage N       Deploy only stage N (e.g. --stage 02)
#   ./deploy-nebari-local.sh --from-stage N  Start from stage N onward
#
# Prerequisites:
#   terraform >= 1.0, docker, kind, kubectl, helm, jq
#
set -euo pipefail

###############################################################################
# CONFIGURATION — Modify these values to match your environment
###############################################################################

PROJECT_NAME="nebari-test"
NAMESPACE="dev"
NEBARI_VERSION="2025.10.1"
KEYCLOAK_ROOT_PASSWORD="8jqhgj12n6o5d8l6drzwrjstm0b6sx5g"

# Container image references — update tags for your Nebari version
JUPYTERHUB_IMAGE="quay.io/nebari/nebari-jupyterhub"
JUPYTERLAB_IMAGE="quay.io/nebari/nebari-jupyterlab"
DASK_WORKER_IMAGE="quay.io/nebari/nebari-dask-worker"
CONDA_STORE_IMAGE="quay.io/nebari/nebari-conda-store"
CONDA_STORE_TAG="${NEBARI_VERSION}"
TRAEFIK_IMAGE="traefik"
TRAEFIK_TAG="2.11"
WORKFLOW_CONTROLLER_TAG="${NEBARI_VERSION}"

# Resource settings
SHARED_STORAGE_GB=10
CONDA_STORE_STORAGE="20Gi"
CONDA_STORE_OBJ_STORAGE="20Gi"

# Feature toggles (set to true/false)
MONITORING_ENABLED=false
ARGO_WORKFLOWS_ENABLED=false
JHUB_APPS_ENABLED=false
JUPYTERLAB_PIONEER_ENABLED=false
NEBARI_WORKFLOW_CONTROLLER=false
SHARED_FS_TYPE="nfs"   # "nfs" or "cephfs"

# Node selectors (for local Kind, all use the same selector)
NODE_SELECTOR_KEY="kubernetes.io/os"
NODE_SELECTOR_VALUE="linux"

###############################################################################
# INTERNAL VARIABLES — Do not modify
###############################################################################

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGES_DIR="${BASE_DIR}/stages"
STATE_DIR="${BASE_DIR}/terraform-state"
GENERATED_DIR="${BASE_DIR}/.generated"
KUBECONFIG_PATH="${STATE_DIR}/kubeconfig"

PLAN_ONLY=false
DESTROY=false
SINGLE_STAGE=""
FROM_STAGE=""

# Outputs captured between stages
LB_ADDRESS=""
ENDPOINT=""
REALM_ID=""
KC_BOT_PASSWORD=""
KC_RO_USERNAME=""
KC_RO_PASSWORD=""
FORWARDAUTH_MIDDLEWARE=""
CERT_SECRET_NAME="nebari-tls-cert"

###############################################################################
# COLORS & LOGGING
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_header()  { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

###############################################################################
# ARGUMENT PARSING
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan-only)  PLAN_ONLY=true; shift ;;
            --destroy)    DESTROY=true; shift ;;
            --stage)      SINGLE_STAGE="$2"; shift 2 ;;
            --from-stage) FROM_STAGE="$2"; shift 2 ;;
            --help|-h)    usage; exit 0 ;;
            *)            log_error "Unknown argument: $1"; usage; exit 1 ;;
        esac
    done
}

usage() {
    cat <<'EOF'
Usage: deploy-nebari-local.sh [OPTIONS]

Options:
  --plan-only       Run terraform plan only (no apply)
  --destroy         Destroy all resources in reverse order
  --stage N         Run only stage N (e.g., 02, 07)
  --from-stage N    Start from stage N onward
  --help, -h        Show this help message

Examples:
  ./deploy-nebari-local.sh                  # Full deployment
  ./deploy-nebari-local.sh --plan-only      # Dry run
  ./deploy-nebari-local.sh --stage 02       # Only stage 02
  ./deploy-nebari-local.sh --from-stage 05  # From stage 05 onward
  ./deploy-nebari-local.sh --destroy        # Tear down everything
EOF
}

###############################################################################
# PREREQUISITES CHECK
###############################################################################

check_prerequisites() {
    log_header "Checking Prerequisites"

    local missing=()

    for cmd in terraform docker kind kubectl jq; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            case "$cmd" in
                terraform) ver=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1) ;;
                docker)    ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',') ;;
                kind)      ver=$(kind version 2>/dev/null) ;;
                kubectl)   ver=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "unknown") ;;
                jq)        ver=$(jq --version 2>/dev/null) ;;
            esac
            log_success "$cmd found: $ver"
        else
            log_error "$cmd is NOT installed"
            missing+=("$cmd")
        fi
    done

    # Optional: helm (needed for some stages)
    if command -v helm &>/dev/null; then
        log_success "helm found: $(helm version --short 2>/dev/null)"
    else
        log_warn "helm not found (optional, but recommended)"
    fi

    # Check Docker is running
    if ! docker info &>/dev/null; then
        log_error "Docker is not running. Please start Docker first."
        missing+=("docker-running")
    else
        log_success "Docker daemon is running"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites: ${missing[*]}"
        log_info "Install missing tools before continuing."
        exit 1
    fi

    # Create directories
    mkdir -p "${STATE_DIR}"
    mkdir -p "${GENERATED_DIR}"
    log_success "All prerequisites satisfied"
}

###############################################################################
# TERRAFORM HELPER FUNCTIONS
###############################################################################

# Generate _nebari.tf.json with provider config for a stage
# Args: $1 = stage directory, $2 = "with_keycloak" (optional)
generate_provider_config() {
    local stage_dir="$1"
    local with_keycloak="${2:-}"
    local config_file="${stage_dir}/_nebari.tf.json"

    local provider_json
    provider_json=$(cat <<PROVEOF
{
  "provider": {
    "kubernetes": {
      "config_path": "${KUBECONFIG_PATH}"
    },
    "helm": {
      "kubernetes": {
        "config_path": "${KUBECONFIG_PATH}"
      }
    }
  }
}
PROVEOF
)
    echo "$provider_json" > "$config_file"
    log_info "Generated provider config: ${config_file}"
}

# Run terraform init + plan + apply for a stage
# Args: $1 = stage_dir, $2 = stage_name, $3 = tfvars_file (optional)
run_terraform() {
    local stage_dir="$1"
    local stage_name="$2"
    local tfvars_file="${3:-}"

    log_info "Initializing Terraform for ${stage_name}..."
    terraform -chdir="${stage_dir}" init -input=false -reconfigure 2>&1 | tail -3

    local var_file_arg=""
    if [[ -n "$tfvars_file" && -f "$tfvars_file" ]]; then
        var_file_arg="-var-file=${tfvars_file}"
    fi

    log_info "Planning ${stage_name}..."
    if [[ -n "$var_file_arg" ]]; then
        terraform -chdir="${stage_dir}" plan -input=false ${var_file_arg} -out=tfplan
    else
        terraform -chdir="${stage_dir}" plan -input=false -out=tfplan
    fi

    if [[ "$PLAN_ONLY" == "true" ]]; then
        log_success "Plan complete for ${stage_name} (plan-only mode)"
        return 0
    fi

    log_info "Applying ${stage_name}..."
    terraform -chdir="${stage_dir}" apply -input=false tfplan
    log_success "${stage_name} applied successfully"
}

# Run terraform destroy for a stage
# Args: $1 = stage_dir, $2 = stage_name, $3 = tfvars_file (optional)
run_terraform_destroy() {
    local stage_dir="$1"
    local stage_name="$2"
    local tfvars_file="${3:-}"

    if [[ ! -f "${stage_dir}/terraform.tfstate" && ! -d "${stage_dir}/.terraform" ]]; then
        log_warn "No state found for ${stage_name}, skipping destroy"
        return 0
    fi

    log_info "Destroying ${stage_name}..."
    terraform -chdir="${stage_dir}" init -input=false -reconfigure 2>&1 | tail -3

    local var_file_arg=""
    if [[ -n "$tfvars_file" && -f "$tfvars_file" ]]; then
        var_file_arg="-var-file=${tfvars_file}"
    fi

    if [[ -n "$var_file_arg" ]]; then
        terraform -chdir="${stage_dir}" destroy -input=false -auto-approve ${var_file_arg}
    else
        terraform -chdir="${stage_dir}" destroy -input=false -auto-approve
    fi
    log_success "${stage_name} destroyed"
}

# Get terraform output as JSON
# Args: $1 = stage_dir, $2 = output_name
get_tf_output() {
    local stage_dir="$1"
    local output_name="$2"
    terraform -chdir="${stage_dir}" output -json "$output_name" 2>/dev/null
}

###############################################################################
# STAGE 01: Terraform State (Local — No-Op)
###############################################################################

run_stage_01() {
    log_header "Stage 01: Terraform State (Local)"
    local stage_dir="${STAGES_DIR}/01-terraform-state/local"

    log_info "Local state backend — no Terraform resources to create."
    log_info "State files will be stored in each stage directory."
    log_success "Stage 01 complete (no-op for local deployment)"
}

destroy_stage_01() {
    log_header "Stage 01: Terraform State (Destroy)"
    log_info "Nothing to destroy for local state backend."
}

###############################################################################
# STAGE 02: Infrastructure — Kind Cluster + MetalLB
###############################################################################

run_stage_02() {
    log_header "Stage 02: Infrastructure (Kind Cluster + MetalLB)"
    local stage_dir="${STAGES_DIR}/02-infrastructure/local"
    local tfvars_file="${GENERATED_DIR}/stage-02.tfvars.json"

    # Generate tfvars
    cat > "$tfvars_file" <<TFEOF
{
  "kubeconfig_filename": "${KUBECONFIG_PATH}",
  "kube_context": ""
}
TFEOF

    # Docker 29.x requires API >= 1.44; the docker provider defaults to 1.41
    export DOCKER_API_VERSION="1.44"

    run_terraform "$stage_dir" "Stage 02 - Infrastructure" "$tfvars_file"

    if [[ "$PLAN_ONLY" != "true" ]]; then
        # Capture outputs
        KUBECONFIG_PATH=$(get_tf_output "$stage_dir" "kubeconfig_filename" | jq -r '.')
        export KUBECONFIG="${KUBECONFIG_PATH}"
        log_info "KUBECONFIG set to: ${KUBECONFIG_PATH}"

        # Wait for cluster to be ready
        log_info "Waiting for Kind cluster to be ready..."
        kubectl wait --for=condition=Ready nodes --all --timeout=120s
        log_success "Kind cluster is ready"

        # Wait for MetalLB to be ready
        log_info "Waiting for MetalLB pods..."
        kubectl wait --for=condition=Ready pods --all -n metallb-system --timeout=180s 2>/dev/null || true
        sleep 5
        log_success "MetalLB is running"
    fi
}

destroy_stage_02() {
    log_header "Stage 02: Infrastructure (Destroy)"
    local stage_dir="${STAGES_DIR}/02-infrastructure/local"
    local tfvars_file="${GENERATED_DIR}/stage-02.tfvars.json"
    run_terraform_destroy "$stage_dir" "Stage 02 - Infrastructure" "$tfvars_file"
}

###############################################################################
# STAGE 03: Kubernetes Initialize — Namespace + Traefik CRDs
###############################################################################

run_stage_03() {
    log_header "Stage 03: Kubernetes Initialize"
    local stage_dir="${STAGES_DIR}/03-kubernetes-initialize"
    local tfvars_file="${GENERATED_DIR}/stage-03.tfvars.json"

    # Generate provider config
    generate_provider_config "$stage_dir"

    # Generate tfvars
    cat > "$tfvars_file" <<TFEOF
{
  "name": "${PROJECT_NAME}",
  "environment": "${NAMESPACE}",
  "cloud_provider": "local",
  "aws_region": "",
  "external_container_reg": {
    "enabled": false,
    "access_key_id": "",
    "secret_access_key": "",
    "extcr_account": "",
    "extcr_region": ""
  },
  "gpu_enabled": false,
  "gpu_node_group_names": []
}
TFEOF

    run_terraform "$stage_dir" "Stage 03 - Kubernetes Initialize" "$tfvars_file"
}

destroy_stage_03() {
    log_header "Stage 03: Kubernetes Initialize (Destroy)"
    local stage_dir="${STAGES_DIR}/03-kubernetes-initialize"
    local tfvars_file="${GENERATED_DIR}/stage-03.tfvars.json"
    generate_provider_config "$stage_dir"
    run_terraform_destroy "$stage_dir" "Stage 03" "$tfvars_file"
}

###############################################################################
# STAGE 04: Kubernetes Ingress — Traefik
###############################################################################

run_stage_04() {
    log_header "Stage 04: Kubernetes Ingress (Traefik)"
    local stage_dir="${STAGES_DIR}/04-kubernetes-ingress"
    local tfvars_file="${GENERATED_DIR}/stage-04.tfvars.json"

    # Generate provider config
    generate_provider_config "$stage_dir"

    # Generate tfvars
    cat > "$tfvars_file" <<TFEOF
{
  "name": "${PROJECT_NAME}",
  "environment": "${NAMESPACE}",
  "node_groups": {
    "general": {
      "key": "${NODE_SELECTOR_KEY}",
      "value": "${NODE_SELECTOR_VALUE}"
    },
    "user": {
      "key": "${NODE_SELECTOR_KEY}",
      "value": "${NODE_SELECTOR_VALUE}"
    },
    "worker": {
      "key": "${NODE_SELECTOR_KEY}",
      "value": "${NODE_SELECTOR_VALUE}"
    }
  },
  "traefik-image": {
    "image": "${TRAEFIK_IMAGE}",
    "tag": "${TRAEFIK_TAG}"
  },
  "certificate-service": "self-signed"
}
TFEOF

    run_terraform "$stage_dir" "Stage 04 - Kubernetes Ingress" "$tfvars_file"

    if [[ "$PLAN_ONLY" != "true" ]]; then
        # Capture the load balancer address
        log_info "Waiting for Traefik load balancer IP..."
        local retries=30
        while [[ $retries -gt 0 ]]; do
            LB_ADDRESS=$(kubectl get svc -n "${NAMESPACE}" -l app=traefik -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
            if [[ -n "$LB_ADDRESS" ]]; then
                break
            fi
            retries=$((retries - 1))
            sleep 5
        done

        if [[ -z "$LB_ADDRESS" ]]; then
            # Try getting from terraform output
            LB_ADDRESS=$(get_tf_output "$stage_dir" "load_balancer_address" 2>/dev/null | jq -r '.' 2>/dev/null || true)
        fi

        if [[ -z "$LB_ADDRESS" || "$LB_ADDRESS" == "null" ]]; then
            log_warn "Could not detect load balancer IP automatically."
            log_warn "Trying to determine from MetalLB IP range..."
            LB_ADDRESS=$(kubectl get svc -n "${NAMESPACE}" -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        fi

        if [[ -z "$LB_ADDRESS" || "$LB_ADDRESS" == "null" ]]; then
            log_error "Failed to get load balancer IP. Check MetalLB configuration."
            log_info "You can set the endpoint manually and re-run from stage 05."
            exit 1
        fi

        ENDPOINT="${LB_ADDRESS}.nip.io"
        log_success "Load Balancer IP: ${LB_ADDRESS}"
        log_success "Endpoint: ${ENDPOINT}"

        # Save endpoint for later stages
        echo "${ENDPOINT}" > "${STATE_DIR}/endpoint"
        echo "${LB_ADDRESS}" > "${STATE_DIR}/lb_address"
    fi
}

destroy_stage_04() {
    log_header "Stage 04: Kubernetes Ingress (Destroy)"
    local stage_dir="${STAGES_DIR}/04-kubernetes-ingress"
    local tfvars_file="${GENERATED_DIR}/stage-04.tfvars.json"
    generate_provider_config "$stage_dir"
    run_terraform_destroy "$stage_dir" "Stage 04" "$tfvars_file"
}

###############################################################################
# STAGE 05: Keycloak Deployment
###############################################################################

run_stage_05() {
    log_header "Stage 05: Keycloak Deployment"
    local stage_dir="${STAGES_DIR}/05-kubernetes-keycloak"
    local tfvars_file="${GENERATED_DIR}/stage-05.tfvars.json"

    # Load endpoint if not set (when running from a specific stage)
    load_saved_state

    # Generate provider config
    generate_provider_config "$stage_dir"

    # Generate tfvars
    cat > "$tfvars_file" <<TFEOF
{
  "name": "${PROJECT_NAME}",
  "environment": "${NAMESPACE}",
  "endpoint": "${ENDPOINT}",
  "initial_root_password": "${KEYCLOAK_ROOT_PASSWORD}",
  "overrides": [],
  "node_group": {
    "key": "${NODE_SELECTOR_KEY}",
    "value": "${NODE_SELECTOR_VALUE}"
  },
  "themes": {
    "enabled": false,
    "repository": "",
    "branch": ""
  }
}
TFEOF

    run_terraform "$stage_dir" "Stage 05 - Keycloak" "$tfvars_file"

    if [[ "$PLAN_ONLY" != "true" ]]; then
        # Capture keycloak bot password
        KC_BOT_PASSWORD=$(get_tf_output "$stage_dir" "keycloak_nebari_bot_password" | jq -r '.')

        # Save for later stages
        echo "${KC_BOT_PASSWORD}" > "${STATE_DIR}/kc_bot_password"

        # Wait for Keycloak to be ready
        log_info "Waiting for Keycloak to be ready..."
        kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=keycloak \
            -n "${NAMESPACE}" --timeout=300s 2>/dev/null || true
        sleep 10
        log_success "Keycloak is running"
    fi
}

destroy_stage_05() {
    log_header "Stage 05: Keycloak (Destroy)"
    local stage_dir="${STAGES_DIR}/05-kubernetes-keycloak"
    local tfvars_file="${GENERATED_DIR}/stage-05.tfvars.json"
    load_saved_state
    generate_provider_config "$stage_dir"
    run_terraform_destroy "$stage_dir" "Stage 05" "$tfvars_file"
}

###############################################################################
# STAGE 06: Keycloak Configuration
###############################################################################

run_stage_06() {
    log_header "Stage 06: Keycloak Configuration"
    local stage_dir="${STAGES_DIR}/06-kubernetes-keycloak-configuration"
    local tfvars_file="${GENERATED_DIR}/stage-06.tfvars.json"

    load_saved_state

    # Generate provider config (kubernetes/helm only — keycloak uses env vars)
    generate_provider_config "$stage_dir"

    # Set Keycloak provider env vars
    export KEYCLOAK_URL="https://${ENDPOINT}/auth"
    export KEYCLOAK_CLIENT_ID="admin-cli"
    export KEYCLOAK_USER="root"
    export KEYCLOAK_PASSWORD="${KEYCLOAK_ROOT_PASSWORD}"
    export KEYCLOAK_REALM="master"
    log_info "Keycloak provider configured via environment variables"

    # Generate tfvars
    cat > "$tfvars_file" <<TFEOF
{
  "realm": "${PROJECT_NAME}",
  "realm_display_name": "${PROJECT_NAME}",
  "keycloak_groups": ["admin", "developer", "analyst", "superadmin"],
  "default_groups": ["analyst"],
  "authentication": {
    "type": "password"
  }
}
TFEOF

    run_terraform "$stage_dir" "Stage 06 - Keycloak Configuration" "$tfvars_file"

    if [[ "$PLAN_ONLY" != "true" ]]; then
        # Capture realm_id and read-only credentials
        REALM_ID=$(get_tf_output "$stage_dir" "realm_id" | jq -r '.')

        local ro_creds
        ro_creds=$(get_tf_output "$stage_dir" "keycloak-read-only-user-credentials")
        KC_RO_USERNAME=$(echo "$ro_creds" | jq -r '.username')
        KC_RO_PASSWORD=$(echo "$ro_creds" | jq -r '.password')

        # Save for later stages
        echo "${REALM_ID}" > "${STATE_DIR}/realm_id"
        echo "${KC_RO_USERNAME}" > "${STATE_DIR}/kc_ro_username"
        echo "${KC_RO_PASSWORD}" > "${STATE_DIR}/kc_ro_password"

        log_success "Keycloak realm '${REALM_ID}' configured"
    fi
}

destroy_stage_06() {
    log_header "Stage 06: Keycloak Configuration (Destroy)"
    local stage_dir="${STAGES_DIR}/06-kubernetes-keycloak-configuration"
    local tfvars_file="${GENERATED_DIR}/stage-06.tfvars.json"
    load_saved_state
    generate_provider_config "$stage_dir"
    export KEYCLOAK_URL="https://${ENDPOINT}/auth"
    export KEYCLOAK_CLIENT_ID="admin-cli"
    export KEYCLOAK_USER="root"
    export KEYCLOAK_PASSWORD="${KEYCLOAK_ROOT_PASSWORD}"
    export KEYCLOAK_REALM="master"
    run_terraform_destroy "$stage_dir" "Stage 06" "$tfvars_file"
}

###############################################################################
# STAGE 07: Kubernetes Services
###############################################################################

run_stage_07() {
    log_header "Stage 07: Kubernetes Services"
    local stage_dir="${STAGES_DIR}/07-kubernetes-services"
    local tfvars_file="${GENERATED_DIR}/stage-07.tfvars.json"

    load_saved_state

    # Generate provider config
    generate_provider_config "$stage_dir"

    # Set Keycloak provider env vars
    export KEYCLOAK_URL="https://${ENDPOINT}/auth"
    export KEYCLOAK_CLIENT_ID="admin-cli"
    export KEYCLOAK_USER="root"
    export KEYCLOAK_PASSWORD="${KEYCLOAK_ROOT_PASSWORD}"
    export KEYCLOAK_REALM="master"

    # Build the conda-store default environment
    local conda_envs
    conda_envs=$(cat <<'CONDAEOF'
{
  "nebari-git-nebari-git-default.yaml": {
    "name": "default",
    "channels": ["conda-forge"],
    "dependencies": [
      "python=3.11",
      "ipykernel",
      "ipywidgets",
      "numpy",
      "pandas"
    ]
  }
}
CONDAEOF
)

    # Build the service token scopes for conda-store
    local service_token_scopes
    service_token_scopes=$(cat <<'STSEOF'
{
  "argo-workflows-jupyter-scheduler": {
    "primary_namespace": "nebari-git",
    "role_bindings": {
      "nebari-git/*": ["viewer"]
    }
  },
  "dask-gateway": {
    "primary_namespace": "nebari-git",
    "role_bindings": {
      "nebari-git/*": ["viewer"]
    }
  },
  "jhub-apps": {
    "primary_namespace": "nebari-git",
    "role_bindings": {
      "nebari-git/*": ["viewer"]
    }
  }
}
STSEOF
)

    # Build the JupyterHub theme from nebari-config.yaml
    local jh_theme
    jh_theme=$(cat <<THEOF
{
  "hub_title": "Nebari - ${PROJECT_NAME}",
  "hub_subtitle": "Your open source data science platform, hosted",
  "welcome": "Welcome! Learn about Nebari's features and configurations in the documentation.",
  "logo": ""
}
THEOF
)

    # Generate the full tfvars JSON
    cat > "$tfvars_file" <<TFEOF
{
  "name": "${PROJECT_NAME}",
  "environment": "${NAMESPACE}",
  "endpoint": "${ENDPOINT}",
  "realm_id": "${REALM_ID}",
  "cloud-provider": "local",
  "node_groups": {
    "general": { "key": "${NODE_SELECTOR_KEY}", "value": "${NODE_SELECTOR_VALUE}" },
    "user":    { "key": "${NODE_SELECTOR_KEY}", "value": "${NODE_SELECTOR_VALUE}" },
    "worker":  { "key": "${NODE_SELECTOR_KEY}", "value": "${NODE_SELECTOR_VALUE}" }
  },

  "jupyterhub-theme": ${jh_theme},
  "jupyterhub-image": { "name": "${JUPYTERHUB_IMAGE}", "tag": "${NEBARI_VERSION}" },
  "jupyterhub-overrides": [],
  "jupyterhub-shared-storage": ${SHARED_STORAGE_GB},
  "jupyterhub-shared-endpoint": null,
  "jupyterlab-image": { "name": "${JUPYTERLAB_IMAGE}", "tag": "${NEBARI_VERSION}" },
  "jupyterlab-profiles": [],
  "jupyterlab-preferred-dir": "",
  "initial-repositories": "{}",
  "jupyterlab-default-settings": {},
  "jupyterlab-gallery-settings": { "exhibits": [] },
  "jupyterhub-hub-extraEnv": "[]",
  "idle-culler-settings": {
    "kernel_cull_busy": false,
    "kernel_cull_connected": true,
    "kernel_cull_idle_timeout": 30,
    "kernel_cull_interval": 5,
    "server_shutdown_no_activity_timeout": 15,
    "terminal_cull_inactive_timeout": 15
  },
  "node-taint-tolerations": [],
  "shared_fs_type": "${SHARED_FS_TYPE}",
  "jupyterhub-logout-redirect-url": "",

  "conda-store-environments": ${conda_envs},
  "conda-store-filesystem-storage": "${CONDA_STORE_STORAGE}",
  "conda-store-object-storage": "${CONDA_STORE_OBJ_STORAGE}",
  "conda-store-extra-settings": {},
  "conda-store-extra-config": "",
  "conda-store-image": "${CONDA_STORE_IMAGE}",
  "conda-store-image-tag": "${CONDA_STORE_TAG}",
  "conda-store-default-namespace": "nebari-git",
  "conda-store-service-token-scopes": ${service_token_scopes},

  "dask-worker-image": { "name": "${DASK_WORKER_IMAGE}", "tag": "${NEBARI_VERSION}" },
  "dask-gateway-profiles": [],
  "worker-taint-tolerations": [],

  "monitoring-enabled": ${MONITORING_ENABLED},
  "grafana-loki-overrides": [],
  "grafana-promtail-overrides": [],
  "grafana-loki-minio-overrides": [],
  "minio-enabled": true,

  "argo-workflows-enabled": ${ARGO_WORKFLOWS_ENABLED},
  "argo-workflows-overrides": [],
  "nebari-workflow-controller": ${NEBARI_WORKFLOW_CONTROLLER},
  "keycloak-read-only-user-credentials": {
    "username": "${KC_RO_USERNAME}",
    "password": "${KC_RO_PASSWORD}",
    "client_id": "admin-cli",
    "realm": "master"
  },
  "workflow-controller-image-tag": "${WORKFLOW_CONTROLLER_TAG}",

  "jupyterlab-pioneer-enabled": ${JUPYTERLAB_PIONEER_ENABLED},
  "jupyterlab-pioneer-log-format": "",
  "jhub-apps-enabled": ${JHUB_APPS_ENABLED},
  "jhub-apps-overrides": "{}",

  "forwardauth_middleware_name": "traefik-forward-auth",
  "cert_secret_name": "${CERT_SECRET_NAME}",
  "rook_ceph_storage_class_name": "local-path"
}
TFEOF

    run_terraform "$stage_dir" "Stage 07 - Kubernetes Services" "$tfvars_file"

    if [[ "$PLAN_ONLY" != "true" ]]; then
        # Capture forward-auth middleware name
        FORWARDAUTH_MIDDLEWARE=$(get_tf_output "$stage_dir" "forward-auth-middleware" 2>/dev/null | jq -r '.' 2>/dev/null || echo "traefik-forward-auth")
        echo "${FORWARDAUTH_MIDDLEWARE}" > "${STATE_DIR}/forwardauth_middleware"

        log_info "Waiting for services to initialize..."
        sleep 15
        log_success "Core services deployed"
    fi
}

destroy_stage_07() {
    log_header "Stage 07: Kubernetes Services (Destroy)"
    local stage_dir="${STAGES_DIR}/07-kubernetes-services"
    local tfvars_file="${GENERATED_DIR}/stage-07.tfvars.json"
    load_saved_state
    generate_provider_config "$stage_dir"
    export KEYCLOAK_URL="https://${ENDPOINT}/auth"
    export KEYCLOAK_CLIENT_ID="admin-cli"
    export KEYCLOAK_USER="root"
    export KEYCLOAK_PASSWORD="${KEYCLOAK_ROOT_PASSWORD}"
    export KEYCLOAK_REALM="master"
    run_terraform_destroy "$stage_dir" "Stage 07" "$tfvars_file"
}

###############################################################################
# STAGE 08: Nebari Terraform Extensions
###############################################################################

run_stage_08() {
    log_header "Stage 08: Nebari Terraform Extensions"
    local stage_dir="${STAGES_DIR}/08-nebari-tf-extensions"
    local tfvars_file="${GENERATED_DIR}/stage-08.tfvars.json"

    load_saved_state

    # Generate provider config
    generate_provider_config "$stage_dir"

    # Set Keycloak provider env vars
    export KEYCLOAK_URL="https://${ENDPOINT}/auth"
    export KEYCLOAK_CLIENT_ID="admin-cli"
    export KEYCLOAK_USER="root"
    export KEYCLOAK_PASSWORD="${KEYCLOAK_ROOT_PASSWORD}"
    export KEYCLOAK_REALM="master"

    # Read the nebari-config.yaml as JSON for the nebari_config_yaml variable
    local nebari_config_json
    if command -v python3 &>/dev/null; then
        nebari_config_json=$(python3 -c "
import yaml, json, sys
with open('${BASE_DIR}/nebari-config.yaml') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
" 2>/dev/null || echo '{}')
    else
        nebari_config_json='{}'
        log_warn "python3 not found — nebari_config_yaml will be empty"
    fi

    # Generate tfvars
    cat > "$tfvars_file" <<TFEOF
{
  "environment": "${NAMESPACE}",
  "endpoint": "${ENDPOINT}",
  "realm_id": "${REALM_ID}",
  "tf_extensions": [],
  "helm_extensions": [],
  "nebari_config_yaml": ${nebari_config_json},
  "keycloak_nebari_bot_password": "${KC_BOT_PASSWORD}",
  "forwardauth_middleware_name": "traefik-forward-auth"
}
TFEOF

    run_terraform "$stage_dir" "Stage 08 - Nebari Extensions" "$tfvars_file"
}

destroy_stage_08() {
    log_header "Stage 08: Nebari Extensions (Destroy)"
    local stage_dir="${STAGES_DIR}/08-nebari-tf-extensions"
    local tfvars_file="${GENERATED_DIR}/stage-08.tfvars.json"
    load_saved_state
    generate_provider_config "$stage_dir"
    export KEYCLOAK_URL="https://${ENDPOINT}/auth"
    export KEYCLOAK_CLIENT_ID="admin-cli"
    export KEYCLOAK_USER="root"
    export KEYCLOAK_PASSWORD="${KEYCLOAK_ROOT_PASSWORD}"
    export KEYCLOAK_REALM="master"
    run_terraform_destroy "$stage_dir" "Stage 08" "$tfvars_file"
}

###############################################################################
# STAGE 10: Kuberhealthy CRDs & Operator
###############################################################################

run_stage_10() {
    log_header "Stage 10: Kuberhealthy CRDs & Operator"
    local stage_dir="${STAGES_DIR}/10-kubernetes-kuberhealthy"

    load_saved_state
    export KUBECONFIG="${KUBECONFIG_PATH}"

    # Apply CRDs first
    log_info "Applying Kuberhealthy CRDs..."
    for crd_file in "${stage_dir}"/crds/*.yaml; do
        if [[ -f "$crd_file" ]]; then
            kubectl apply -f "$crd_file"
        fi
    done
    log_success "CRDs applied"

    # Apply manifests
    log_info "Applying Kuberhealthy manifests..."
    for manifest_file in "${stage_dir}"/manifests/*.yaml; do
        if [[ -f "$manifest_file" ]]; then
            # Replace namespace placeholder if needed
            kubectl apply -f "$manifest_file" -n "${NAMESPACE}" 2>/dev/null || \
                kubectl apply -f "$manifest_file" 2>/dev/null || true
        fi
    done
    log_success "Kuberhealthy operator deployed"
}

destroy_stage_10() {
    log_header "Stage 10: Kuberhealthy (Destroy)"
    local stage_dir="${STAGES_DIR}/10-kubernetes-kuberhealthy"
    load_saved_state
    export KUBECONFIG="${KUBECONFIG_PATH}"

    log_info "Deleting Kuberhealthy manifests..."
    for manifest_file in "${stage_dir}"/manifests/*.yaml; do
        if [[ -f "$manifest_file" ]]; then
            kubectl delete -f "$manifest_file" --ignore-not-found 2>/dev/null || true
        fi
    done
    for crd_file in "${stage_dir}"/crds/*.yaml; do
        if [[ -f "$crd_file" ]]; then
            kubectl delete -f "$crd_file" --ignore-not-found 2>/dev/null || true
        fi
    done
    log_success "Kuberhealthy removed"
}

###############################################################################
# STAGE 11: Kuberhealthy Health Checks
###############################################################################

run_stage_11() {
    log_header "Stage 11: Kuberhealthy Health Checks"
    local stage_dir="${STAGES_DIR}/11-kubernetes-kuberhealthy-healthchecks"

    load_saved_state
    export KUBECONFIG="${KUBECONFIG_PATH}"

    log_info "Applying Kuberhealthy health check definitions..."
    for manifest_file in "${stage_dir}"/manifests/*.yaml; do
        if [[ -f "$manifest_file" ]]; then
            kubectl apply -f "$manifest_file" -n "${NAMESPACE}" 2>/dev/null || \
                kubectl apply -f "$manifest_file" 2>/dev/null || true
        fi
    done
    log_success "Health checks deployed"
}

destroy_stage_11() {
    log_header "Stage 11: Kuberhealthy Health Checks (Destroy)"
    local stage_dir="${STAGES_DIR}/11-kubernetes-kuberhealthy-healthchecks"
    load_saved_state
    export KUBECONFIG="${KUBECONFIG_PATH}"

    log_info "Deleting Kuberhealthy health checks..."
    for manifest_file in "${stage_dir}"/manifests/*.yaml; do
        if [[ -f "$manifest_file" ]]; then
            kubectl delete -f "$manifest_file" --ignore-not-found 2>/dev/null || true
        fi
    done
    log_success "Health checks removed"
}

###############################################################################
# STATE PERSISTENCE — Load previously saved outputs
###############################################################################

load_saved_state() {
    if [[ -z "$ENDPOINT" && -f "${STATE_DIR}/endpoint" ]]; then
        ENDPOINT=$(cat "${STATE_DIR}/endpoint")
    fi
    if [[ -z "$LB_ADDRESS" && -f "${STATE_DIR}/lb_address" ]]; then
        LB_ADDRESS=$(cat "${STATE_DIR}/lb_address")
    fi
    if [[ -z "$KC_BOT_PASSWORD" && -f "${STATE_DIR}/kc_bot_password" ]]; then
        KC_BOT_PASSWORD=$(cat "${STATE_DIR}/kc_bot_password")
    fi
    if [[ -z "$REALM_ID" && -f "${STATE_DIR}/realm_id" ]]; then
        REALM_ID=$(cat "${STATE_DIR}/realm_id")
    fi
    if [[ -z "$KC_RO_USERNAME" && -f "${STATE_DIR}/kc_ro_username" ]]; then
        KC_RO_USERNAME=$(cat "${STATE_DIR}/kc_ro_username")
    fi
    if [[ -z "$KC_RO_PASSWORD" && -f "${STATE_DIR}/kc_ro_password" ]]; then
        KC_RO_PASSWORD=$(cat "${STATE_DIR}/kc_ro_password")
    fi
    if [[ -f "${KUBECONFIG_PATH}" ]]; then
        export KUBECONFIG="${KUBECONFIG_PATH}"
    fi
}

###############################################################################
# DEPLOYMENT SUMMARY
###############################################################################

print_summary() {
    log_header "Deployment Summary"

    load_saved_state

    echo -e "${BOLD}Nebari Local Deployment Complete!${NC}\n"
    echo -e "${BOLD}Cluster Info:${NC}"
    echo -e "  Kind Cluster:     test-cluster"
    echo -e "  Kubeconfig:       ${KUBECONFIG_PATH}"
    echo -e "  Load Balancer IP: ${LB_ADDRESS}"
    echo -e "  Endpoint:         ${ENDPOINT}"
    echo ""
    echo -e "${BOLD}Service URLs:${NC}"
    echo -e "  JupyterHub:   ${GREEN}https://${ENDPOINT}/${NC}"
    echo -e "  Keycloak:     ${GREEN}https://${ENDPOINT}/auth/${NC}"
    echo -e "  conda-store:  ${GREEN}https://${ENDPOINT}/conda-store/${NC}"
    echo -e "  Dask Gateway: ${GREEN}https://${ENDPOINT}/gateway/${NC}"
    if [[ "$MONITORING_ENABLED" == "true" ]]; then
        echo -e "  Monitoring:   ${GREEN}https://${ENDPOINT}/monitoring/${NC}"
    fi
    if [[ "$ARGO_WORKFLOWS_ENABLED" == "true" ]]; then
        echo -e "  Argo:         ${GREEN}https://${ENDPOINT}/argo/${NC}"
    fi
    echo ""
    echo -e "${BOLD}Keycloak Admin Credentials:${NC}"
    echo -e "  Username: root"
    echo -e "  Password: ${KEYCLOAK_ROOT_PASSWORD}"
    echo ""
    echo -e "${YELLOW}Note: TLS certificates are self-signed.${NC}"
    echo -e "${YELLOW}You will need to accept the browser security warning.${NC}"
    echo ""
    echo -e "${BOLD}Useful Commands:${NC}"
    echo -e "  export KUBECONFIG=${KUBECONFIG_PATH}"
    echo -e "  kubectl get pods -n ${NAMESPACE}"
    echo -e "  kubectl get svc -n ${NAMESPACE}"
    echo ""
}

###############################################################################
# MAIN ORCHESTRATION
###############################################################################

should_run_stage() {
    local stage_num="$1"
    if [[ -n "$SINGLE_STAGE" ]]; then
        [[ "$SINGLE_STAGE" == "$stage_num" ]]
        return
    fi
    if [[ -n "$FROM_STAGE" ]]; then
        [[ "$stage_num" -ge "$FROM_STAGE" ]]
        return
    fi
    return 0
}

deploy() {
    log_header "Starting Nebari Local Deployment"
    log_info "Project: ${PROJECT_NAME}"
    log_info "Namespace: ${NAMESPACE}"
    log_info "Nebari Version: ${NEBARI_VERSION}"
    log_info "Plan Only: ${PLAN_ONLY}"
    echo ""

    check_prerequisites

    should_run_stage "01" && run_stage_01
    should_run_stage "02" && run_stage_02
    should_run_stage "03" && run_stage_03
    should_run_stage "04" && run_stage_04
    should_run_stage "05" && run_stage_05
    should_run_stage "06" && run_stage_06
    should_run_stage "07" && run_stage_07
    should_run_stage "08" && run_stage_08
    should_run_stage "10" && run_stage_10
    should_run_stage "11" && run_stage_11

    if [[ "$PLAN_ONLY" != "true" ]]; then
        print_summary
    else
        log_header "Plan Complete"
        log_info "All stages planned successfully. Run without --plan-only to apply."
    fi
}

destroy_all() {
    log_header "Destroying Nebari Local Deployment (Reverse Order)"
    check_prerequisites
    load_saved_state

    destroy_stage_11
    destroy_stage_10
    destroy_stage_08
    destroy_stage_07
    destroy_stage_06
    destroy_stage_05
    destroy_stage_04
    destroy_stage_03
    # Stage 02 destroys the Kind cluster (do last)
    destroy_stage_02
    destroy_stage_01

    # Clean up generated files
    log_info "Cleaning up generated files..."
    rm -rf "${GENERATED_DIR}"
    rm -rf "${STATE_DIR}"

    log_header "Nebari Local Deployment Destroyed"
    log_success "All resources have been removed."
}

main() {
    parse_args "$@"

    if [[ "$DESTROY" == "true" ]]; then
        destroy_all
    else
        deploy
    fi
}

main "$@"
