#!/bin/bash
#
# ArgoCD v3.0 Upgrade Impact Detection Script
# This script checks your current ArgoCD installation for potential issues
# when upgrading from v2.x to v3.0
#
# Usage: ./detect-argocd-upgrade-impact.sh
#

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
CRITICAL=0
WARNING=0
OK=0

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  ArgoCD v3.0 Upgrade Impact Detection                         ║${NC}"
echo -e "${BLUE}║  Checking for breaking changes and required actions           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to print section header
print_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Function to print result
print_result() {
    local status=$1
    local message=$2
    local details=$3
    
    case $status in
        "CRITICAL")
            echo -e "${RED}🔴 CRITICAL:${NC} $message"
            [ -n "$details" ] && echo -e "   ${RED}$details${NC}"
            ((CRITICAL++))
            ;;
        "WARNING")
            echo -e "${YELLOW}⚠️  WARNING:${NC} $message"
            [ -n "$details" ] && echo -e "   ${YELLOW}$details${NC}"
            ((WARNING++))
            ;;
        "OK")
            echo -e "${GREEN}✅ OK:${NC} $message"
            [ -n "$details" ] && echo -e "   ${GREEN}$details${NC}"
            ((OK++))
            ;;
    esac
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed or not in PATH${NC}"
    exit 1
fi

# Check if argocd namespace exists
if ! kubectl get namespace argocd &> /dev/null; then
    echo -e "${RED}Error: argocd namespace not found${NC}"
    exit 1
fi

# ============================================================================
# 1. Resource Tracking Method
# ============================================================================
print_section "1. Resource Tracking Method"

TRACKING=$(kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.application\.resourceTrackingMethod}' 2>/dev/null || echo "")

if [ -z "$TRACKING" ] || [ "$TRACKING" = "label" ]; then
    print_result "CRITICAL" "Using label-based tracking (default in v2)" \
        "Action: Plan to sync all applications after upgrade to prevent orphaned resources"
else
    print_result "OK" "Already using annotation-based tracking"
fi

# ============================================================================
# 2. ApplyOutOfSyncOnly Applications
# ============================================================================
print_section "2. Applications with ApplyOutOfSyncOnly"

APPS=$(kubectl get applications.argoproj.io -A -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.syncPolicy.syncOptions[]? == "ApplyOutOfSyncOnly=true") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null || echo "")

if [ -n "$APPS" ]; then
    APP_COUNT=$(echo "$APPS" | wc -l)
    print_result "CRITICAL" "Found $APP_COUNT application(s) with ApplyOutOfSyncOnly=true" \
        "These applications MUST be synced explicitly after upgrade"
    echo ""
    echo "   Applications:"
    echo "$APPS" | sed 's/^/      - /'
else
    print_result "OK" "No applications with ApplyOutOfSyncOnly=true"
fi

# ============================================================================
# 3. Logs RBAC Enforcement
# ============================================================================
print_section "3. Logs RBAC Enforcement"

LOG_ENFORCE=$(kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.server\.rbac\.log\.enforce\.enable}' 2>/dev/null || echo "")
DEFAULT_POLICY=$(kubectl get cm argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.default}' 2>/dev/null || echo "")

if [ "$LOG_ENFORCE" = "true" ]; then
    print_result "OK" "Logs RBAC enforcement already enabled"
elif [[ "$DEFAULT_POLICY" =~ "role:readonly" ]] || [[ "$DEFAULT_POLICY" =~ "role:admin" ]]; then
    print_result "OK" "Using default role with logs access (readonly or admin)"
else
    print_result "CRITICAL" "Logs RBAC not configured" \
        "Action: Add 'logs, get' permission to RBAC policies before upgrade"
fi

# ============================================================================
# 4. Legacy Repository Configuration
# ============================================================================
print_section "4. Legacy Repository Configuration"

LEGACY_REPOS=$(kubectl get cm argocd-cm -n argocd -o jsonpath="[{.data.repositories}, {.data['repository\.credentials']}, {.data['helm\.repositories']}]" 2>/dev/null || echo "[, , ]")

if [ "$LEGACY_REPOS" = "[, , ]" ]; then
    print_result "OK" "No legacy repository configuration in argocd-cm"
else
    print_result "CRITICAL" "Found legacy repository configuration in argocd-cm" \
        "Action: Migrate repositories to Secrets before upgrade"
fi

# ============================================================================
# 5. Null Values in Helm Charts
# ============================================================================
print_section "5. Null Values in Helm Charts"

