# Implementation Plan: Add DataHub to Root App

## Overview

Add DataHub as a data catalog solution that integrates with the existing Trino and Polaris data warehouse stack. DataHub will provide metadata discovery, lineage tracking, and data governance for data pipelines using dbt, SQLMesh, Prefect, and other tools.

## Global Context

### Architecture
- **DataHub** (Helm chart `0.9.1`, app version `v1.5.0`) - Metadata catalog platform
- **Trino** - Already deployed in `data-platform` namespace with Iceberg/Polaris
- **Polaris** - Already deployed in `data-platform` namespace
- **External PostgreSQL** - Available at `192.168.2.119:5432` (same as other apps)

### Key Integration Points
- **Trino**: DataHub can ingest metadata from Trino catalogs
- **Polaris**: DataHub can track Iceberg table metadata
- **Prefect/Dagster**: DataHub supports workflow ingestion
- **dbt/SQLMesh**: DataHub has native dbt integration for lineage

### DataHub Prerequisites
| Service | Decision | Notes |
|---------|----------|-------|
| **Kafka** | Use Redpanda | Kafka-compatible, deploy as separate ArgoCD app |
| **OpenSearch** | `datahub-prerequisites` chart | Deploy as a separate ArgoCD app before DataHub; the main `datahub` chart does NOT bundle a search subchart |
| **PostgreSQL** | External existing | `192.168.2.119:5432` (same as other apps) |
| **Graph Service** | Elasticsearch/OpenSearch | Configured via `global.graph_service_impl: elasticsearch` |

> **Important**: The `datahub` Helm chart does not include an embedded Elasticsearch/OpenSearch subchart. Search must be pre-provisioned via the separate `datahub/datahub-prerequisites` chart (or an external instance). `global.elasticsearch.*` keys tell DataHub *where* to connect, not whether to deploy one.

## Phase Versioning Strategy

**Decide Per Phase During Implementation** - Each phase includes a git choice point so the implementer can pick worktree, feature branch, or tag at execution time.

---

## Phases

### Phase 1: Add Redpanda (Kafka Alternative)

**Objective**: Deploy Redpanda as a Kafka-compatible message broker for DataHub's metadata events.

**Complexity**: Medium  
**Estimated Time**: 30 min

**Prerequisites**:
- None (first phase)

**Context for this Phase**:
- Redpanda chart repo: `https://charts.redpanda.com/`
- Redpanda is Kafka-compatible and works with DataHub out of the box
- Redpanda should run in `data-platform` namespace alongside DataHub
- Authentication can be disabled for internal cluster communication
- Use minimal configuration for development/small workloads
- **Note**: Redpanda does not need external ingress - DataHub accesses it via internal Kubernetes service at `redpanda.data-platform.svc.cluster.local:9092`

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Add `redpanda` section |
| `charts/root-app/templates/redpanda.yaml` | create | ArgoCD Application CRD for Redpanda |

**Implementation Steps**:
1. Add Redpanda values entry to `values.yaml`:
   ```yaml
   redpanda:
     enabled: true
     version: "<latest-stable>"
     namespace: data-platform
     # External PostgreSQL for Redpanda's schema (optional - can use embedded)
     # For minimal setup, use built-in PostgreSQL
   ```
2. Create `templates/redpanda.yaml` with:
   - ArgoCD Application CRD pointing to `https://charts.redpanda.com/` chart `redpanda`
   - `CreateNamespace=true` sync option
   - Automated sync with prune and selfHeal
   - Minimal Redpanda config (single broker, disable auth for internal)

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] `helm template root-app charts/root-app/ --values charts/root-app/values.yaml | grep -A50 "redpanda"` shows Redpanda resources

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done.

**Outputs**:
- Redpanda deployed and accessible at `redpanda.data-platform.svc.cluster.local:9092`
- Schema Registry accessible at `redpanda.data-platform.svc.cluster.local:8081` (available if external schema registry is needed, but DataHub defaults to its own `INTERNAL` schema registry so this is not required unless overriding)

---

### Phase 2: Add DataHub Prerequisites (OpenSearch)

**Objective**: Deploy the `datahub-prerequisites` chart to provision OpenSearch (the required search/graph backend). Kafka is provided by Redpanda (Phase 1) so it is disabled here.

**Complexity**: Low  
**Estimated Time**: 20 min

**Prerequisites**:
- Phase 1 complete (Redpanda deployed)

