#!/usr/bin/env bash
#
# clawstown.sh -- Deploy a Clawstown agent swarm on Kubernetes
#
# Deploys an OpenClaw-based development swarm: one Mayor (coordinator/reviewer)
# and N Workers (developers), coordinating through GitHub Issues and PRs.
#
# Usage:
#   ./clawstown.sh --repo <github-url> --description "project goals" [options]
#   ./clawstown.sh --teardown [--namespace <ns>] [--delete-cluster]
#   ./clawstown.sh --dry-run --repo <github-url> --description "project goals"

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_CHART="oci://ghcr.io/openclaw-rocks/charts/openclaw-operator"
OPERATOR_NAMESPACE="openclaw-operator-system"
CRD_API_VERSION="openclaw.rocks/v1alpha1"

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
NAMESPACE="clawstown"
WORKERS=2
MAYOR_MODEL="anthropic/claude-sonnet-4-20250514"
WORKER_MODEL="anthropic/claude-sonnet-4-20250514"
CLUSTER_NAME="clawstown"
REPO=""
DESCRIPTION=""
DESCRIPTION_FILE=""
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
KUBECONFIG_PATH="${KUBECONFIG:-}"
WORKER_ROLES=""
DRY_RUN=false
TEARDOWN=false
DELETE_CLUSTER=false

# -----------------------------------------------------------------------------
# Colors (disabled if not a terminal)
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()   { echo -e "${GREEN}[clawstown]${NC} $*"; }
warn()  { echo -e "${YELLOW}[clawstown]${NC} $*" >&2; }
error() { echo -e "${RED}[clawstown]${NC} $*" >&2; }
fatal() { error "$@"; exit 1; }

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage: clawstown.sh [options]

Deploy:
  --repo <url>              GitHub repository URL (required)
  --description <text>      Project description / goal (required unless --description-file)
  --description-file <path> Read project description from file

Authentication:
  --anthropic-api-key <key> Anthropic API key (default: $ANTHROPIC_API_KEY)
  --github-token <token>    GitHub PAT with repo scope (default: $GITHUB_TOKEN)

Cluster:
  --kubeconfig <path>       Use existing cluster (default: create Kind cluster)
  --cluster-name <name>     Kind cluster name (default: clawstown)
  --namespace <ns>          Kubernetes namespace (default: clawstown)

Swarm:
  --workers <n>             Number of worker agents (default: 2)
  --mayor-model <model>     Model for the Mayor (default: anthropic/claude-sonnet-4-20250514)
  --worker-model <model>    Model for workers (default: anthropic/claude-sonnet-4-20250514)
  --worker-roles <roles>    Comma-separated role hints (e.g. backend,frontend,testing)

Modes:
  --dry-run                 Generate manifests to stdout without applying
  --teardown                Remove the Clawstown deployment
  --delete-cluster          Also delete the Kind cluster (with --teardown)

  --help                    Show this help message
USAGE
  exit 0
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)              REPO="$2"; shift 2 ;;
      --description)       DESCRIPTION="$2"; shift 2 ;;
      --description-file)  DESCRIPTION_FILE="$2"; shift 2 ;;
      --anthropic-api-key) ANTHROPIC_API_KEY="$2"; shift 2 ;;
      --github-token)      GITHUB_TOKEN="$2"; shift 2 ;;
      --kubeconfig)        KUBECONFIG_PATH="$2"; shift 2 ;;
      --cluster-name)      CLUSTER_NAME="$2"; shift 2 ;;
      --namespace)         NAMESPACE="$2"; shift 2 ;;
      --workers)           WORKERS="$2"; shift 2 ;;
      --mayor-model)       MAYOR_MODEL="$2"; shift 2 ;;
      --worker-model)      WORKER_MODEL="$2"; shift 2 ;;
      --worker-roles)      WORKER_ROLES="$2"; shift 2 ;;
      --dry-run)           DRY_RUN=true; shift ;;
      --teardown)          TEARDOWN=true; shift ;;
      --delete-cluster)    DELETE_CLUSTER=true; shift ;;
      --help|-h)           usage ;;
      *)                   fatal "Unknown option: $1 (use --help for usage)" ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
check_command() {
  if ! command -v "$1" &>/dev/null; then
    fatal "$1 is required but not installed. See: $2"
  fi
}

