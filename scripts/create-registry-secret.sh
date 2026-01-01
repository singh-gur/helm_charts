#!/bin/bash
# create-registry-secret.sh
# Creates a Kubernetes secret for pulling from private Docker registry
# and patches service accounts to use it
#
# Usage:
#   ./create-registry-secret.sh [OPTIONS]
#
# Options:
#   -s, --server     Registry server URL (default: regv2.gsingh.io)
#   -u, --username   Registry username (prompts if not provided)
#   -p, --password   Registry password (prompts if not provided)
#   -e, --email      Registry email (default: hello@gsingh.io)
#   -n, --namespaces Comma-separated list of namespaces (default: default)
#   -a, --argocd     Patch ArgoCD service accounts (default: true)
#   -i, --insecure   Add insecure registry to ArgoCD (default: false)
#   -r, --restart    Restart ArgoCD pods (default: true)
#   -h, --help       Show this help message
#
# Examples:
#   # Interactive mode
#   ./create-registry-secret.sh
#
#   # Single namespace
#   ./create-registry-secret.sh -u myuser -p mypass -n default
#
#   # Multiple namespaces
#   ./create-registry-secret.sh -u myuser -p mypass -n "default,data-platform,monitoring"
#
#   # Enable insecure registry (for self-signed certs)
#   ./create-registry-secret.sh -u myuser -p mypass -n default -i true
#
#   # Skip ArgoCD operations
#   ./create-registry-secret.sh -u myuser -p mypass -n default -a false -i false -r false
#
#   # All options
#   ./create-registry-secret.sh -s regv2.gsingh.io -u myuser -p mypass -e hello@gsingh.io -n "default,kube-system"

set -euo pipefail

# Default values
REGISTRY_SERVER="regv2.gsingh.io"
USERNAME=""
PASSWORD=""
EMAIL="hello@gsingh.io"
NAMESPACES="default"
PATCH_ARGOCD=true
ADD_INSECURE=false
RESTART_ARGOCD=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script info
SCRIPT_NAME="$(basename "$0")"
SECRET_NAME="regv2-secret"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

show_help() {
    head -32 "$0" | tail -28
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--server)
            REGISTRY_SERVER="$2"
            shift 2
            ;;
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        -e|--email)
            EMAIL="$2"
            shift 2
            ;;
        -n|--namespaces)
            NAMESPACES="$2"
            shift 2
            ;;
        -a|--argocd)
            PATCH_ARGOCD="$2"
            shift 2
            ;;
        -i|--insecure)
            ADD_INSECURE="$2"
            shift 2
            ;;
        -r|--restart)
            RESTART_ARGOCD="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            ;;
    esac
done

# Prompt for missing credentials
if [[ -z "$USERNAME" ]]; then
    read -p "Docker registry username: " USERNAME
fi

if [[ -z "$PASSWORD" ]]; then
    read -s -p "Docker registry password: " PASSWORD
    echo ""
fi

# Validate inputs
if [[ -z "$USERNAME" ]] || [[ -z "$PASSWORD" ]]; then
    log_error "Username and password are required"
    exit 1
fi

# Pre-checks
log_step "Running pre-checks..."

# Check kubectl availability
if ! command -v kubectl &>/dev/null; then
    log_error "kubectl not found. Please install kubectl first."
    exit 1
fi

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
    exit 1
fi

log_info "Connected to Kubernetes cluster"

# Convert comma-separated namespaces to array
IFS=',' read -ra NAMESPACE_ARRAY <<< "$NAMESPACES"

echo ""
log_step "Configuration Summary:"
echo "  Registry Server: $REGISTRY_SERVER"
echo "  Username: $USERNAME"
echo "  Email: $EMAIL"
echo "  Namespaces: ${NAMESPACE_ARRAY[*]}"
echo "  Patch ArgoCD: $PATCH_ARGOCD"
echo "  Add Insecure Registry: $ADD_INSECURE"
echo "  Restart ArgoCD: $RESTART_ARGOCD"
echo ""

