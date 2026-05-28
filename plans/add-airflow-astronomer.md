# Simple Implementation Plan: Add Airflow (Astronomer Chart) to Root App

## Overview

Add Apache Airflow to the root-app using the Astronomer Helm chart, configured with external PostgreSQL database. Pod logs will be collected automatically by the existing Promtail deployment.

## Relevant Context

- Astronomer Airflow chart version: 1.17.33 (latest, wraps Airflow 2.4.3)
- Chart repository: https://helm.astronomer.io
- Chart structure: Outer Astronomer wrapper chart contains nested Apache Airflow chart
- External PostgreSQL pattern exists in repo (192.168.2.119:5432)
- Promtail already collecting pod logs cluster-wide (Airflow logs will appear in Loki automatically)
- **Database configuration**: Uses `data.metadataConnection` (inline) or `data.metadataSecretName` (secret reference)
- **Secret naming**: metadataSecretName, fernetKeySecretName, webserverSecretKeySecretName
- **Samples directory**: Existing `samples/` contains example secrets for other apps (follow same pattern)

## Assumptions

- External PostgreSQL database "airflow" already exists on 192.168.2.119
- Database credentials will be stored in a Kubernetes secret named "airflow-metadata"
- Airflow will run in its own namespace (airflow)
- Web UI will be accessible at airflow.gsingh.io
- Using KubernetesExecutor for task execution (chart default)
- Default Airflow authentication (no OIDC integration)
- Rely on Promtail for pod log collection (already running in cluster)

## Single-Phase Plan

- **Objective**: Deploy Airflow with external PostgreSQL and sample secret templates
- **Status**: Not Started
- **Complexity**: Medium
- **Estimated Time**: 30-45 minutes
- **Context**: Following established patterns from dagster.yaml and prefect.yaml templates

## Files

| Path | Purpose |
|------|---------|
| `charts/root-app/values.yaml` | Add `airflow` configuration section |
| `charts/root-app/templates/airflow.yaml` | ArgoCD Application resource for Airflow deployment |
| `samples/airflow-metadata.yaml` | Sample PostgreSQL connection secret |
| `samples/airflow-fernet-key.yaml` | Sample Fernet key secret |
| `samples/airflow-webserver-secret-key.yaml` | Sample Flask session key secret |

## Implementation Tasks

- [ ] Add airflow configuration to `charts/root-app/values.yaml` with:
  - enabled: true
  - version: "1.17.33"
  - namespace: "airflow"
  - ingress.host: "airflow.gsingh.io"
  - postgresql configuration (host, port, database, username, existingSecret: "airflow-metadata")
  - fernetKeySecretName: "airflow-fernet-key"
  - webserverSecretKeySecretName: "airflow-webserver-secret-key"
  
- [ ] Create `charts/root-app/templates/airflow.yaml` with:
  - ArgoCD Application resource following dagster.yaml pattern
  - External PostgreSQL via `data.metadataConnection` (host: 192.168.2.119, port: 5432, db: airflow)
  - Secret references: data.metadataSecretName, fernetKeySecretName, webserverSecretKeySecretName
  - Ingress configuration for web UI at airflow.gsingh.io
  - KubernetesExecutor enabled (default)
  - Sync policy with automated self-heal and prune
  
- [ ] Create sample secret files in `samples/` directory:
  - `samples/airflow-metadata.yaml` - PostgreSQL connection string secret template
  - `samples/airflow-fernet-key.yaml` - Fernet encryption key secret template
  - `samples/airflow-webserver-secret-key.yaml` - Flask session key secret template
  
- [ ] Add finalizer for cascading deletion

## Verification

- [ ] Run `helm lint charts/root-app/` to validate Helm chart syntax
- [ ] Run `just test-render airflow` to render templates without deploying
- [ ] Verify ArgoCD can sync the application after deployment
- [ ] Check Airflow webserver is accessible at airflow.gsingh.io
- [ ] Confirm Promtail is collecting Airflow pod logs (check Loki for logs from `airflow` namespace)

## Completion Gate

User reviews the rendered ArgoCD Application manifest and confirms:
- Database secret references are correct
- Ingress and namespace settings are acceptable
- All required Airflow components are configured
- Sample secret files are complete and accurate

## Outputs

- `charts/root-app/values.yaml` - Updated with `airflow` section
- `charts/root-app/templates/airflow.yaml` - ArgoCD Application resource
- `samples/airflow-metadata.yaml` - Sample PostgreSQL connection secret
- `samples/airflow-fernet-key.yaml` - Sample Fernet key secret
- `samples/airflow-webserver-secret-key.yaml` - Sample Flask session key secret
- Airflow deployment in `airflow` namespace with:
  - Webserver at airflow.gsingh.io
  - PostgreSQL connection to 192.168.2.119
  - Pod logs collected by Promtail

## Risks

- Three separate secrets must be created before deployment: airflow-metadata, airflow-fernet-key, airflow-webserver-secret-key
- Airflow database migrations need to run after deployment (handled by migrateDatabaseJob)
- Promtail must be running to collect Airflow pod logs

## Questions for User

None - all questions have been answered:
- ✓ Database secret name: airflow-metadata (confirmed)
- ✓ Log shipping: Rely on Promtail for pod logs (simpler approach)
- ✓ Executor: KubernetesExecutor (chart default)
- ✓ Web UI auth: Default Airflow authentication
- ✓ Resources: Use chart defaults
- ✓ Sample secrets: Create templates in `samples/` directory

## Secret Requirements

Before deploying, three Kubernetes secrets must be created in the airflow namespace:

1. **airflow-metadata** - PostgreSQL connection string
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: airflow-metadata
     namespace: airflow
   type: Opaque
   stringData:
     connection: postgresql://airflow:PASSWORD@192.168.2.119:5432/airflow
   ```

2. **airflow-fernet-key** - Airflow encryption key
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: airflow-fernet-key
     namespace: airflow
   type: Opaque
   stringData:
     fernet-key: <generate-with: python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())">
   ```

3. **airflow-webserver-secret-key** - Flask session encryption
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: airflow-webserver-secret-key
     namespace: airflow
   type: Opaque
   stringData:
     webserver-secret-key: <generate-with: python -c "import secrets; print(secrets.token_hex(32))">
   ```

Sample secret files will be created in `samples/` directory following the existing pattern used by other apps.
