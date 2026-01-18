# Install ArgoCD CLI
install-argocd:
    @echo "Installing ArgoCD CLI..."
    curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
    rm argocd-linux-amd64
    @echo "ArgoCD CLI installed successfully"
    argocd version

# Render a specific template from root-app chart
test-render template_name:
    @echo "Rendering {{template_name}} template..."
    @mkdir -p .test
    helm template root-app charts/root-app --values charts/root-app/values.yaml --show-only templates/{{template_name}}.yaml > .test/{{template_name}}-rendered.yaml
    @echo "Rendered {{template_name}} template to .test/{{template_name}}-rendered.yaml"

# Expand ArgoCD Application to full Kubernetes manifests
expand-app app_name:
    ./scripts/expand-app.sh {{app_name}}

push message:
    @echo "Push changes to the repository"
    git add .
    git commit -m "{{message}}"
    git push

# Generate SQL commands to create a user, database, and grant schema privileges
# Usage: just generate-db-sql username dbname
# Example: just generate-db-sql myuser mydb
generate-db-sql username dbname:
    # Generate random password
    @export PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32) && \
    echo "=== Generated Password: $PASSWORD ===" && \
    echo "" && \
    echo "-- Create user with password:" && \
    echo "CREATE USER \"{{username}}\" WITH PASSWORD '$PASSWORD';" && \
    echo "" && \
    echo "-- Create database with user as owner (grants all privileges automatically):" && \
    echo "CREATE DATABASE \"{{dbname}}\" OWNER \"{{username}}\";" && \
    echo "" && \
    echo "-- Ensure future objects created by others are accessible:" && \
    echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"{{username}}\";" && \
    echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"{{username}}\";"

# ============================================================================
# ArgoCD Management Recipes
# ============================================================================

# Backup ArgoCD configuration and state
backup-argocd:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Backing up ArgoCD configuration ==="
    BACKUP_DIR=".backups/argocd/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    echo "Backup directory: $BACKUP_DIR"
    echo ""
    echo "Backing up ArgoCD applications..."
    kubectl get applications -n argocd -o yaml > "$BACKUP_DIR/applications.yaml" 2>/dev/null || echo "No applications found or ArgoCD not deployed"
    echo "Backing up ArgoCD configmaps..."
    kubectl get configmaps -n argocd -o yaml > "$BACKUP_DIR/configmaps.yaml" 2>/dev/null || echo "No configmaps found"
    echo "Backing up ArgoCD secrets (metadata only, no sensitive data)..."
    kubectl get secrets -n argocd -o yaml > "$BACKUP_DIR/secrets.yaml" 2>/dev/null || echo "No secrets found"
    echo "Backing up ArgoCD deployments..."
    kubectl get deployments -n argocd -o yaml > "$BACKUP_DIR/deployments.yaml" 2>/dev/null || echo "No deployments found"
    echo "Backing up current Chart.yaml..."
    cp charts/argo-cd/Chart.yaml "$BACKUP_DIR/Chart.yaml"
    echo "Backing up current values.yaml..."
    cp charts/argo-cd/values.yaml "$BACKUP_DIR/values.yaml"
    echo ""
    echo "✅ Backup completed: $BACKUP_DIR"

# Backup all Kubernetes applications across all namespaces
backup-all-apps:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Backing up all Kubernetes applications ==="
    BACKUP_DIR=".backups/all-apps/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    echo "Backup directory: $BACKUP_DIR"
    echo ""
    echo "Backing up all deployments..."
    kubectl get deployments --all-namespaces -o yaml > "$BACKUP_DIR/deployments.yaml"
    echo "Backing up all statefulsets..."
    kubectl get statefulsets --all-namespaces -o yaml > "$BACKUP_DIR/statefulsets.yaml"
    echo "Backing up all services..."
    kubectl get services --all-namespaces -o yaml > "$BACKUP_DIR/services.yaml"
    echo "Backing up all configmaps..."
    kubectl get configmaps --all-namespaces -o yaml > "$BACKUP_DIR/configmaps.yaml"
    echo "Backing up all ingresses..."
    kubectl get ingresses --all-namespaces -o yaml > "$BACKUP_DIR/ingresses.yaml"
    echo "Backing up all PVCs..."
    kubectl get pvc --all-namespaces -o yaml > "$BACKUP_DIR/pvcs.yaml"
    echo "Backing up all ArgoCD applications..."
    kubectl get applications --all-namespaces -o yaml > "$BACKUP_DIR/argocd-applications.yaml" 2>/dev/null || echo "No ArgoCD applications found"
    echo ""
    echo "✅ Backup completed: $BACKUP_DIR"

