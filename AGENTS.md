# AGENTS.md - Helm Charts Development Guide

**Important**: Never index/read files in `.ignore` folder

## Core Commands

| Task | Command |
|------|---------|
| **Lint chart** | `helm lint charts/root-app/`, `helm lint charts/argo-cd/`, `helm lint charts/whoami/` |
| **Render full template** | `helm template root-app charts/root-app/ --values charts/root-app/values.yaml` |
| **Test single template** | `just test-render <app_name>` (e.g., `just test-render authentik`) |
| **Expand to manifests** | `just expand-app <app_name>` or `./scripts/expand-app.sh <app_name>` |
| **Dry-run install** | `helm install --dry-run root-app charts/root-app/` |
| **Install ArgoCD CLI** | `just install-argocd` |
| **Push changes** | `just push "message"` |

## Code Style Standards

### YAML Conventions
- **Indentation**: 2 spaces (no tabs)
- **Line length**: Max 160 characters for readability
- **Comments**: Use `#` for comments, explain non-obvious configurations

### Naming Conventions
- **Resources**: kebab-case (e.g., `my-app-deployment`)
- **Values keys**: camelCase (e.g., `existingSecret`, `hostPath`)
- **Chart names**: kebab-case (e.g., `root-app`, `argo-cd`)

### Helm Template Patterns
```yaml
# Conditional rendering
{{- if .Values.appname.enabled }}
# ...
{{- end }}

# Secret references
existingSecret: {{ .Values.appname.existingSecret }}
userKey: {{ .Values.appname.userKey }}
passwordKey: {{ .Values.appname.passwordKey }}
```

### Values Schema Requirements
Each app entry should include:
- `enabled: bool` - Enable/disable the application
- `version: string` - Chart or application version
- `namespace: string` - Target namespace (defaults to default)
- `ingress.host: string` - Subdomain for ingress (e.g., `grafana.gsingh.io`)
- `existingSecret: string` - Secret name for credentials

## Architecture Overview

### App of Apps Pattern
The `root-app` chart manages all child applications via ArgoCD Application CRDs. This enables:
- Single point of configuration
- Automatic synchronization
- Cascaded deletions with finalizers

### Chart Types

| Type | Location | Description |
|------|----------|-------------|
| **Root** | `charts/root-app/` | ArgoCD Application CRDs that reference children |
| **External** | `charts/argo-cd/` | Dependencies on external Helm repos (e.g., argo-helm) |
| **Local** | `charts/whoami/` | Custom applications with local templates |

### Directory Structure
```
charts/
  root-app/
    Chart.yaml          # Root app metadata
    values.yaml         # App configurations
    values_local.yaml   # Local overrides (gitignored)
    templates/          # ArgoCD Application CRDs
      authentik.yaml
      grafana.yaml
      whoami.yaml
      ...
  argo-cd/
    Chart.yaml          # External dependency reference
    values.yaml         # ArgoCD overrides
  whoami/
    Chart.yaml          # Local chart metadata
    values.yaml         # Empty (all defaults)
    templates/          # K8s manifests
      deployment.yaml
      service.yaml
      ingress.yaml
```

### Testing Workflow
1. Templates render to `.test/` directory (gitignored)
2. Use `just test-render <app>` to test individual templates
3. Use `just expand-app <app>` to generate full K8s manifests
4. Run `helm lint` before committing

## ArgoCD Application CRD Standards

Every ArgoCD Application template must include:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .Values.appname.name }}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/gsingh/helm_charts.git
    targetRevision: HEAD
    path: charts/{{ .Values.appname.path }}
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .Values.appname.namespace }}
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

**Required fields**:
- `automated.selfHeal: true` - Auto-heal on drift
- `resources-finalizer.argocd.argoproj.io` - Cascading delete
- `prune: true` - Remove orphaned resources

## Available Applications

### Observability
- **lgtm** - Grafana, Loki, Tempo, Mimir stack (v3.0.1)
- **alloy** - Grafana Alloy agent (v1.0.3)
- **promtail** - Log scraping (Bitnami)

### CI/CD & Orchestration
- **argo-cd** - GitOps controller (v7.3.6)
- **argo-wf** - Argo Workflows
- **airflow** - Apache Airflow (v25.0.2)

### Development & Platform
- **authentik** - Identity provider (v2025.10.3)
- **coder** - Self-hosted dev environments
- **dagster** - Data orchestrator
- **prefect** - Workflow orchestration
- **windmill** - Dev tool platform

### Data & Analytics
- **trino** - Distributed SQL query engine
- **kyuubi** - Thrift JDBC/ODBC server

### Other
- **ghost** - CMS platform
- **openproject** - Project management
- **proton-bridge** - Email bridge
- **uptime** - Monitoring
- **rancher** - Kubernetes management
- **zitadel** - Identity solution

## Secrets Management

All credentials use existing secrets pattern:
```yaml
existingSecret: my-app-credentials
userKey: admin-user      # Key in the secret
passwordKey: admin-password
```

**Never commit actual secrets** - Use `values_local.yaml` for local overrides.

## Common Issues & Debugging

### Template Rendering Fails
```bash
# Check template syntax
helm template root-app charts/root-app/ --debug
```

### ArgoCD App Not Syncing
```bash
# Verify repo URL and path
kubectl get application <app> -n argocd -o yaml | grep -A5 source

# Check for finalizer issues
kubectl get application <app> -n argocd -o jsonpath='{.metadata.finalizers}'
```

### Values Not Applying
```bash
# Expand to manifests and inspect
just expand-app <app>
cat .test/<app>-full-manifests.yaml | grep -A5 <config_key>
```