# Create secret in each namespace and patch service accounts
for NS in "${NAMESPACE_ARRAY[@]}"; do
    NS=$(echo "$NS" | xargs)  # Trim whitespace
    if [[ -z "$NS" ]]; then
        continue
    fi

    log_step "Processing namespace: $NS"

    # Check if namespace exists
    if ! kubectl get namespace "$NS" &>/dev/null; then
        log_warn "Namespace '$NS' does not exist. Creating..."
        kubectl create namespace "$NS"
    fi

    # Create or update the secret
    log_info "  Creating/updating secret '$SECRET_NAME' in namespace '$NS'..."
    kubectl create secret docker-registry "$SECRET_NAME" \
        --docker-server="$REGISTRY_SERVER" \
        --docker-username="$USERNAME" \
        --docker-password="$PASSWORD" \
        --docker-email="$EMAIL" \
        --namespace="$NS" \
        --dry-run=client \
        -o yaml | kubectl apply -f - 2>/dev/null || true

    # Patch the default service account
    log_info "  Patching default service account in namespace '$NS'..."
    kubectl patch serviceaccount default \
        --namespace="$NS" \
        -p '{"imagePullSecrets": [{"name": "'"$SECRET_NAME"'"}]}' \
        --type=merge 2>/dev/null || log_warn "  Could not patch serviceaccount in '$NS'"
done

# Patch ArgoCD service accounts
if [[ "$PATCH_ARGOCD" == "true" ]]; then
    echo ""
    log_step "Patching ArgoCD service accounts..."

    # Check if ArgoCD is installed
    if ! kubectl get namespace argocd &>/dev/null; then
        log_warn "ArgoCD namespace not found. Skipping ArgoCD patch."
    else
        for sa in argocd-repo-server argocd-server argocd-application-controller; do
            if kubectl get serviceaccount "$sa" -n argocd &>/dev/null; then
                kubectl patch serviceaccount "$sa" \
                    --namespace="argocd" \
                    -p '{"imagePullSecrets": [{"name": "'"$SECRET_NAME"'"}]}' \
                    --type=merge 2>/dev/null
                log_info "  Patched: $sa"
            else
                log_warn "  Service account '$sa' not found in namespace 'argocd'"
            fi
        done
    fi
fi

# Add insecure registry for self-signed certificates
if [[ "$ADD_INSECURE" == "true" ]]; then
    echo ""
    log_step "Configuring ArgoCD for insecure registry..."

    if kubectl get configmap argocd-cm -n argocd &>/dev/null; then
        CURRENT_CONFIG=$(kubectl get configmap argocd-cm -n argocd -o jsonpath='{.data.config.yaml}' 2>/dev/null || echo "")

        if echo "$CURRENT_CONFIG" | grep -q "$REGISTRY_SERVER"; then
            log_info "  Registry already configured in ArgoCD"
        else
            kubectl patch configmap argocd-cm -n argocd \
                --type merge \
                -p '{"data":{"config.yaml":"'"$CURRENT_CONFIG"'\ninsecure.registry:\n- '"$REGISTRY_SERVER"'\n"}}' 2>/dev/null || true
            log_info "  Added '$REGISTRY_SERVER' to insecure registries"
        fi
    else
        log_warn "  ArgoCD configmap 'argocd-cm' not found. Skipping."
    fi
fi

# Restart ArgoCD pods
if [[ "$RESTART_ARGOCD" == "true" ]] && [[ "$PATCH_ARGOCD" == "true" ]] || [[ "$ADD_INSECURE" == "true" ]]; then
    echo ""
    log_step "Restarting ArgoCD components..."

    kubectl rollout restart deployment argocd-server -n argocd 2>/dev/null && log_info "  Restarted: argocd-server" || log_warn "  Could not restart argocd-server"
    kubectl rollout restart deployment argocd-repo-server -n argocd 2>/dev/null && log_info "  Restarted: argocd-repo-server" || log_warn "  Could not restart argocd-repo-server"
    kubectl rollout restart statefulset argocd-application-controller -n argocd 2>/dev/null && log_info "  Restarted: argocd-application-controller" || log_warn "  Could not restart argocd-application-controller"
fi

# Final summary
echo ""
log_info "=== Summary ==="
log_info "Registry: $REGISTRY_SERVER"
log_info "Secret: $SECRET_NAME"
log_info "Namespaces: ${NAMESPACE_ARRAY[*]}"
echo ""
log_info "Secrets created:"
for NS in "${NAMESPACE_ARRAY[@]}"; do
    NS=$(echo "$NS" | xargs)
    kubectl get secret "$SECRET_NAME" -n "$NS" &>/dev/null && echo "  - $NS: OK" || echo "  - $NS: FAILED"
done

echo ""
log_info "To verify your deployments, run:"
echo "  kubectl get pods -n <namespace> -o jsonpath='{.items[*].spec.imagePullSecrets[*].name}'"
echo ""
log_info "Done!"
