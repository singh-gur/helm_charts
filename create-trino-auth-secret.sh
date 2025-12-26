#!/bin/bash
set -euo pipefail

# Trino Password Authentication Secret Creator
# This script creates Kubernetes secrets for Trino password authentication

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="data-platform"
PASSWORD_SECRET_NAME="trino-password-auth"
GROUPS_SECRET_NAME="trino-groups-auth"
TEMP_DIR=$(mktemp -d)
PASSWORD_FILE="${TEMP_DIR}/password.db"
GROUPS_FILE="${TEMP_DIR}/group.db"

# Cleanup function
cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

# Print colored message
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if htpasswd is installed
check_htpasswd() {
    if ! command -v htpasswd &> /dev/null; then
        print_error "htpasswd command not found!"
        echo ""
        echo "Please install apache2-utils (Debian/Ubuntu) or httpd-tools (RHEL/CentOS):"
        echo "  Ubuntu/Debian: sudo apt-get install apache2-utils"
        echo "  RHEL/CentOS:   sudo yum install httpd-tools"
        echo "  macOS:         brew install httpd"
        exit 1
    fi
}

# Check if kubectl is installed and configured
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl command not found!"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl is not configured or cluster is not reachable!"
        exit 1
    fi
}

# Check if namespace exists
check_namespace() {
    if ! kubectl get namespace "${NAMESPACE}" &> /dev/null; then
        print_warning "Namespace '${NAMESPACE}' does not exist."
        read -p "Create namespace? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl create namespace "${NAMESPACE}"
            print_success "Namespace '${NAMESPACE}' created"
        else
            print_error "Cannot proceed without namespace"
            exit 1
        fi
    fi
}