# Sync .backups directory to S3 using AWS profile
# Usage: just sync-backups-to-s3 <aws-profile> <s3-bucket> [prefix]
# Example: just sync-backups-to-s3 my-profile s3://my-bucket
# Example with prefix: just sync-backups-to-s3 my-profile s3://my-bucket helm-backups
sync-backups-to-s3 profile bucket prefix="":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Syncing backups to S3 ==="
    echo "AWS Profile: {{profile}}"
    echo "S3 Bucket: {{bucket}}"
    if [ -n "{{prefix}}" ]; then
        S3_PATH="{{bucket}}/{{prefix}}"
        echo "Prefix: {{prefix}}"
    else
        S3_PATH="{{bucket}}"
    fi
    echo "Full S3 Path: $S3_PATH"
    echo ""
    if [ ! -d ".backups" ]; then
        echo "❌ Error: .backups directory does not exist"
        exit 1
    fi
    echo "Starting sync..."
    AWS_PROFILE={{profile}} aws s3 sync .backups "$S3_PATH" --exclude "*.git/*"
    echo ""
    echo "✅ Backup sync completed to $S3_PATH"

# Upgrade ArgoCD to a specific chart version
# Usage: just upgrade-argocd <version>
# Example: just upgrade-argocd 8.0.0
upgrade-argocd version:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== ArgoCD Upgrade Process ==="
    CURRENT_VERSION=$(grep 'version:' charts/argo-cd/Chart.yaml | head -1 | awk '{print $2}')
    echo "Current chart version: $CURRENT_VERSION"
    echo "Target chart version: {{version}}"
    echo ""
    echo "⚠️  This will update charts/argo-cd/Chart.yaml"
    echo ""
    read -p "Continue with upgrade? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Upgrade cancelled"
        exit 1
    fi
    echo ""
    echo "Updating Chart.yaml..."
    sed -i 's/version: .*/version: {{version}}/' charts/argo-cd/Chart.yaml
    echo "Running helm dependency update..."
    helm dependency update charts/argo-cd
    echo ""
    echo "Testing template rendering..."
    helm template argo-cd charts/argo-cd --values charts/argo-cd/values.yaml > /dev/null
    echo ""
    echo "Running helm lint..."
    helm lint charts/argo-cd
    echo ""
    echo "✅ Upgrade preparation complete!"
    echo ""
    echo "Next steps:"
    echo "1. Review the changes: git diff charts/argo-cd/"
    echo "2. Test the rendered templates: helm template argo-cd charts/argo-cd"
    echo "3. Commit when ready: git add charts/argo-cd && git commit -m 'Upgrade ArgoCD to {{version}}'"
    echo "4. Validate after deployment: just validate-argocd"

# Rollback ArgoCD to a specific chart version
# Usage: just rollback-argocd <version>
# Example: just rollback-argocd 7.3.6
rollback-argocd version:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== ArgoCD Rollback Process ==="
    CURRENT_VERSION=$(grep 'version:' charts/argo-cd/Chart.yaml | head -1 | awk '{print $2}')
    echo "Current chart version: $CURRENT_VERSION"
    echo "Rollback to version: {{version}}"
    echo ""
    echo "⚠️  This will revert charts/argo-cd/Chart.yaml"
    echo ""
    read -p "Continue with rollback? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Rollback cancelled"
        exit 1
    fi
    echo ""
    echo "Updating Chart.yaml..."
    sed -i 's/version: .*/version: {{version}}/' charts/argo-cd/Chart.yaml
    echo "Running helm dependency update..."
    helm dependency update charts/argo-cd
    echo ""
    echo "Testing template rendering..."
    helm template argo-cd charts/argo-cd --values charts/argo-cd/values.yaml > /dev/null
    echo ""
    echo "✅ Rollback preparation complete!"
    echo ""
    echo "Next steps:"
    echo "1. Review the changes: git diff charts/argo-cd/"
    echo "2. Commit when ready: git add charts/argo-cd && git commit -m 'Rollback ArgoCD to {{version}}'"
    echo "3. Validate after deployment: just validate-argocd"

# Validate ArgoCD deployment
validate-argocd:
    @echo "=== Validating ArgoCD Deployment ==="
    @echo ""
    @echo "📊 ArgoCD Pods Status:"
    @kubectl get pods -n argocd 2>/dev/null || echo "❌ ArgoCD namespace not found or no pods running"
    @echo ""
    @echo "📦 ArgoCD Applications:"
    @kubectl get applications -n argocd 2>/dev/null || echo "❌ No ArgoCD applications found"
    @echo ""
    @echo "🔍 ArgoCD Server Version:"
    @kubectl get deployment argocd-server -n argocd -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "❌ ArgoCD server deployment not found"
    @echo ""
    @echo ""
    @echo "🔍 Chart Version:"
    @grep 'version:' charts/argo-cd/Chart.yaml | head -1
    @echo ""
    @echo "✅ Validation complete"

# Show available ArgoCD chart versions
list-argocd-versions:
    @echo "=== Available ArgoCD Chart Versions ==="
    @echo ""
    @helm search repo argo-cd/argo-cd --versions | head -30