validate_deploy() {
  check_command kubectl "https://kubernetes.io/docs/tasks/tools/"
  check_command helm    "https://helm.sh/docs/intro/install/"

  if [ -z "$KUBECONFIG_PATH" ]; then
    check_command kind "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
  fi

  if [ -z "$REPO" ]; then
    fatal "--repo is required"
  fi

  # Load description from file if specified
  if [ -n "$DESCRIPTION_FILE" ]; then
    if [ ! -f "$DESCRIPTION_FILE" ]; then
      fatal "Description file not found: $DESCRIPTION_FILE"
    fi
    DESCRIPTION="$(cat "$DESCRIPTION_FILE")"
  fi

  if [ -z "$DESCRIPTION" ]; then
    fatal "--description or --description-file is required"
  fi

  if [ -z "$ANTHROPIC_API_KEY" ]; then
    fatal "--anthropic-api-key or \$ANTHROPIC_API_KEY is required"
  fi

  if [ -z "$GITHUB_TOKEN" ]; then
    fatal "--github-token or \$GITHUB_TOKEN is required"
  fi

  if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || [ "$WORKERS" -lt 1 ]; then
    fatal "--workers must be a positive integer"
  fi
}

validate_teardown() {
  check_command kubectl "https://kubernetes.io/docs/tasks/tools/"
  if [ "$DELETE_CLUSTER" = true ]; then
    check_command kind "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
  fi
}

# -----------------------------------------------------------------------------
# Kubectl helper (respects dry-run mode)
# -----------------------------------------------------------------------------
kube_apply() {
  if [ "$DRY_RUN" = true ]; then
    cat
  else
    kubectl apply -f -
  fi
}

kubectl_cmd() {
  if [ -n "$KUBECONFIG_PATH" ]; then
    kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
  else
    kubectl "$@"
  fi
}

# -----------------------------------------------------------------------------
# Kind cluster
# -----------------------------------------------------------------------------
create_kind_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log "Kind cluster '${CLUSTER_NAME}' already exists, reusing"
    return
  fi

  log "Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "${SCRIPT_DIR}/kind/cluster.yaml" \
    --wait 60s

  log "Kind cluster '${CLUSTER_NAME}' created"
}

# -----------------------------------------------------------------------------
# Operator installation
# -----------------------------------------------------------------------------
install_operator() {
  if kubectl_cmd get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
    log "OpenClaw operator namespace exists, checking installation..."
    if kubectl_cmd get deployment -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=openclaw-operator &>/dev/null 2>&1; then
      log "OpenClaw operator already installed, upgrading..."
      helm upgrade openclaw-operator "$OPERATOR_CHART" \
        --namespace "$OPERATOR_NAMESPACE" \
        --wait \
        --timeout 120s
      return
    fi
  fi

  log "Installing OpenClaw operator..."
  helm install openclaw-operator "$OPERATOR_CHART" \
    --namespace "$OPERATOR_NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 120s

  log "OpenClaw operator installed"
}

# -----------------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------------
create_namespace() {
  if kubectl_cmd get namespace "$NAMESPACE" &>/dev/null; then
    log "Namespace '${NAMESPACE}' already exists"
    return
  fi

  log "Creating namespace '${NAMESPACE}'..."
  cat <<EOF | kube_apply
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: clawstown
EOF
}

# -----------------------------------------------------------------------------
# Secrets
# -----------------------------------------------------------------------------
create_secrets() {
  log "Creating secrets..."

  if [ "$DRY_RUN" = true ]; then
    cat <<EOF
---
# Secret: clawstown-api-keys (REDACTED)
apiVersion: v1
kind: Secret
metadata:
  name: clawstown-api-keys
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  ANTHROPIC_API_KEY: "REDACTED"
---
# Secret: clawstown-github (REDACTED)
apiVersion: v1
kind: Secret
metadata:
  name: clawstown-github
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  GITHUB_TOKEN: "REDACTED"
EOF
    return
  fi

  # Create or update API keys secret
  kubectl_cmd create secret generic clawstown-api-keys \
    --namespace "$NAMESPACE" \
    --from-literal="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
    --dry-run=client -o yaml | kubectl_cmd apply -f -

  # Create or update GitHub token secret
  kubectl_cmd create secret generic clawstown-github \
    --namespace "$NAMESPACE" \
    --from-literal="GITHUB_TOKEN=${GITHUB_TOKEN}" \
    --dry-run=client -o yaml | kubectl_cmd apply -f -

  log "Secrets created"
}

