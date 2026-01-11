# Helm Charts Repository

A collection of Helm charts for deploying applications to Kubernetes using GitOps with ArgoCD.

## Overview

This repository contains Helm charts managed via the **App of Apps** pattern, where a root ArgoCD Application manages all child applications. This enables declarative, self-healing infrastructure deployments.

## Charts Structure

| Chart | Type | Description |
|-------|------|-------------|
| [root-app](charts/root-app/) | Root | ArgoCD Application CRDs for all child apps |
| [argo-cd](charts/argo-cd/) | External | ArgoCD deployment from argo-helm |
| [whoami](charts/whoami/) | Local | Simple whoami application (example) |

## Quick Start

### Prerequisites

- Helm v3.x
- kubectl configured with cluster access
- (Optional) ArgoCD CLI: `just install-argocd`

### Rendering Templates

```bash
# Render all templates
helm template root-app charts/root-app/ --values charts/root-app/values.yaml

# Render a single application
just test-render authentik

# Expand to full Kubernetes manifests
just expand-app authentik
```

### Linting Charts

```bash
# Lint root app
helm lint charts/root-app/

# Lint specific chart
helm lint charts/whoami/
```

### Dry-Run Installation

```bash
# Dry-run install to validate
helm install --dry-run root-app charts/root-app/
```

## Adding New Applications

### 1. Create values.yaml entry

Add to `charts/root-app/values.yaml`:

```yaml
newapp:
  enabled: true
  version: "1.0.0"
  namespace: default
  name: newapp
  path: newapp
  ingress:
    enabled: true
    host: newapp.gsingh.io
  existingSecret: newapp-credentials
```

### 2. Create ArgoCD Application template

Create `charts/root-app/templates/newapp.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .Values.newapp.name }}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/gsingh/helm_charts.git
    targetRevision: HEAD
    path: charts/newapp
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .Values.newapp.namespace }}
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

### 3. Validate

```bash
just test-render newapp
helm lint charts/root-app/
```

## Configuration

### Global Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `argocdNamespace` | Namespace for ArgoCD | `default` |

### Per-App Settings

Each application supports:
- `enabled` - Enable/disable deployment
- `version` - Chart/application version
- `namespace` - Target namespace
- `ingress.host` - Subdomain for ingress
- `existingSecret` - Secret containing credentials

### Local Overrides

Create `charts/root-app/values_local.yaml` for local overrides (gitignored):

```yaml
# values_local.yaml
authentik:
  enabled: true
  version: "local-dev"
```

## Available Applications

### Observability
- **lgtm** - Grafana, Loki, Tempo, Mimir stack
- **alloy** - Grafana Alloy agent
- **promtail** - Log scraper

### CI/CD & Workflows
- **argo-cd** - GitOps controller
- **argo-wf** - Workflow automation
- **airflow** - Data pipelines

### Development
- **authentik** - Identity provider
- **coder** - Dev environments
- **dagster** - Data orchestrator
- **prefect** - Workflows
- **windmill** - Developer platform

### Data & Analytics
- **trino** - SQL query engine
- **kyuubi** - JDBC interface

### Other
- **ghost** - CMS
- **openproject** - Project management
- **proton-bridge** - Email
- **uptime** - Monitoring
- **rancher** - K8s management
- **zitadel** - Identity management

## Repository Commands

This project uses [Just](https://github.com/casey/just) for task automation:

| Command | Description |
|---------|-------------|
| `just install-argocd` | Install ArgoCD CLI |
| `just test-render <app>` | Render single template |
| `just expand-app <app>` | Expand to full manifests |
| `just push "message"` | Commit and push changes |

## Secrets Management

All credentials are managed via Kubernetes Secrets. Use `existingSecret` to reference pre-created secrets:

```yaml
existingSecret: my-app-credentials
userKey: username
passwordKey: password
```

Never commit actual secrets. Use `values_local.yaml` for local development.

## Testing

Templates render to `.test/` directory (gitignored):

```bash
# View rendered template
cat .test/authentik-rendered.yaml

# View expanded manifests
cat .test/authentik-full-manifests.yaml
```

## Contributing

1. Add application configuration to `values.yaml`
2. Create ArgoCD Application template in `templates/`
3. Validate with `just test-render` and `helm lint`
4. Commit with descriptive message

## License

This project follows the repository's overall license.
