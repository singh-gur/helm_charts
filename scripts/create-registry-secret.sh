#!/bin/bash
# create-registry-secret.sh
# Creates a Kubernetes secret for pulling from private Docker registry
# and patches service accounts to use it (appends, doesn't replace existing secrets)
#
# Features:
#   - Validates credentials with docker login (if available)
#   - Appends imagePullSecrets to service accounts (preserves existing secrets)
#   - Creates secrets in multiple namespaces
#   - Patches ArgoCD service accounts for private registry access
#   - Configures ArgoCD for insecure/self-signed certificate registries
#   - Idempotent operations (safe to run multiple times)
#   - Interactive confirmation before making changes
#
# Prerequisites:
#   - kubectl configured with cluster access
#   - docker (optional, for credential validation)
#   - Appropriate RBAC permissions for target namespaces
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
#                    Accepts: true/yes/y/1 or false/no/n/0
#   -i, --insecure   Add insecure registry to ArgoCD (default: false)
#                    Use for self-signed certificates
#   -r, --restart    Restart ArgoCD pods (default: true)
#   -h, --help       Show this help message
#
# Examples:
#   # Interactive mode (recommended - prompts for credentials securely)
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
#   # All options with custom registry
#   ./create-registry-secret.sh -s regv2.gsingh.io -u myuser -p mypass -e hello@gsingh.io -n "default,kube-system"
#
# Notes:
#   - Password via CLI is visible in process list - use interactive mode for security
#   - Script validates credentials before making cluster changes (requires docker)
#   - Requires confirmation before proceeding with changes
#   - Safe to run multiple times - won't duplicate secrets in service accounts
#   - Creates namespaces if they don't exist

set -euo pipefail

# Set up temp file cleanup early
TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT INT TERM

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

# Normalize boolean values
normalize_bool() {
    local val="$1"
    case "${val,,}" in
        true|yes|y|1)
            echo "true"
            ;;
        false|no|n|0)
            echo "false"
            ;;
        *)
            echo "true"  # Default to true for backward compatibility
            ;;
    esac
}

# Patch service account with imagePullSecret (append, don't replace)
patch_serviceaccount_with_secret() {
    local sa=$1
    local ns=$2
    local secret=$3
    
    # Get existing imagePullSecrets
    local existing
    existing=$(kubectl get serviceaccount "$sa" -n "$ns" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    
    # Check if secret already exists in the list
    if echo "$existing" | grep -qw "$secret"; then
        log_info "  Secret '$secret' already attached to serviceaccount '$sa'"
        return 0
    fi
    
    # Build the patch with all secrets (existing + new)
    local secrets_json='['
    local first=true
    for s in $existing; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            secrets_json+=','
        fi
        secrets_json+="{\"name\":\"$s\"}"
    done
    
    if [[ "$first" == "false" ]]; then
        secrets_json+=','
    fi
    secrets_json+="{\"name\":\"$secret\"}]"
    
    kubectl patch serviceaccount "$sa" \
        --namespace="$ns" \
        -p "{\"imagePullSecrets\": $secrets_json}" \
        --type=merge 2>/dev/null || {
            log_warn "  Could not patch serviceaccount '$sa' in namespace '$ns'"
            return 1
        }
    
    log_info "  Patched serviceaccount '$sa' (appended secret)"
    return 0
}

show_help() {
    head -60 "$0" | tail -56
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
            log_warn "Password provided via command line - visible in process list!"
            log_warn "Consider using interactive mode for better security"
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
            PATCH_ARGOCD=$(normalize_bool "$2")
            shift 2
            ;;
        -i|--insecure)
            ADD_INSECURE=$(normalize_bool "$2")
            shift 2
            ;;
        -r|--restart)
            RESTART_ARGOCD=$(normalize_bool "$2")
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

# Validate registry credentials (optional but recommended)
log_step "Validating registry credentials..."
if command -v docker &>/dev/null; then
    if echo "$PASSWORD" | docker login "$REGISTRY_SERVER" -u "$USERNAME" --password-stdin &>/dev/null; then
        log_info "Credentials validated successfully"
        docker logout "$REGISTRY_SERVER" &>/dev/null
    else
        log_warn "Could not validate credentials (docker login failed)"
        log_warn "This might be due to:"
        log_warn "  - Incorrect username/password"
        log_warn "  - Registry server unreachable"
        log_warn "  - Docker daemon not running"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            exit 0
        fi
    fi