# -----------------------------------------------------------------------------
# GitHub labels setup
# -----------------------------------------------------------------------------
setup_github_labels() {
  if ! command -v gh &>/dev/null; then
    warn "gh CLI not found -- skipping GitHub label setup"
    warn "Create these labels manually: clawstown:task, clawstown:in-progress, clawstown:review, clawstown:blocked, clawstown:done"
    return
  fi

  log "Setting up GitHub labels..."

  local repo_slug
  repo_slug=$(echo "$REPO" | sed -E 's|https?://github\.com/||; s|\.git$||; s|/$||')

  local -a labels=(
    "clawstown:task|0075ca|Work item created by the Mayor"
    "clawstown:in-progress|fbca04|Worker has started on this issue"
    "clawstown:review|d4c5f9|PR awaiting Mayor review"
    "clawstown:blocked|e4e669|Blocked on a dependency"
    "clawstown:done|0e8a16|Complete and merged"
    "role:backend|c2e0c6|Backend-focused work"
    "role:frontend|bfdadc|Frontend-focused work"
    "role:testing|d4c5f9|Testing-focused work"
  )

  for entry in "${labels[@]}"; do
    IFS='|' read -r name color desc <<< "$entry"
    gh label create "$name" \
      --repo "$repo_slug" \
      --color "$color" \
      --description "$desc" \
      --force 2>/dev/null || true
  done

  log "GitHub labels configured"
}

# -----------------------------------------------------------------------------
# YAML helper: indent file content for embedding in block scalars
# -----------------------------------------------------------------------------
indent_file() {
  local file="$1"
  local spaces="$2"
  local padding
  padding=$(printf "%${spaces}s" "")
  # Indent non-empty lines; leave empty lines empty
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      echo ""
    else
      echo "${padding}${line}"
    fi
  done < "$file"
}

indent_string() {
  local content="$1"
  local spaces="$2"
  local padding
  padding=$(printf "%${spaces}s" "")
  echo "$content" | while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      echo ""
    else
      echo "${padding}${line}"
    fi
  done
}

# -----------------------------------------------------------------------------
# Mayor manifest
# -----------------------------------------------------------------------------
generate_mayor_manifest() {
  cat <<EOF
---
apiVersion: ${CRD_API_VERSION}
kind: OpenClawInstance
metadata:
  name: clawstown-mayor
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: clawstown
    app.kubernetes.io/component: mayor
    clawstown.openclaw.rocks/role: mayor
spec:
  config:
    raw:
      agents:
        defaults:
          model:
            primary: "${MAYOR_MODEL}"
  envFrom:
    - secretRef:
        name: clawstown-api-keys
    - secretRef:
        name: clawstown-github
  env:
    - name: CLAWSTOWN_ROLE
      value: "mayor"
    - name: CLAWSTOWN_REPO
      value: "${REPO}"
    - name: CLAWSTOWN_WORKER_COUNT
      value: "${WORKERS}"
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2000m"
      memory: "4Gi"
  storage:
    persistence:
      enabled: true
      size: 10Gi
  security:
    networkPolicy:
      enabled: true
      allowDNS: true
  workspace:
    initialFiles:
      "CLAWSTOWN.md": |
$(indent_file "${SCRIPT_DIR}/prompts/mayor.md" 8)
      "PROJECT.md": |
$(indent_string "$DESCRIPTION" 8)
EOF
}