# Create password file
create_password_file() {
    print_info "Creating password file..."
    echo ""
    
    local first_user=true
    while true; do
        read -p "Enter username (or press Enter to finish): " username
        
        if [[ -z "${username}" ]]; then
            if [[ "${first_user}" == true ]]; then
                print_error "At least one user is required!"
                continue
            else
                break
            fi
        fi
        
        # Validate username (alphanumeric, underscore, hyphen)
        if [[ ! "${username}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            print_error "Invalid username. Use only alphanumeric characters, underscore, or hyphen."
            continue
        fi
        
        if [[ "${first_user}" == true ]]; then
            # First user: create new file with -c flag
            htpasswd -cBC 10 "${PASSWORD_FILE}" "${username}"
            first_user=false
        else
            # Subsequent users: append to existing file
            htpasswd -B "${PASSWORD_FILE}" "${username}"
        fi
        
        print_success "User '${username}' added"
        echo ""
    done
    
    if [[ ! -f "${PASSWORD_FILE}" ]]; then
        print_error "No users were added!"
        exit 1
    fi
    
    print_success "Password file created with $(wc -l < "${PASSWORD_FILE}") user(s)"
}

# Create groups file
create_groups_file() {
    print_info "Creating groups file (optional)..."
    echo ""
    
    read -p "Do you want to create groups for access control? (y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return 1
    fi
    
    echo "# Group format: group_name:user1,user2,user3" > "${GROUPS_FILE}"
    echo "# Example groups:" >> "${GROUPS_FILE}"
    echo ""
    
    while true; do
        read -p "Enter group name (or press Enter to finish): " groupname
        
        if [[ -z "${groupname}" ]]; then
            break
        fi
        
        # Validate group name
        if [[ ! "${groupname}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            print_error "Invalid group name. Use only alphanumeric characters, underscore, or hyphen."
            continue
        fi
        
        read -p "Enter comma-separated usernames for group '${groupname}': " users
        
        if [[ -z "${users}" ]]; then
            print_warning "No users specified for group '${groupname}', skipping..."
            continue
        fi
        
        echo "${groupname}:${users}" >> "${GROUPS_FILE}"
        print_success "Group '${groupname}' added with users: ${users}"
        echo ""
    done
    
    # Check if any groups were actually added (more than just comments)
    if [[ $(grep -v '^#' "${GROUPS_FILE}" | grep -v '^$' | wc -l) -eq 0 ]]; then
        print_warning "No groups were added"
        return 1
    fi
    
    print_success "Groups file created"
    return 0
}

# Create Kubernetes secret for passwords
create_password_secret() {
    print_info "Creating Kubernetes secret for passwords..."
    
    # Check if secret already exists
    if kubectl get secret "${PASSWORD_SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
        print_warning "Secret '${PASSWORD_SECRET_NAME}' already exists in namespace '${NAMESPACE}'"
        read -p "Do you want to replace it? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete secret "${PASSWORD_SECRET_NAME}" -n "${NAMESPACE}"
            print_info "Existing secret deleted"
        else
            print_error "Cannot proceed without creating/updating the secret"
            exit 1
        fi
    fi
    
    kubectl create secret generic "${PASSWORD_SECRET_NAME}" \
        --from-file=password.db="${PASSWORD_FILE}" \
        --namespace="${NAMESPACE}"
    
    print_success "Password secret '${PASSWORD_SECRET_NAME}' created in namespace '${NAMESPACE}'"
}

# Create Kubernetes secret for groups
create_groups_secret() {
    if [[ ! -f "${GROUPS_FILE}" ]] || [[ $(grep -v '^#' "${GROUPS_FILE}" | grep -v '^$' | wc -l) -eq 0 ]]; then
        return
    fi
    
    print_info "Creating Kubernetes secret for groups..."
    
    # Check if secret already exists
    if kubectl get secret "${GROUPS_SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
        print_warning "Secret '${GROUPS_SECRET_NAME}' already exists in namespace '${NAMESPACE}'"
        read -p "Do you want to replace it? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete secret "${GROUPS_SECRET_NAME}" -n "${NAMESPACE}"
            print_info "Existing secret deleted"
        else
            print_warning "Skipping groups secret creation"
            return
        fi
    fi
    
    kubectl create secret generic "${GROUPS_SECRET_NAME}" \
        --from-file=group.db="${GROUPS_FILE}" \
        --namespace="${NAMESPACE}"
    
    print_success "Groups secret '${GROUPS_SECRET_NAME}' created in namespace '${NAMESPACE}'"
}

# Display next steps
show_next_steps() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Secrets created successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Enable authentication in your values file (values.yaml or values_local.yaml):"
    echo ""
    echo "   trino:"
    echo "     auth:"
    echo "       enabled: true"
    echo "       passwordAuthSecret: \"${PASSWORD_SECRET_NAME}\""
    if kubectl get secret "${GROUPS_SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
        echo "       groups:"
        echo "         enabled: true"
        echo "         groupsAuthSecret: \"${GROUPS_SECRET_NAME}\""
    fi
    echo ""
    echo "2. Commit and push your changes (if using GitOps)"
    echo ""
    echo "3. ArgoCD will automatically sync, or manually sync:"
    echo "   argocd app sync trino"
    echo ""
    echo "4. Verify the secrets:"
    echo "   kubectl get secret ${PASSWORD_SECRET_NAME} -n ${NAMESPACE}"
    if kubectl get secret "${GROUPS_SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
        echo "   kubectl get secret ${GROUPS_SECRET_NAME} -n ${NAMESPACE}"
    fi
    echo ""
    echo "5. Test authentication:"
    echo "   trino --server https://trino.gsingh.io --user <username> --password"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Create Kubernetes secrets for Trino password authentication.

OPTIONS:
    -n, --namespace NAMESPACE    Kubernetes namespace (default: data-platform)
    -p, --password-secret NAME   Password secret name (default: trino-password-auth)
    -g, --groups-secret NAME     Groups secret name (default: trino-groups-auth)
    -h, --help                   Show this help message

EXAMPLES:
    # Create secrets in default namespace
    $0

    # Create secrets in custom namespace
    $0 --namespace my-namespace

    # Use custom secret names
    $0 --password-secret my-trino-pass --groups-secret my-trino-groups

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -p|--password-secret)
                PASSWORD_SECRET_NAME="$2"
                shift 2
                ;;
            -g|--groups-secret)
                GROUPS_SECRET_NAME="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    parse_args "$@"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Trino Password Authentication Secret Creator"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Target namespace: ${NAMESPACE}"
    print_info "Password secret name: ${PASSWORD_SECRET_NAME}"
    print_info "Groups secret name: ${GROUPS_SECRET_NAME}"
    echo ""
    
    # Preflight checks
    check_htpasswd
    check_kubectl
    check_namespace
    
    # Create files
    create_password_file
    
    if create_groups_file; then
        echo ""
    fi
    
    # Create secrets
    echo ""
    create_password_secret
    create_groups_secret
    
    # Show next steps
    show_next_steps
}

# Run main function
main "$@"