if [ -d "charts" ]; then
    NULL_FILES=$(find charts/ -name "values.yaml" -exec grep -l ": null" {} \; 2>/dev/null || echo "")
    
    if [ -n "$NULL_FILES" ]; then
        FILE_COUNT=$(echo "$NULL_FILES" | wc -l)
        print_result "CRITICAL" "Found null values in $FILE_COUNT values.yaml file(s)" \
            "Action: Remove all 'null' values before upgrade (Helm 3.17.1 breaking change)"
        echo ""
        echo "   Files with null values:"
        echo "$NULL_FILES" | sed 's/^/      - /'
    else
        print_result "OK" "No null values found in Helm charts"
    fi
else
    print_result "WARNING" "charts/ directory not found - skipping null value check"
fi

# ============================================================================
# 6. Current ArgoCD Version
# ============================================================================
print_section "6. Current ArgoCD Version"

CURRENT_VERSION=$(kubectl exec -n argocd deployment/argocd-server -- argocd version --client --short 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")

if [ "$CURRENT_VERSION" != "unknown" ]; then
    MAJOR_VERSION=$(echo "$CURRENT_VERSION" | cut -d. -f1 | sed 's/v//')
    
    if [ "$MAJOR_VERSION" -ge 3 ]; then
        print_result "OK" "Already running ArgoCD v3.x ($CURRENT_VERSION)"
    else
        print_result "WARNING" "Running ArgoCD $CURRENT_VERSION (will upgrade to v3.x)"
    fi
else
    print_result "WARNING" "Could not determine current ArgoCD version"
fi

# ============================================================================
# 7. RBAC Configuration
# ============================================================================
print_section "7. RBAC Configuration"

RBAC_POLICY=$(kubectl get cm argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.csv}' 2>/dev/null || echo "")

if [ -z "$RBAC_POLICY" ]; then
    print_result "WARNING" "No custom RBAC policies found" \
        "Using default policies - verify logs access after upgrade"
else
    # Check if logs permission exists
    if echo "$RBAC_POLICY" | grep -q "logs.*get"; then
        print_result "OK" "Found logs permissions in RBAC policies"
    else
        print_result "CRITICAL" "No logs permissions found in RBAC policies" \
            "Action: Add 'logs, get' permissions to all roles that need log access"
    fi
    
    # Check for fine-grained permissions
    if echo "$RBAC_POLICY" | grep -q "update/\*\|delete/\*"; then
        print_result "OK" "Found fine-grained sub-resource permissions"
    else
        print_result "WARNING" "No fine-grained sub-resource permissions found" \
            "Consider adding 'update/*' and 'delete/*' permissions for resource management"
    fi
fi

# ============================================================================
# 8. Dex Configuration
# ============================================================================
print_section "8. Dex SSO Configuration"

DEX_ENABLED=$(kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.dex\.config}' 2>/dev/null || echo "")

if [ -n "$DEX_ENABLED" ]; then
    print_result "WARNING" "Dex SSO is configured" \
        "Action: Update RBAC policies to use federated_claims.user_id instead of sub claim"
else
    print_result "OK" "Dex SSO not configured"
fi

# ============================================================================
# 9. ApplicationSet Configuration
# ============================================================================
print_section "9. ApplicationSet Configuration"

APPSETS=$(kubectl get applicationsets.argoproj.io -A -o json 2>/dev/null | \
    jq -r '.items[] | select(
        .spec.applyNestedSelectors != true and
        .spec.generators[][].generators[][].generators[].selector != null
    ) | .metadata.namespace + "/" + .metadata.name' 2>/dev/null || echo "")

if [ -n "$APPSETS" ]; then
    APPSET_COUNT=$(echo "$APPSETS" | wc -l)
    print_result "WARNING" "Found $APPSET_COUNT ApplicationSet(s) with nested selectors and applyNestedSelectors != true" \
        "Action: Review and remove nested selectors or set applyNestedSelectors=true"
    echo ""
    echo "   ApplicationSets:"
    echo "$APPSETS" | sed 's/^/      - /'
else
    print_result "OK" "No ApplicationSets with nested selector issues"
fi

# ============================================================================
# 10. Metrics Configuration
# ============================================================================
print_section "10. Legacy Metrics Usage"

LEGACY_METRICS=$(kubectl get cm argocd-cmd-params-cm -n argocd -o jsonpath='{.data.ARGOCD_LEGACY_CONTROLLER_METRICS}' 2>/dev/null || echo "")

if [ "$LEGACY_METRICS" = "true" ]; then
    print_result "WARNING" "Legacy controller metrics enabled" \
        "Action: Update monitoring dashboards to use argocd_app_info metric before upgrade"
else
    print_result "OK" "Not using legacy controller metrics"
fi

# ============================================================================
# 11. Resource Exclusions
# ============================================================================
print_section "11. Resource Exclusions Configuration"

EXCLUSIONS=$(kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.resource\.exclusions}' 2>/dev/null || echo "")

if [ -z "$EXCLUSIONS" ]; then
    print_result "WARNING" "No custom resource exclusions configured" \
        "v3.0 adds default exclusions for Endpoints, EndpointSlice, Lease, etc."
else
    print_result "OK" "Custom resource exclusions configured"
fi

# ============================================================================
# 12. Health Status Persistence
# ============================================================================
print_section "12. Health Status Persistence"

HEALTH_PERSIST=$(kubectl get cm argocd-cmd-params-cm -n argocd -o jsonpath='{.data.controller\.resource\.health\.persist}' 2>/dev/null || echo "")

if [ -z "$HEALTH_PERSIST" ] || [ "$HEALTH_PERSIST" = "true" ]; then
    print_result "WARNING" "Health status persisted in Application CR (v2 default)" \
        "v3.0 stores health externally by default for better performance"
else
    print_result "OK" "Health status already stored externally"
fi

# ============================================================================
# 13. Application Status Check
# ============================================================================
print_section "13. Current Application Status"

TOTAL_APPS=$(kubectl get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l || echo "0")
HEALTHY_APPS=$(kubectl get applications.argoproj.io -A -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.health.status == "Healthy") | .metadata.name' 2>/dev/null | wc -l || echo "0")
SYNCED_APPS=$(kubectl get applications.argoproj.io -A -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.sync.status == "Synced") | .metadata.name' 2>/dev/null | wc -l || echo "0")

if [ "$TOTAL_APPS" -eq 0 ]; then
    print_result "WARNING" "No applications found"
else
    echo -e "   Total Applications: $TOTAL_APPS"
    echo -e "   Healthy: $HEALTHY_APPS"
    echo -e "   Synced: $SYNCED_APPS"
    
    if [ "$HEALTHY_APPS" -eq "$TOTAL_APPS" ] && [ "$SYNCED_APPS" -eq "$TOTAL_APPS" ]; then
        print_result "OK" "All applications are healthy and synced"
    else
        print_result "WARNING" "Some applications are not healthy or synced" \
            "Recommendation: Fix application issues before upgrading"
    fi
fi

# ============================================================================
# 14. Cluster Health
# ============================================================================
print_section "14. ArgoCD Cluster Health"

PODS_READY=$(kubectl get pods -n argocd --no-headers 2>/dev/null | grep -c "Running" || echo "0")
PODS_TOTAL=$(kubectl get pods -n argocd --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$PODS_READY" -eq "$PODS_TOTAL" ] && [ "$PODS_TOTAL" -gt 0 ]; then
    print_result "OK" "All ArgoCD pods are running ($PODS_READY/$PODS_TOTAL)"
else
    print_result "WARNING" "Some ArgoCD pods are not running ($PODS_READY/$PODS_TOTAL)" \
        "Recommendation: Fix pod issues before upgrading"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Detection Summary                                             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "   ${RED}Critical Issues: $CRITICAL${NC}"
echo -e "   ${YELLOW}Warnings: $WARNING${NC}"
echo -e "   ${GREEN}OK: $OK${NC}"
echo ""

if [ $CRITICAL -gt 0 ]; then
    echo -e "${RED}⚠️  CRITICAL ISSUES FOUND!${NC}"
    echo -e "${RED}   You MUST address all critical issues before upgrading.${NC}"
    echo ""
    echo -e "   Next Steps:"
    echo -e "   1. Review all critical issues above"
    echo -e "   2. Follow remediation steps in tasks/argocd-upgrade-v3.md"
    echo -e "   3. Re-run this script to verify fixes"
    echo -e "   4. Create backups before upgrading"
    echo ""
    exit 1
elif [ $WARNING -gt 0 ]; then
    echo -e "${YELLOW}⚠️  WARNINGS FOUND${NC}"
    echo -e "${YELLOW}   Review warnings and plan accordingly.${NC}"
    echo ""
    echo -e "   Next Steps:"
    echo -e "   1. Review all warnings above"
    echo -e "   2. Consult tasks/argocd-upgrade-v3.md for details"
    echo -e "   3. Create backups before upgrading"
    echo -e "   4. Proceed with upgrade when ready"
    echo ""
    exit 0
else
    echo -e "${GREEN}✅ NO CRITICAL ISSUES FOUND!${NC}"
    echo -e "${GREEN}   Your cluster appears ready for upgrade.${NC}"
    echo ""
    echo -e "   Next Steps:"
    echo -e "   1. Create backups (see tasks/argocd-upgrade-v3.md)"
    echo -e "   2. Review the full upgrade plan"
    echo -e "   3. Choose staged or direct upgrade approach"
    echo -e "   4. Schedule maintenance window"
    echo -e "   5. Execute upgrade"
    echo ""
    exit 0
fi