# -----------------------------------------------------------------------------
# Worker manifest
# -----------------------------------------------------------------------------
generate_worker_manifest() {
  local worker_id="$1"
  local worker_name="clawstown-worker-${worker_id}"

  # Determine role hint if provided
  local role_hint=""
  if [ -n "$WORKER_ROLES" ]; then
    local roles_array
    IFS=',' read -ra roles_array <<< "$WORKER_ROLES"
    local role_index=$((worker_id % ${#roles_array[@]}))
    role_hint="${roles_array[$role_index]}"
  fi

  # Build role-specific env var section
  local role_env=""
  if [ -n "$role_hint" ]; then
    role_env="    - name: CLAWSTOWN_WORKER_ROLE
      value: \"${role_hint}\""
  fi

  # Build role-specific workspace file
  local role_file_section=""
  local role_file="${SCRIPT_DIR}/prompts/roles/${role_hint}.md"
  if [ -n "$role_hint" ] && [ -f "$role_file" ]; then
    role_file_section="      \"CLAWSTOWN_ROLE_HINT.md\": |
$(indent_file "$role_file" 8)"
  fi

  cat <<EOF
---
apiVersion: ${CRD_API_VERSION}
kind: OpenClawInstance
metadata:
  name: ${worker_name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: clawstown
    app.kubernetes.io/component: worker
    clawstown.openclaw.rocks/role: worker
    clawstown.openclaw.rocks/worker-id: "${worker_id}"
spec:
  config:
    raw:
      agents:
        defaults:
          model:
            primary: "${WORKER_MODEL}"
  envFrom:
    - secretRef:
        name: clawstown-api-keys
    - secretRef:
        name: clawstown-github
  env:
    - name: CLAWSTOWN_ROLE
      value: "worker"
    - name: CLAWSTOWN_REPO
      value: "${REPO}"
    - name: CLAWSTOWN_WORKER_ID
      value: "${worker_id}"
${role_env}
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2000m"
      memory: "4Gi"
  storage:
    persistence:
      enabled: true
      size: 10Gi
  security:
    networkPolicy:
      enabled: true
      allowDNS: true
  workspace:
    initialFiles:
      "CLAWSTOWN.md": |
$(indent_file "${SCRIPT_DIR}/prompts/worker.md" 8)
      "PROJECT.md": |
$(indent_string "$DESCRIPTION" 8)
${role_file_section}
EOF
}

# -----------------------------------------------------------------------------
# Deploy instances
# -----------------------------------------------------------------------------
deploy_mayor() {
  log "Deploying Mayor..."
  generate_mayor_manifest | kube_apply
  if [ "$DRY_RUN" != true ]; then
    log "Mayor deployed: clawstown-mayor"
  fi
}

deploy_workers() {
  log "Deploying ${WORKERS} worker(s)..."
  for i in $(seq 0 $((WORKERS - 1))); do
    generate_worker_manifest "$i" | kube_apply
    if [ "$DRY_RUN" != true ]; then
      log "Worker deployed: clawstown-worker-${i}"
    fi
  done
}

# -----------------------------------------------------------------------------
# Wait for readiness
# -----------------------------------------------------------------------------
wait_for_ready() {
  log "Waiting for swarm to become ready..."

  local timeout=300
  local interval=5
  local elapsed=0
  local total=$((WORKERS + 1))

  while [ "$elapsed" -lt "$timeout" ]; do
    local ready=0

    # Check Mayor
    local mayor_phase
    mayor_phase=$(kubectl_cmd get openclawinstance clawstown-mayor \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$mayor_phase" = "Running" ]; then
      ready=$((ready + 1))
    fi

    # Check Workers
    for i in $(seq 0 $((WORKERS - 1))); do
      local worker_phase
      worker_phase=$(kubectl_cmd get openclawinstance "clawstown-worker-${i}" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [ "$worker_phase" = "Running" ]; then
        ready=$((ready + 1))
      fi
    done

    if [ "$ready" -eq "$total" ]; then
      log "All ${total} instances are running"
      return 0
    fi

    echo -ne "\r  ${ready}/${total} instances ready (${elapsed}s elapsed)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo ""
  warn "Timed out waiting for all instances to become ready"
  warn "Run 'kubectl get openclawinstances -n ${NAMESPACE}' to check status"
  return 1
}

# -----------------------------------------------------------------------------
# Status output
# -----------------------------------------------------------------------------
print_status() {
  echo ""
  echo -e "${BOLD}========================================${NC}"
  echo -e "${BOLD}  Clawstown Swarm Deployed${NC}"
  echo -e "${BOLD}========================================${NC}"
  echo ""
  echo -e "  Namespace:   ${BLUE}${NAMESPACE}${NC}"
  echo -e "  Repository:  ${BLUE}${REPO}${NC}"
  echo -e "  Mayor:       clawstown-mayor (${MAYOR_MODEL})"
  echo -e "  Workers:     ${WORKERS} (${WORKER_MODEL})"
  if [ -n "$WORKER_ROLES" ]; then
    echo -e "  Roles:       ${WORKER_ROLES}"
  fi
  echo ""
  echo -e "${BOLD}Instances:${NC}"
  kubectl_cmd get openclawinstances -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.clawstown\.openclaw\.rocks/role,PHASE:.status.phase' \
    2>/dev/null || echo "  (unable to fetch instance status)"
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo ""
  echo "  1. Send the Mayor its first instruction via the gateway:"
  echo ""
  echo "     # Port-forward to the Mayor's gateway"
  echo "     kubectl port-forward -n ${NAMESPACE} svc/clawstown-mayor 18789:18789 &"
  echo ""
  echo "     # Open the webchat UI"
  echo "     open http://localhost:18789"
  echo ""
  echo "     # Or send a message via the API"
  echo "     GATEWAY_TOKEN=\$(kubectl get secret -n ${NAMESPACE} clawstown-mayor-gateway-token -o jsonpath='{.data.token}' | base64 -d)"
  echo ""
  echo "  2. Tell the Mayor to begin:"
  echo "     \"Read CLAWSTOWN.md and PROJECT.md, then analyze the repository and start creating issues.\""
  echo ""
  echo "  3. Monitor the swarm:"
  echo "     kubectl logs -f -n ${NAMESPACE} sts/clawstown-mayor -c openclaw"
  echo "     kubectl get openclawinstances -n ${NAMESPACE} -w"
  echo ""
  echo "  4. Watch progress on GitHub:"
  echo "     ${REPO}/issues"
  echo ""
  echo "  5. Tear down when done:"
  echo "     ./clawstown.sh --teardown --namespace ${NAMESPACE}"
  echo ""
}

# -----------------------------------------------------------------------------
# Teardown
# -----------------------------------------------------------------------------
teardown() {
  log "Tearing down Clawstown in namespace '${NAMESPACE}'..."

  # Delete all OpenClawInstances in the namespace
  if kubectl_cmd get openclawinstances -n "$NAMESPACE" &>/dev/null 2>&1; then
    log "Deleting OpenClaw instances..."
    kubectl_cmd delete openclawinstances --all -n "$NAMESPACE" --timeout=60s || true
  fi

  # Delete secrets
  kubectl_cmd delete secret clawstown-api-keys clawstown-github \
    -n "$NAMESPACE" --ignore-not-found || true

  # Delete namespace
  if kubectl_cmd get namespace "$NAMESPACE" &>/dev/null; then
    log "Deleting namespace '${NAMESPACE}'..."
    kubectl_cmd delete namespace "$NAMESPACE" --timeout=120s || true
  fi

  # Optionally delete Kind cluster
  if [ "$DELETE_CLUSTER" = true ]; then
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
      log "Deleting Kind cluster '${CLUSTER_NAME}'..."
      kind delete cluster --name "$CLUSTER_NAME"
    fi
  fi

  log "Teardown complete"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Teardown mode
  if [ "$TEARDOWN" = true ]; then
    validate_teardown
    teardown
    exit 0
  fi

  # Deploy mode
  validate_deploy

  echo ""
  echo -e "${BOLD}Clawstown${NC} -- Deploying agent swarm"
  echo -e "  Repository:  ${REPO}"
  echo -e "  Workers:     ${WORKERS}"
  echo -e "  Namespace:   ${NAMESPACE}"
  if [ "$DRY_RUN" = true ]; then
    echo -e "  Mode:        ${YELLOW}dry-run (manifests only)${NC}"
  fi
  echo ""

  if [ "$DRY_RUN" = true ]; then
    # In dry-run mode, just output all manifests
    create_namespace
    create_secrets
    deploy_mayor
    deploy_workers
    exit 0
  fi

  # Set kubeconfig for Kind cluster
  if [ -z "$KUBECONFIG_PATH" ]; then
    create_kind_cluster
    # Kind sets the kubeconfig context automatically
  else
    export KUBECONFIG="$KUBECONFIG_PATH"
  fi

  install_operator
  create_namespace
  create_secrets
  setup_github_labels
  deploy_mayor
  deploy_workers
  wait_for_ready || true
  print_status
}

main "$@"
