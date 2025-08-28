# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Helm charts repository that implements a GitOps-style deployment pattern using ArgoCD. The repository manages multiple applications through a "root-app" pattern where a single parent application (root-app) manages all child applications.

## Architecture

The repository follows an "App of Apps" pattern:

1. **Root App** (`charts/root-app/`): The main ArgoCD application that manages all other applications
2. **ArgoCD Chart** (`charts/argo-cd/`): Bootstraps ArgoCD itself with custom configuration
3. **Individual Apps**: Each application is defined as an ArgoCD Application resource in `charts/root-app/templates/`

### Key Components

- **Root App Templates**: Located in `charts/root-app/templates/`, each YAML file defines an ArgoCD Application
- **Values Configuration**: `charts/root-app/values.yaml` controls which applications are enabled and their versions
- **Domain Configuration**: All applications use the `gsingh.io` domain with subdomains

## Common Commands

### Helm Operations
```bash
# Validate chart syntax
helm lint charts/root-app/
helm lint charts/argo-cd/
helm lint charts/whoami/

# Template and preview changes
helm template root-app charts/root-app/ --values charts/root-app/values.yaml
helm template argo-cd charts/argo-cd/ --values charts/argo-cd/values.yaml

# Dry-run installation
helm install --dry-run root-app charts/root-app/

# Test individual template rendering (using justfile)
just test-render <template_name>  # Renders specific template to .test/ directory
```

### Development Workflow
```bash
# Use justfile for common development tasks
just test-render langfuse  # Test rendering a specific application template
just test-render openproject  # Test complex application configurations
```

### Application Management

Applications are controlled via the `values.yaml` file in the root-app chart. Each application has:
- `enabled`: Boolean to enable/disable the app
- `version`: Helm chart version (for external charts)
- `ingress.host`: Subdomain configuration (e.g., `grafana.gsingh.io`, `ide.gsingh.io`)

Key configuration patterns in `values.yaml`:
- SSO integration with Zitadel for applications like Argo Workflows
- External database connections (e.g., OpenProject uses external PostgreSQL at 192.168.20.96)
- S3 storage configuration for applications like OpenProject
- Resource limits and requests for memory-intensive applications

### Git Operations
```bash
# After making changes, commit and push
git add .
git commit -m "description of changes"
git push origin main
```

## Application Types

The repository manages two types of applications:

1. **External Helm Charts**: Applications like Langfuse, Ghost, Coder that reference external Helm repositories
2. **Custom Applications**: Simple applications like whoami with local templates

## Important Patterns

- All ArgoCD Applications use `automated.selfHeal: true` for automatic synchronization
- Applications are deployed to the `default` namespace
- The root-app references this Git repository (`https://github.com/singh-gur/helm_charts.git`)
- Ingress configurations use individual subdomains (e.g., `grafana.gsingh.io`, `ide.gsingh.io`)
- Template conditionals use `.Values.<app>.enabled` to control application deployment
- External charts reference specific versions while custom charts use local paths
- Complex applications may have multiple configuration sections (SSO, database, storage)

## Backup Directory

The `backup/` directory contains YAML files for applications that may have been previously deployed directly to Kubernetes before being converted to the ArgoCD pattern.