**Context for this Phase**:
- The `datahub/datahub-prerequisites` chart is at `https://helm.datahubproject.io/`, chart name `datahub-prerequisites`
- It must be deployed **before** the main `datahub` chart — ArgoCD sync waves or explicit ordering is required
- Disable Kafka and MySQL/PostgreSQL in prerequisites (we supply those externally); enable only OpenSearch:
  ```yaml
  kafka:
    enabled: false
  mysql:
    enabled: false
  postgresql:
    enabled: false
  neo4j:
    enabled: false
  opensearch:
    enabled: true
    singleNode: true
    config:
      opensearch.yml: |
        plugins:
          security:
            disabled: true
  ```
- OpenSearch will be available at `opensearch-cluster-master.data-platform.svc.cluster.local:9200` (default release name `prerequisites`)
- Add `argocd.argoproj.io/sync-wave: "-1"` annotation to the prerequisites Application so it deploys before DataHub

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Add `datahub-prerequisites` section |
| `charts/root-app/templates/datahub-prerequisites.yaml` | create | ArgoCD Application CRD for prerequisites |

**Implementation Steps**:
1. Add `datahubPrerequisites:` section to `values.yaml`
2. Create `templates/datahub-prerequisites.yaml` following the standard ArgoCD Application pattern with:
   - `argocd.argoproj.io/sync-wave: "-1"` annotation to ensure it deploys before DataHub
   - `CreateNamespace=true` sync option
   - OpenSearch enabled, Kafka/MySQL/PostgreSQL/Neo4j disabled

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] `just test-render datahub-prerequisites` produces valid ArgoCD Application
- [ ] Prerequisites Application appears before DataHub Application in rendered output

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done.

**Outputs**:
- OpenSearch deployed at `opensearch-cluster-master.data-platform.svc.cluster.local:9200`

---

### Phase 3: Add DataHub Values Configuration

**Objective**: Add DataHub configuration to root-app values.yaml.

**Complexity**: Low  
**Estimated Time**: 20 min

**Prerequisites**:
- Phase 1 complete (Redpanda deployed)
- Phase 2 complete (OpenSearch deployed via prerequisites)

**Context for this Phase**:
- DataHub chart repo: `https://helm.datahubproject.io/` chart `datahub`
- Key configuration sections:
  - `global.datahub.version` - DataHub app version (e.g. `v1.5.0`)
  - `global.elasticsearch.host` / `global.elasticsearch.port` - Point to the OpenSearch instance deployed by `datahub-prerequisites` (default host: `opensearch-cluster-master`, port: `9200`)
  - `global.graph_service_impl: elasticsearch` - Use OpenSearch/ES as graph backend (not Neo4j)
  - `global.kafka.bootstrap.server` - Point to Redpanda
  - `global.kafka.schemaregistry.type: INTERNAL` - DataHub manages its own schema registry by default; no external SR needed
  - `global.sql.datasource` - External PostgreSQL at 192.168.2.119 (full key structure documented in Implementation Steps below)
  - `datahub-gms` - General Metadata Service
  - `datahub-frontend` - Web UI with ingress
  - `acryl-datahub-actions` - For event-based ingestion
- PostgreSQL credentials secret needed (reuse pattern from other apps)
- Auto-generate auth secrets since no existing DataHub secrets
- **Do NOT set `global.elasticsearch.enabled`** — that key does not exist in the DataHub chart; Elasticsearch/OpenSearch is a prerequisite, not a subchart of `datahub`

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Add `datahub` section with all config |

