# AGENTS.md - Development Guidelines for Helm Charts Repository

**Important Notes**

- Please do not index or read any files that are in .ignore folder

## Build/Test/Lint Commands

- **Validate charts**: `helm lint charts/root-app/`, `helm lint charts/argo-cd/`, `helm lint charts/whoami/`
- **Template/preview**: `helm template root-app charts/root-app/ --values charts/root-app/values.yaml`
- **Test single template**: `just test-render <app_name>` (e.g., `just test-render langfuse`)
- **Expand app to full manifests**: `just expand-app <app_name>` or `./expand-app.sh <app_name>`
- **Dry-run install**: `helm install --dry-run root-app charts/root-app/`

## Code Style & Conventions

- **YAML Structure**: Use 2-space indentation, follow Helm template conventions
- **Naming**: Use kebab-case for resource names, camelCase for values.yaml keys
- **Templates**: All ArgoCD Applications use conditional rendering: `{{- if .Values.appname.enabled }}`
- **Values**: Each app has `enabled: bool`, `version: string`, and `ingress.host: subdomain.gsingh.io`
- **Ingress**: All apps use individual subdomains pattern (e.g., `grafana.gsingh.io`, `ide.gsingh.io`)
- **ArgoCD Apps**: Always include `automated.selfHeal: true` and `resources-finalizer.argocd.argoproj.io`

## Repository Patterns

- **App of Apps**: Root app manages all child applications via ArgoCD Application CRDs
- **External Charts**: Reference specific versions from external Helm repositories
- **Local Charts**: Use `path: charts/appname` for custom applications like whoami
- **Git Operations**: Use `just push "commit message"` for standardized commits
- **Testing**: Templates render to `.test/` directory (gitignored)

## File Structure

- **Root App**: `charts/root-app/templates/` contains one YAML per application
- **Values**: Control app deployment via `charts/root-app/values.yaml`
- **Custom Apps**: Local charts in `charts/` with standard Helm structure
