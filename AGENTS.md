# AGENTS.md - Helm Charts Development Guide

**Important**: Never index/read files in `.ignore` folder

## Commands

- **Lint**: `helm lint charts/root-app/`, `helm lint charts/argo-cd/`, `helm lint charts/whoami/`
- **Template**: `helm template root-app charts/root-app/ --values charts/root-app/values.yaml`
- **Test single template**: `just test-render <app_name>` (e.g., `just test-render langfuse`)
- **Expand to manifests**: `just expand-app <app_name>` or `./scripts/expand-app.sh <app_name>`
- **Dry-run**: `helm install --dry-run root-app charts/root-app/`

## Code Style

- **YAML**: 2-space indentation, follow Helm template conventions
- **Naming**: kebab-case for resource names, camelCase for values.yaml keys
- **Templates**: Use conditional rendering `{{- if .Values.appname.enabled }}`
- **Values**: Include `enabled: bool`, `version: string`, `ingress.host: subdomain.gsingh.io`
- **Ingress**: Use subdomain pattern (e.g., `grafana.gsingh.io`)
- **ArgoCD Apps**: Always include `automated.selfHeal: true` and `resources-finalizer.argocd.argoproj.io`

## Architecture

- **App of Apps**: Root app manages children via ArgoCD Application CRDs
- **External Charts**: Reference specific versions from external Helm repos
- **Local Charts**: Use `path: charts/appname` for custom apps (e.g., whoami)
- **Testing**: Templates render to `.test/` directory (gitignored)