**Implementation Steps**:
1. Add `datahub:` section to `values.yaml` with:
   - `enabled: true`
   - `version: "0.9.1"` (DataHub Helm chart version; latest as of 2026-03-25)
   - `namespace: data-platform`
   - `ingress.host: datahub.gsingh.io`
   - `global.datahub.version: "v1.5.0"` (DataHub app version — must match chart appVersion)
   - `global.elasticsearch.host: "opensearch-cluster-master"` and `global.elasticsearch.port: "9200"` (point to prerequisites OpenSearch)
   - `global.graph_service_impl: elasticsearch`
   - `global.kafka.bootstrap.server: "redpanda.data-platform.svc.cluster.local:9092"`
   - `global.kafka.schemaregistry.type: INTERNAL` (DataHub manages its own internal schema registry; leave as default — do **not** point to Redpanda's schema registry port unless you specifically want external Confluent-compatible SR)
   - `global.sql.datasource` with the full set of required keys (see structure below)
   - Enable `datahub-gms`, `datahub-frontend`, `acryl-datahub-actions`
   - Enable secret auto-generation for auth (`global.datahub.metadata_service_authentication.provisionSecrets.autoGenerate: true`)

**PostgreSQL Secret Structure** (`datahub-postgres-credentials` or similar):
The DataHub chart requires these keys under `global.sql.datasource` — the `polaris`-style single `jdbcUrl` key does **not** apply here:
```yaml
global.sql.datasource:
  host: "192.168.2.119"
  hostForpostgresqlClient: "192.168.2.119"
  port: "5432"
  url: "jdbc:postgresql://192.168.2.119:5432/datahub"
  driver: "org.postgresql.Driver"
  database: "datahub"
  username: "datahub"          # or reference via secretRef
  password:
    secretRef: datahub-postgres-credentials
    secretKey: postgres-password
```
- Create the secret `datahub-postgres-credentials` with key `postgres-password` before deploying
- The `datahub` database must exist in PostgreSQL before deployment; the `postgresqlSetupJob` (enabled via `datahubSystemUpdate.sql.setup.enabled: true`) will create tables but expects the DB to exist
- Optionally set `DATAHUB_DB_NAME` via `postgresqlSetupJob.extraEnvs` if using a non-default database name

**Verification**:
- [ ] Values schema is valid (can validate with `helm schema validate` if available)
- [ ] All required DataHub keys present in values.yaml

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done.

**Outputs**:
- Complete DataHub configuration in values.yaml ready for template creation

---

### Phase 4: Create DataHub ArgoCD Template

**Objective**: Create the ArgoCD Application CRD template for DataHub.

**Complexity**: Medium  
**Estimated Time**: 45 min

**Prerequisites**:
- Phase 3 complete (values configured)

**Context for this Phase**:
- Template pattern follows existing templates like `polaris.yaml` and `trino.yaml`
- Must use conditional rendering `{{- if .Values.datahub.enabled }}`
- Helm values must map correctly from `.Values.datahub.*`
- Key sections to template:
  - Global config (ES, Kafka, SQL)
  - GMS service configuration
  - Frontend with ingress
  - Actions component
  - Secret references (use existingSecret pattern)

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/templates/datahub.yaml` | create | ArgoCD Application CRD for DataHub |

**Implementation Steps**:
1. Create `templates/datahub.yaml` following the polaris.yaml pattern
2. Map all values from `.Values.datahub.*` to helm chart values:
   - `global.elasticsearch.host`/`port` pointing to the prerequisites OpenSearch instance
   - Kafka/Redpanda bootstrap server
   - PostgreSQL datasource with secretRef
   - GMS image and resources
   - Frontend with ingress (host: datahub.gsingh.io, className: traefik)
   - Actions component
   - Auth secret auto-generation
3. Include standard syncPolicy with finalizers

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] `just test-render datahub` produces valid output
- [ ] Template renders ArgoCD Application with correct spec

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done.

**Outputs**:
- Working `templates/datahub.yaml` that deploys DataHub

---

### Phase 5: Configure Trino Ingestion Source

**Objective**: Configure DataHub to ingest metadata from Trino.

**Complexity**: Low  
**Estimated Time**: 20 min

**Prerequisites**:
- Phase 4 complete (DataHub template works)

**Context for this Phase**:
- DataHub can use a Trino source for metadata ingestion via the `datahub-ingestion` CLI
- **Primary approach**: Configure ingestion via the DataHub UI (Settings → Ingestion → New Source → Trino). This avoids managing recipe YAML in Helm values and is easier to iterate on.
- **Alternative approach**: Use the `datahub-ingestion-cron` subchart. This subchart takes a `recipes` list where each entry is a full DataHub ingestion recipe. The recipe structure is NOT a custom `datahub.ingestion.trino.*` key — it is a full `datahub-ingestion-cron` subchart config.
- Trino is at `trino.data-platform.svc.cluster.local:8080`
- `global.datahub.managed_ingestion.enabled: true` (already default in chart) enables UI-based ingestion

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/templates/datahub.yaml` | optionally modify | Enable `datahub-ingestion-cron` subchart if using scheduled approach |
| `charts/root-app/values.yaml` | optionally modify | Add ingestion cron recipe if not using UI approach |

**Implementation Steps (recommended: UI approach)**:
1. Ensure `global.datahub.managed_ingestion.enabled: true` is set (this is the chart default)
2. After DataHub is running, navigate to `https://datahub.gsingh.io` → Settings → Ingestion → + New Source → Trino
3. Set connection details:
   - Host: `trino.data-platform.svc.cluster.local`
   - Port: `8080`
   - Catalog: `iceberg`
4. Run and schedule as needed from the UI

**Implementation Steps (alternative: `datahub-ingestion-cron` subchart)**:
If automated ingestion via GitOps is preferred, enable the subchart with a proper recipe structure:
```yaml
# In datahub.yaml ArgoCD Application helm.values:
datahub-ingestion-cron:
  enabled: true
  image:
    repository: acryldata/datahub-ingestion
    tag: "v1.5.0"
  recipes:
    - name: trino-iceberg
      schedule: "0 6 * * *"      # daily at 06:00
      recipe:
        source:
          type: trino
          config:
            host_port: "trino.data-platform.svc.cluster.local:8080"
            database: "iceberg"
        sink:
          type: datahub-rest
          config:
            server: "http://datahub-datahub-gms:8080"
```
Note: The `datahub.ingestion.trino.*` key structure used in the original plan does not exist in the DataHub Helm chart and will be silently ignored.

**Verification**:
- [ ] If using UI approach: DataHub running and Ingestion UI accessible at `https://datahub.gsingh.io/ingestion`
- [ ] If using cron approach: `datahub-ingestion-cron` enabled in rendered template and recipe structure matches DataHub ingestion recipe schema

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done.

**Outputs**:
- DataHub configured to ingest Trino metadata

---

### Phase 6: Verify Full Integration

**Objective**: Verify the complete DataHub deployment renders correctly.

**Complexity**: Low  
**Estimated Time**: 20 min

**Prerequisites**:
- Phase 5 complete

**Context for this Phase**:
- Final verification before user approval
- Run full helm template to ensure all values render
- Verify no syntax errors or missing values

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| None | verify | Verify existing files are correct |

**Implementation Steps**:
1. Run `helm lint charts/root-app/`
2. Run `helm template root-app charts/root-app/ --values charts/root-app/values.yaml | grep -A200 "kind: Application" | grep -E "^# Source:|^apiVersion|^kind|^  name:|datahub"`
3. Verify both `datahub-prerequisites` and `datahub` Applications appear in rendered output, with prerequisites having sync-wave `-1`
4. Test expand script: `just expand-app datahub` (if available)

**Verification**:
- [ ] `helm lint charts/root-app/` passes with no errors
- [ ] `datahub-prerequisites` Application resource appears with `sync-wave: "-1"` annotation
- [ ] `datahub` Application resource appears in rendered template
- [ ] All required DataHub components (gms, frontend, actions) are configured
- [ ] After cluster deploy: check `datahubSystemUpdate` job completed successfully (`kubectl get jobs -n data-platform`)

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done.

**Outputs**:
- Complete, verified DataHub integration

---

## Phase Dependencies

```
Phase 1 (Redpanda)  Phase 2 (Prerequisites/OpenSearch)  Phase 3 (DataHub Values)
        \                        |                               /
         \                       |                              /
          \                      v                             /
           \──────────────► Phase 4 (DataHub Template) ◄─────/
                                 |
                                 v
                     Phase 5 (Trino Ingestion)
                                 |
                                 v
                         Phase 6 (Verify)
```

Phases 1, 2, and 3 have no dependency on each other and can be implemented in parallel. All three must be complete before Phase 4.

## Risks

| Risk | Mitigation |
|------|------------|
| Redpanda version compatibility with DataHub | Use stable Redpanda version, DataHub uses standard Kafka protocol |
| PostgreSQL connection issues | Reuse existing connection pattern from other apps (192.168.2.119) |
| Elasticsearch resource usage | DataHub subchart ES is resource-heavy; monitor and adjust limits |
| Secret management | Use auto-generate feature for initial setup, then migrate to proper secrets |

## Configuration Decisions (User Confirmed)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Redpanda version | Latest stable | As requested |
| Admin credentials | Use default | User will change via UI |
| Ingress class | Traefik (explicit) | User has Traefik deployed |
| Resource limits | Chart defaults | As requested |

**Note on Ingress Class**: If no ingress class is specified, Kubernetes uses the default ingress class. However, explicitly setting `traefik` ensures predictable behavior since the user confirmed Traefik is their ingress controller.
