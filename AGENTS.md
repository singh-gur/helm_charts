# AGENTS.md - Helm Charts Development Guide

**Important**: Never index/read files in `.ignore` folder

## Core Commands

| Task | Command |
|------|---------|
| List all recipes | `just` (default task) |
| Lint chart | `helm lint charts/root-app/`, `helm lint charts/argo-cd/`, `helm lint charts/whoami/` |
| Render full template | `helm template root-app charts/root-app/ --values charts/root-app/values.yaml` |
| Test single template | `just test-render <app_name>` (e.g., `just test-render authentik`) |
| Expand to manifests | `just expand-app <app_name>` or `./scripts/expand-app.sh <app_name>` |
| Dry-run install | `helm install --dry-run root-app charts/root-app/` |
| Install ArgoCD CLI | `just install-argocd` |
| Push changes | `just push "message"` |
| Generate DB user/database SQL | `just generate-db-sql <username> <dbname>` |

### ArgoCD Lifecycle

| Task | Command |
|------|---------|
| Validate deployment | `just validate-argocd` |
| Upgrade chart version | `just upgrade-argocd <version>` |
| Rollback chart version | `just rollback-argocd <version>` |
| List available chart versions | `just list-argocd-versions` |
| Backup ArgoCD state | `just backup-argocd` |
| Backup all apps (all namespaces) | `just backup-all-apps` |
| Sync backups to S3 | `just sync-backups-to-s3 <profile> <bucket> [prefix]` |

### Data Platform

| Task | Command |
|------|---------|
| Init Polaris catalog/roles/grants | `just init-polaris` |
| Get Zitadel token for Polaris/Trino | `just get-zitadel-token` |
| Register existing Iceberg tables in Polaris | `just migrate-iceberg-to-polaris <args>` |

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
| **Local** | `charts/whoami/`, `charts/fission-hello/` | Custom applications with local templates |

Most `root-app` templates do not reference local charts — they point ArgoCD directly at external Helm repos (e.g., `charts.redpanda.com`, `grafana.github.io/helm-charts`) with inline `helm.values` overrides.

### Data Platform Flow
- Trino queries Iceberg via `trino.catalogs.iceberg.catalogType`: `rest` (Polaris, default) or `jdbc` (PostgreSQL-backed).
- Polaris manages Iceberg catalog metadata and authorization; Zitadel provides OIDC tokens.
- Table data and metadata files remain in S3-compatible object storage.

### Directory Structure
```
charts/
  root-app/
    Chart.yaml          # Root app metadata
    values.yaml         # App configurations (source of truth for all versions)
    values_local.yaml   # Local overrides (gitignored)
    values.schema.json
    templates/          # ArgoCD Application CRDs, one per app
      airflow.yaml
      authentik.yaml
      trino.yaml
      whoami.yaml
      ...
  argo-cd/
    Chart.yaml          # External dependency reference
    values.yaml         # ArgoCD overrides
  whoami/               # Local chart
  fission-hello/        # Local chart (sample Fission function)
scripts/                # expand-app.sh, Polaris/Trino/Zitadel helpers, secret creators
docs/                   # App-specific notes (e.g., dagster-authentication.md)
```

### Testing Workflow
1. Templates render to `.test/` directory (gitignored)
2. Use `just test-render <app>` to test individual templates
3. Use `just expand-app <app>` to generate full K8s manifests
4. Run `helm lint` before committing

## ArgoCD Application CRD Standards

Every ArgoCD Application template follows this pattern (see `charts/root-app/templates/whoami.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .Values.appname.name }}
  namespace: {{ .Values.argocdNamespace | default "default" }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    # Local chart: repoURL + path
    repoURL: https://github.com/singh-gur/helm_charts.git
    targetRevision: HEAD
    path: charts/{{ .Values.appname.path }}
    # OR external chart: repoURL + chart + targetRevision + helm.values overrides
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .Values.appname.namespace }}
  syncPolicy:
    automated:
      selfHeal: true
      prune: true            # on templates that manage orphaned resources
    syncOptions:
      - CreateNamespace=true # when the app needs its own namespace
```

**Required fields**:
- `automated.selfHeal: true` - Auto-heal on drift
- `resources-finalizer.argocd.argoproj.io` - Cascading delete
- `{{ .Values.argocdNamespace | default "default" }}` - Never hardcode `argocd` as the Application namespace

## Available Applications

App versions drift constantly — `charts/root-app/values.yaml` is the source of truth for every `version:`. Enable/disable per app via `enabled: bool`.

### Observability
- **lgtm** - Grafana, Loki, Tempo, Mimir stack
- **alloy** - Grafana Alloy agent
- **promtail** - Log scraping (Bitnami)
- **k8s-monitoring** - Grafana Kubernetes monitoring
- **openobserve** - OpenObserve log/metrics platform
- **uptime** - Uptime monitoring

### CI/CD & Orchestration
- **argocd** - GitOps controller (external chart via `charts/argo-cd/`)
- **argowf** - Argo Workflows
- **airflow** - Apache Airflow (external PostgreSQL, custom image)

### Development & Platform
- **authentik** - Identity provider
- **zitadel** - Identity solution (OIDC provider for Polaris/Trino)
- **oauth2-proxy** - OAuth2 proxy for ingress auth
- **coder** - Self-hosted dev environments
- **dagster** - Data orchestrator (see `docs/dagster-authentication.md`)
- **prefect** + **prefect-worker** - Workflow orchestration
- **windmill** - Dev tool platform
- **openproject** - Project management
- **rancher** - Kubernetes management
- **fission** + **fissionauth** - Fission serverless functions
- **whoami** - Local sample chart
- **fission-hello** - Local sample Fission function chart

### Data & Analytics
- **trino** - Distributed SQL query engine (Iceberg via Polaris REST or JDBC catalog, configurable)
- **polaris** - Apache Iceberg REST Catalog
- **kyuubi** - Thrift JDBC/ODBC server
- **datahub** (+ **datahub-prerequisites**) - Data metadata platform
- **redpanda** - Kafka-compatible streaming

### LLM/Observability Tooling
- **langfuse** - LLM tracing/observability
- **opensandbox** - AI agent sandbox platform (controller + lifecycle server; Kata microVM sandboxes in the `opensandbox` namespace, control plane in `opensandbox-system`)

### Other
- **ghost** - CMS platform
- **protonbridge** - Email bridge
- **rootapp** - Self-referencing root Application

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
# Applications live in the namespace set by argocdNamespace (values.yaml, currently default)
kubectl get application <app> -n default -o yaml | grep -A5 source

# Check for finalizer issues
kubectl get application <app> -n default -o jsonpath='{.metadata.finalizers}'
```

### Values Not Applying
```bash
# Expand to manifests and inspect
just expand-app <app>
cat .test/<app>-full-manifests.yaml | grep -A5 <config_key>
```
