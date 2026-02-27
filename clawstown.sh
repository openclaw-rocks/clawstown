#!/usr/bin/env bash
#
# clawstown.sh -- Deploy a Clawstown agent swarm on Kubernetes
#
# Deploys an OpenClaw-based development swarm: N self-organizing agents
# coordinating through GitHub Issues and PRs. Agents read SWARM.md
# from the target repository to understand their goals.
#
# Usage:
#   ./clawstown.sh --repo <github-url> [options]
#   ./clawstown.sh --teardown [--namespace <ns>] [--delete-cluster]
#   ./clawstown.sh --dry-run --repo <github-url>

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
AGENTS=2
MODEL="anthropic/claude-sonnet-4-20250514"
CLUSTER_NAME="clawstown"
REPO=""
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
KUBECONFIG_PATH="${KUBECONFIG:-}"
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

Authentication:
  --anthropic-api-key <key> Anthropic API key (default: $ANTHROPIC_API_KEY)
  --github-token <token>    GitHub PAT with repo scope (default: $GITHUB_TOKEN)

Cluster:
  --kubeconfig <path>       Use existing cluster (default: create Kind cluster)
  --cluster-name <name>     Kind cluster name (default: clawstown)
  --namespace <ns>          Kubernetes namespace (default: clawstown)

Swarm:
  --agents <n>              Number of agents (default: 2)
  --model <model>           Model for agents (default: anthropic/claude-sonnet-4-20250514)

Modes:
  --dry-run                 Generate manifests to stdout without applying
  --teardown                Remove the Clawstown deployment
  --delete-cluster          Also delete the Kind cluster (with --teardown)

  --help                    Show this help message

The target repository must contain a SWARM.md file describing the goals
for the swarm. Agents read it on startup and self-organize around its goals.
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
      --anthropic-api-key) ANTHROPIC_API_KEY="$2"; shift 2 ;;
      --github-token)      GITHUB_TOKEN="$2"; shift 2 ;;
      --kubeconfig)        KUBECONFIG_PATH="$2"; shift 2 ;;
      --cluster-name)      CLUSTER_NAME="$2"; shift 2 ;;
      --namespace)         NAMESPACE="$2"; shift 2 ;;
      --agents)            AGENTS="$2"; shift 2 ;;
      --model)             MODEL="$2"; shift 2 ;;
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

  if [ -z "$ANTHROPIC_API_KEY" ]; then
    fatal "--anthropic-api-key or \$ANTHROPIC_API_KEY is required"
  fi

  if [ -z "$GITHUB_TOKEN" ]; then
    fatal "--github-token or \$GITHUB_TOKEN is required"
  fi

  if ! [[ "$AGENTS" =~ ^[0-9]+$ ]] || [ "$AGENTS" -lt 1 ]; then
    fatal "--agents must be a positive integer"
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
    warn "Create these labels manually: clawstown:task, clawstown:in-progress, clawstown:review, clawstown:blocked, clawstown:done, clawstown:failing"
    return
  fi

  log "Setting up GitHub labels..."

  local repo_slug
  repo_slug=$(echo "$REPO" | sed -E 's|https?://github\.com/||; s|\.git$||; s|/$||')

  local -a labels=(
    "clawstown:task|0075ca|Work item for the swarm"
    "clawstown:in-progress|fbca04|An agent is working on this issue"
    "clawstown:review|d4c5f9|PR awaiting peer review"
    "clawstown:blocked|e4e669|Blocked on a dependency"
    "clawstown:done|0e8a16|Complete and merged"
    "clawstown:failing|b60205|Tests are failing after merge"
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


# -----------------------------------------------------------------------------
# Agent manifest
# -----------------------------------------------------------------------------
generate_agent_manifest() {
  local agent_id="$1"
  local agent_name="clawstown-agent-${agent_id}"

  cat <<EOF
---
apiVersion: ${CRD_API_VERSION}
kind: OpenClawInstance
metadata:
  name: ${agent_name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: clawstown
    app.kubernetes.io/component: agent
    clawstown.openclaw.rocks/agent-id: "${agent_id}"
spec:
  config:
    raw:
      agents:
        defaults:
          model:
            primary: "${MODEL}"
  skills:
    - "gh-issues"
  envFrom:
    - secretRef:
        name: clawstown-api-keys
    - secretRef:
        name: clawstown-github
  env:
    - name: CLAWSTOWN_REPO
      value: "${REPO}"
    - name: CLAWSTOWN_AGENT_ID
      value: "${agent_id}"
    - name: CLAWSTOWN_AGENT_COUNT
      value: "${AGENTS}"
    - name: GH_TOKEN
      valueFrom:
        secretKeyRef:
          name: clawstown-github
          key: GITHUB_TOKEN
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
      "AGENTS.md": |
$(indent_file "${SCRIPT_DIR}/prompts/agent.md" 8)
EOF
}

# -----------------------------------------------------------------------------
# Deploy agents
# -----------------------------------------------------------------------------
deploy_agents() {
  log "Deploying ${AGENTS} agent(s)..."
  for i in $(seq 0 $((AGENTS - 1))); do
    generate_agent_manifest "$i" | kube_apply
    if [ "$DRY_RUN" != true ]; then
      log "Agent deployed: clawstown-agent-${i}"
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

  while [ "$elapsed" -lt "$timeout" ]; do
    local ready=0

    for i in $(seq 0 $((AGENTS - 1))); do
      local agent_phase
      agent_phase=$(kubectl_cmd get openclawinstance "clawstown-agent-${i}" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [ "$agent_phase" = "Running" ]; then
        ready=$((ready + 1))
      fi
    done

    if [ "$ready" -eq "$AGENTS" ]; then
      log "All ${AGENTS} agents are running"
      return 0
    fi

    echo -ne "\r  ${ready}/${AGENTS} agents ready (${elapsed}s elapsed)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo ""
  warn "Timed out waiting for all agents to become ready"
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
  echo -e "  Agents:      ${AGENTS} (${MODEL})"
  echo ""
  echo -e "${BOLD}Instances:${NC}"
  kubectl_cmd get openclawinstances -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
    2>/dev/null || echo "  (unable to fetch instance status)"
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo ""
  echo "  1. Ensure SWARM.md exists in the target repository with your goals."
  echo ""
  echo "  2. Kick off any agent via its gateway:"
  echo ""
  echo "     # Port-forward to an agent's gateway"
  echo "     kubectl port-forward -n ${NAMESPACE} svc/clawstown-agent-0 18789:18789 &"
  echo ""
  echo "     # Open the webchat UI"
  echo "     open http://localhost:18789"
  echo ""
  echo "  3. Tell the agent to begin:"
  echo "     \"Clone the repo and start working.\""
  echo ""
  echo "  4. Monitor the swarm:"
  echo "     kubectl logs -f -n ${NAMESPACE} sts/clawstown-agent-0 -c openclaw"
  echo "     kubectl get openclawinstances -n ${NAMESPACE} -w"
  echo ""
  echo "  5. Watch progress on GitHub:"
  echo "     ${REPO}/issues"
  echo ""
  echo "  6. Tear down when done:"
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
  echo -e "  Agents:      ${AGENTS}"
  echo -e "  Namespace:   ${NAMESPACE}"
  if [ "$DRY_RUN" = true ]; then
    echo -e "  Mode:        ${YELLOW}dry-run (manifests only)${NC}"
  fi
  echo ""

  if [ "$DRY_RUN" = true ]; then
    # In dry-run mode, just output all manifests
    create_namespace
    create_secrets
    deploy_agents
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
  deploy_agents
  wait_for_ready || true
  print_status
}

main "$@"
