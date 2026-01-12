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