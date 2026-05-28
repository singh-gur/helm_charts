# Simple Implementation Plan: Add Airflow 3.x with Official Helm Chart

## Overview

Add Apache Airflow 3.x to the root-app using the official Apache Airflow Helm chart. Configure it to use an external PostgreSQL server with credentials supplied through Kubernetes Secrets, and rely on existing LGTM/Promtail log collection where practical.

## Relevant Context

- `charts/root-app/values.yaml` contains per-app configuration blocks and already uses `existingSecret` patterns for database credentials.
- `charts/root-app/templates/*.yaml` define ArgoCD `Application` resources for each app; external charts are referenced directly by `repoURL`, `chart`, and `targetRevision`.
- Latest official Airflow chart found in the Helm repository is chart version `1.21.0` with `appVersion: 3.2.0`.
- Official chart `1.21.0` supports external DB secret references through `data.metadataSecretName` and disables the bundled database with `postgresql.enabled: false`.
- For Airflow 3.x, the chart includes `apiSecretKeySecretName` and `jwtSecretName`; `webserverSecretKeySecretName` is only for Airflow <3 webserver compatibility.
- Official chart `1.21.0` exposes Airflow 3 UI/API ingress through `ingress.apiServer`.
- Existing `promtail` is enabled and pushes pod logs to `http://lgtm-loki-gateway.default.svc.cluster.local:80/loki/api/v1/push`, so Airflow pod logs should be collected without adding chart-specific log shipping.
- `samples/` contains non-secret example manifests such as `samples/dagster-postgresql-secret.yaml` for user-created Kubernetes Secrets.

## Assumptions

- External PostgreSQL is reachable at `192.168.2.119:5432`.
- Airflow database name and username will be `airflow` unless changed during implementation.
- Airflow will deploy to namespace `airflow` and use host `airflow.gsingh.io`.
- Secret values will not be committed; only placeholder sample manifests or instructions will be committed.
- Airflow pod log collection through existing Promtail/Loki is sufficient for LGTM integration.

## Single-Phase Plan

- Objective: Add an ArgoCD-managed Airflow 3.x application using the official Helm chart, external PostgreSQL secret references, and LGTM-compatible pod logs.
- Status: Not Started
- Complexity: Medium
- Estimated Time: 45-60 minutes
- Context: Implement in the root-app chart by following existing application template and values patterns.

## Files

| Path | Purpose |
| ---- | ------- |
| `charts/root-app/values.yaml` | Add the `airflow` app configuration block. |
| `charts/root-app/templates/airflow.yaml` | Add the ArgoCD Application for the official Airflow chart. |
| `samples/airflow-metadata-secret.yaml` | Add placeholder sample for the metadata DB connection secret. |
| `samples/airflow-fernet-key-secret.yaml` | Add placeholder sample for the Airflow Fernet key secret. |
| `samples/airflow-api-secret-key.yaml` | Add placeholder sample for the Airflow 3 API secret key. |
| `samples/airflow-jwt-secret.yaml` | Add placeholder sample for the Airflow 3 JWT secret. |
| `AGENTS.md` | Inspect only; update only if new workflow expectations are introduced. |

## Implementation Tasks

- [ ] Add `airflow` configuration to `charts/root-app/values.yaml` with `enabled`, `version: "1.21.0"`, `airflowVersion: "3.2.0"`, `namespace`, `ingress.host`, `postgresql` connection metadata, and secret names.
- [ ] Create `charts/root-app/templates/airflow.yaml` gated by `{{- if .Values.airflow.enabled }}` and following the repo's ArgoCD Application conventions.
- [ ] Configure the chart source with `repoURL: https://airflow.apache.org`, `chart: airflow`, and `targetRevision` from `.Values.airflow.version`.
- [ ] In Helm values, set `airflowVersion: "3.2.0"`, `postgresql.enabled: false`, and `data.metadataSecretName` to the configured metadata secret.
- [ ] Configure required Airflow secrets with `fernetKeySecretName`, `apiSecretKeySecretName`, and `jwtSecretName`; avoid committing literal keys or passwords.
- [ ] Configure Airflow 3 ingress under `ingress.apiServer.enabled: true` with host `airflow.gsingh.io` and the repo's preferred ingress class if needed.
- [ ] Keep LGTM log shipping simple by relying on existing Promtail pod log scraping; optionally add pod labels/annotations only if needed for filtering in Loki.
- [ ] Add sample secret manifests under `samples/` using placeholder values only, including the exact secret keys expected by the official chart:
  - `samples/airflow-metadata-secret.yaml`: Secret named `airflow-metadata` in namespace `airflow` with `stringData.connection: postgresql+psycopg2://airflow:PASSWORD_HERE@192.168.2.119:5432/airflow`.
  - `samples/airflow-fernet-key-secret.yaml`: Secret named `airflow-fernet-key` with `stringData.fernet-key: FERNET_KEY_HERE`.
  - `samples/airflow-api-secret-key.yaml`: Secret named `airflow-api-secret-key` with `stringData.api-secret-key: API_SECRET_KEY_HERE`.
  - `samples/airflow-jwt-secret.yaml`: Secret named `airflow-jwt-secret` with `stringData.jwt-secret: JWT_SECRET_HERE`.
  - Include comments showing safe local generation commands, but do not include generated values.
- [ ] Ensure the ArgoCD Application includes finalizer, automated prune/selfHeal, and `CreateNamespace=true` sync option.

## Verification

- [ ] Run `helm lint charts/root-app/`.
- [ ] Run `just test-render airflow` and inspect `.test/airflow-rendered.yaml` for the official chart repo, version, namespace, ingress, and secret references.
- [ ] Confirm rendered values do not contain real PostgreSQL passwords, Fernet keys, API secret keys, or JWT secrets.
- [ ] After deployment, confirm Airflow pods start in the `airflow` namespace and migrations complete.
- [ ] Confirm logs appear in Loki/LGTM by querying for Airflow namespace or pod labels.

## Completion Gate

User reviews the rendered Airflow ArgoCD Application and confirms the single phase is complete after secret references, ingress settings, and LGTM log visibility are acceptable.

## Outputs

- Updated root-app values with Airflow enabled/configurable.
- New `charts/root-app/templates/airflow.yaml` ArgoCD Application.
- Placeholder-only sample Airflow secret manifests in `samples/` for metadata DB connection, Fernet key, Airflow 3 API secret key, and JWT secret.
- Validation output from Helm lint and `just test-render airflow`.

## Risks

- Official chart `1.21.0` secret key names must match chart expectations (`connection`, `fernet-key`, `api-secret-key`, `jwt-secret`); incorrect keys can break startup or migrations.
- Airflow 3.x chart ingress uses `apiServer`, so using older `webserver` ingress keys would not expose the UI correctly.
- External PostgreSQL database/user must exist before sync.
- Promtail-based log collection captures pod logs, but Airflow task log persistence/remote logging is a separate concern if historical task logs need durable storage beyond pod output.

## Questions for User

- None.