else
    log_warn "Docker not found - skipping credential validation"
    log_warn "Install docker to enable credential validation"
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

# Confirmation prompt
read -p "Proceed with these settings? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Aborted by user"
    exit 0
fi
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
    patch_serviceaccount_with_secret "default" "$NS" "$SECRET_NAME"
done

# Patch ArgoCD service accounts
if [[ "$PATCH_ARGOCD" == "true" ]]; then
    echo ""
    log_step "Patching ArgoCD service accounts..."

    # Check if ArgoCD is installed
    if ! kubectl get namespace argocd &>/dev/null; then
        log_warn "ArgoCD namespace not found. Skipping ArgoCD patch."
    else
        # Create secret in argocd namespace first
        log_info "  Creating/updating secret '$SECRET_NAME' in namespace 'argocd'..."
        kubectl create secret docker-registry "$SECRET_NAME" \
            --docker-server="$REGISTRY_SERVER" \
            --docker-username="$USERNAME" \
            --docker-password="$PASSWORD" \
            --docker-email="$EMAIL" \
            --namespace="argocd" \
            --dry-run=client \
            -o yaml | kubectl apply -f - 2>/dev/null || true
        
        # Patch ArgoCD service accounts
        for sa in argocd-repo-server argocd-server argocd-application-controller; do
            if kubectl get serviceaccount "$sa" -n argocd &>/dev/null; then
                patch_serviceaccount_with_secret "$sa" "argocd" "$SECRET_NAME"
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
        CURRENT_CONFIG=$(kubectl get configmap argocd-cm -n argocd -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")

        # Check if registry is already in the insecure list
        if echo "$CURRENT_CONFIG" | grep -q "^[[:space:]]*-[[:space:]]*$REGISTRY_SERVER[[:space:]]*$"; then
            log_info "  Registry '$REGISTRY_SERVER' already in insecure registries list"
        else
            # Create temporary file for safe YAML patching
            TEMP_CONFIG=$(mktemp)
            TEMP_FILES+=("$TEMP_CONFIG")
            
            # Build the new config with proper YAML formatting
            if [[ -n "$CURRENT_CONFIG" ]]; then
                # Check if insecure.registry section exists
                if echo "$CURRENT_CONFIG" | grep -q "^insecure\.registry:"; then
                    # Append to existing insecure.registry list
                    echo "$CURRENT_CONFIG" > "$TEMP_CONFIG"
                    # Find the line with insecure.registry and add our server after it
                    # Using awk to properly append to the YAML array
                    awk -v server="$REGISTRY_SERVER" '
                        /^insecure\.registry:/ {
                            print $0
                            getline
                            print $0
                            print "- " server
                            next
                        }
                        { print }
                    ' "$TEMP_CONFIG" > "$TEMP_CONFIG.new"
                    mv "$TEMP_CONFIG.new" "$TEMP_CONFIG"
                else
                    # Add new insecure.registry section
                    echo "$CURRENT_CONFIG" > "$TEMP_CONFIG"
                    cat >> "$TEMP_CONFIG" <<EOF

insecure.registry:
- $REGISTRY_SERVER
EOF
                fi
            else
                # Create new config if empty
                cat > "$TEMP_CONFIG" <<EOF
insecure.registry:
- $REGISTRY_SERVER
EOF
            fi
            
            # Apply the patch using kubectl patch
            if kubectl patch configmap argocd-cm -n argocd \
                --type merge \
                -p "{\"data\":{\"config.yaml\":\"$(cat "$TEMP_CONFIG" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')\"}}" 2>/dev/null; then
                log_info "  Added '$REGISTRY_SERVER' to insecure registries"
            else
                log_warn "  Failed to patch ArgoCD configmap - trying alternative method"
                # Fallback: use kubectl create with --dry-run and apply
                kubectl create configmap argocd-cm \
                    --from-file=config.yaml="$TEMP_CONFIG" \
                    --namespace=argocd \
                    --dry-run=client \
                    -o yaml | kubectl apply -f - 2>/dev/null || log_warn "  Failed to patch ArgoCD configmap"
            fi
        fi
    else
        log_warn "  ArgoCD configmap 'argocd-cm' not found. Skipping."
    fi
fi

# Restart ArgoCD pods
if [[ "$RESTART_ARGOCD" == "true" ]] && ( [[ "$PATCH_ARGOCD" == "true" ]] || [[ "$ADD_INSECURE" == "true" ]] ); then
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
