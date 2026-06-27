# Implementation Plan: Replace Deprecated LGTM Distributed Chart

## Overview

Replace the deprecated `grafana/lgtm-distributed` umbrella chart with separately managed Grafana observability components. The recommended path is to split the stack into maintained charts first, preserve service continuity during migration, and evaluate larger architecture changes such as Tempo Operator after the stack is stable.

Target components:

- Grafana: `grafana/grafana`
- Loki: `grafana/loki`
- Mimir: `grafana/mimir-distributed`
- Tempo: `tempo-distributed` initially, with Tempo Operator as a later evaluation
- Telemetry collection: `grafana/k8s-monitoring` / Alloy, with Promtail retired later if no longer needed

## Global Context

Current repository state:

- `charts/root-app/templates/lgtm.yaml` deploys one ArgoCD Application using `chart: lgtm-distributed`.
- `charts/root-app/values.yaml` sets `lgtm.version: 3.0.1`.
- `promtail` currently pushes to `http://lgtm-loki-gateway.default.svc.cluster.local:80/loki/api/v1/push`.
- `k8sMonitoring` exists but is disabled and points to LGTM service endpoints.
- Fission sends traces to `lgtm-tempo.default.svc.cluster.local:4317`.
- The current LGTM chart config enables Grafana, Loki, Mimir, and Tempo from one umbrella chart.

Official guidance relevant to this migration:

- `lgtm-distributed` is deprecated.
- Loki should migrate from the old `loki-distributed` chart to the maintained `loki` chart using Grafana's documented side-by-side migration approach.
- Mimir remains available through `mimir-distributed`.
- Tempo has Helm chart and operator deployment paths; for this migration, keep the initial change smaller by using a separate Tempo chart first.

## Architecture Decisions

1. Split the umbrella chart into independent ArgoCD Applications.
2. Keep the existing LGTM deployment active while new components are introduced.
3. Migrate Loki first because it has the highest data-loss risk.
4. Use compatible service endpoints and DNS names during migration to avoid broad downstream changes.
5. Keep `grafana.gsingh.io` as the Grafana user-facing ingress host.
6. Move telemetry clients only after each target backend is verified.
7. Defer Tempo Operator evaluation until after the deprecated umbrella chart is removed.

## Assumptions

- Low/no telemetry loss is preferred over speed.
- The first migration can stay in the `default` namespace unless a later phase explicitly chooses otherwise.
- Existing Kubernetes secrets are already present in the target namespace and should be reused where possible.
- Sensitive values must not be read from local files or Kubernetes secrets during implementation.
- Grafana dashboards and datasources may need backup or reprovisioning if they are not already managed as code.

## Phase Strategy

The migration should be performed in phases with a working checkpoint after each phase. Do not disable or remove the old LGTM app until all clients have moved and the split components are verified.

## Phases

### Phase 1: Inventory and Safety Checks

- Status: Not Started
- Complexity: Medium
- Estimated Time: 45-90 minutes

#### Objective

Capture current deployed state and identify exact service/resource names before introducing replacement components.

#### Prerequisites

- Access to render Helm templates locally.
- Read-only cluster access for non-sensitive resource metadata.
- Existing LGTM deployment healthy enough to query logs, metrics, and traces.

#### Files

| File | Purpose |
| --- | --- |
| `charts/root-app/templates/lgtm.yaml` | Current deprecated umbrella chart definition |
| `charts/root-app/values.yaml` | Current LGTM, Promtail, k8s-monitoring, and Fission endpoint values |
| `justfile` | Existing render/test commands |

#### Implementation Tasks

- [ ] Render current LGTM app with `just test-render lgtm`.
- [ ] Record current non-sensitive Kubernetes resource names for LGTM services, StatefulSets, Deployments, PVCs, and ingresses.
- [ ] Identify the current Loki memberlist service name used by the bundled `loki-distributed` deployment.
- [ ] Confirm current endpoints for Loki gateway, Mimir, Tempo OTLP gRPC/HTTP, and Grafana.
- [ ] Back up Grafana dashboards and datasource definitions if they are stored in-cluster.
- [ ] Confirm whether Loki, Mimir, and Tempo use durable object storage or ephemeral storage.

#### Verification

- Existing Grafana can query current Loki, Mimir, and Tempo.
- Current LGTM ArgoCD Application is healthy before migration begins.
- Resource names needed for side-by-side migration are documented.

#### Completion Gate

User confirms inventory is complete and it is safe to add replacement chart templates.

#### Outputs

- Current endpoint/resource inventory.
- Confirmed migration constraints for storage, namespace, and ingress.

### Phase 2: Add Split Component Templates Disabled by Default

- Status: Not Started
- Complexity: Medium
- Estimated Time: 60-90 minutes

#### Objective

Introduce independent ArgoCD Application templates and values for Grafana, Loki, Mimir, and Tempo without cutting traffic over.

#### Prerequisites

- Phase 1 complete.
- Target chart versions selected from the Grafana Helm repository.

#### Files

| File | Purpose |
| --- | --- |
| `charts/root-app/templates/grafana.yaml` | New Grafana Application |
| `charts/root-app/templates/loki.yaml` | New Loki Application |
| `charts/root-app/templates/mimir.yaml` | New Mimir Application |
| `charts/root-app/templates/tempo.yaml` | New Tempo Application |
| `charts/root-app/values.yaml` | New component values and versions |
| `AGENTS.md` | Update only if repository workflows or app list materially change |

#### Implementation Tasks

- [ ] Add separate values sections for `grafana`, `loki`, `mimir`, and `tempo`.
- [ ] Keep `lgtm.enabled: true` during this phase.
- [ ] Create new templates that follow existing ArgoCD Application conventions.
- [ ] Use temporary names/endpoints where needed to avoid service collisions with `lgtm-*` resources.
- [ ] Include `prune: true` in new Application sync policies to match repository standards.
- [ ] Render each new template individually.

#### Verification

- `helm template root-app charts/root-app --values charts/root-app/values.yaml` succeeds.
- Each new template renders cleanly with `just test-render <template>` after recipes or template names are available.
- The old LGTM Application remains enabled and unchanged.

#### Completion Gate

User reviews the rendered split Applications and confirms they can be synced side-by-side.

#### Outputs

- Disabled or non-cutover split chart definitions committed to the repo.

### Phase 3: Loki Migration

- Status: Not Started
- Complexity: High
- Estimated Time: 1-3 hours plus observation time

#### Objective

Move logs from the bundled `loki-distributed` deployment to the maintained `grafana/loki` chart without data loss.

#### Prerequisites

- Phase 2 complete.
- Old Loki memberlist service name confirmed.
- Loki S3/storage settings confirmed.

#### Files

| File | Purpose |
| --- | --- |
| `charts/root-app/templates/loki.yaml` | New Loki chart Application |
| `charts/root-app/templates/promtail.yaml` | Existing log client endpoint |
| `charts/root-app/templates/k8s-monitoring.yaml` | Future log collection endpoint |
| `charts/root-app/values.yaml` | Loki migration and client endpoint values |

#### Implementation Tasks

- [ ] Deploy the new `grafana/loki` chart alongside the current LGTM Loki.
- [ ] Configure it with the same storage bucket/backend as the old Loki deployment where required.
- [ ] Set `migrate.fromDistributed.enabled: true` and point `memberlistService` to the old Loki memberlist service.
- [ ] Exclude new Loki component logs from old log scraping to avoid duplicates.
- [ ] Add a temporary Grafana datasource for the new Loki endpoint.
- [ ] Verify old logs are queryable through the new Loki endpoint.
- [ ] Switch Promtail or Alloy/k8s-monitoring clients to the new Loki push endpoint.
- [ ] Enable flush-on-shutdown on old Loki ingesters before scale-down.
- [ ] Scale old Loki ingesters down one at a time.
- [ ] Remove the Loki migration join settings only after old Loki is removed.

#### Verification

- Historical logs query successfully from new Loki.
- New logs arrive at the new Loki endpoint.
- No meaningful Loki canary missing entries or ingestion errors appear during the cutover.
- No clients still write to `lgtm-loki-gateway`.

#### Completion Gate

User confirms log ingestion and querying are stable from the new Loki deployment.

#### Outputs

- Logs migrated to maintained `grafana/loki` chart.
- Old bundled Loki no longer receives traffic.

### Phase 4: Mimir Metrics Migration

- Status: Not Started
- Complexity: Medium
- Estimated Time: 60-120 minutes plus observation time

#### Objective

Move metrics ingestion and querying from bundled Mimir to a separately managed `mimir-distributed` Application.

#### Prerequisites

- Phase 2 complete.
- Decision made on whether historical Mimir data must be preserved.
- Remote write clients identified.

#### Files

| File | Purpose |
| --- | --- |
| `charts/root-app/templates/mimir.yaml` | New Mimir Application |
| `charts/root-app/templates/k8s-monitoring.yaml` | Metrics write target |
| `charts/root-app/values.yaml` | Mimir and metrics endpoint values |

#### Implementation Tasks

- [ ] Deploy `grafana/mimir-distributed` separately.
- [ ] Configure storage based on the Phase 1 durability findings.
- [ ] Add or update Grafana datasource for new Mimir.
- [ ] Point k8s-monitoring/Alloy remote write to the new Mimir endpoint.
- [ ] Confirm old Mimir no longer receives new writes.

#### Verification

- New Kubernetes metrics appear in Grafana.
- Existing dashboards populate from the new Mimir datasource.
- Remote write clients report success.

#### Completion Gate

User confirms metrics are stable from the new Mimir deployment.

#### Outputs

- Metrics migrated to separately managed Mimir.

### Phase 5: Tempo Traces Migration

- Status: Not Started
- Complexity: Medium
- Estimated Time: 60-120 minutes plus observation time

#### Objective

Move traces from bundled Tempo to a separately managed Tempo deployment.

#### Prerequisites

- Phase 2 complete.
- Target Tempo chart and endpoint names selected.
- Known trace producers identified.

#### Files

| File | Purpose |
| --- | --- |
| `charts/root-app/templates/tempo.yaml` | New Tempo Application |
| `charts/root-app/templates/k8s-monitoring.yaml` | Trace endpoint values |
| `charts/root-app/values.yaml` | Tempo and producer endpoint values |

#### Implementation Tasks

- [ ] Deploy a separate Tempo backend.
- [ ] Configure storage based on whether trace retention needs durable storage.
- [ ] Add or update Grafana datasource for new Tempo.
- [ ] Update Fission OTLP endpoint from `lgtm-tempo.default.svc.cluster.local:4317` to the new endpoint.
- [ ] Update k8s-monitoring trace endpoint if enabled.
- [ ] Check for any remaining references to `lgtm-tempo`.

#### Verification

- New traces arrive from Fission or another known producer.
- Grafana Tempo datasource is healthy.
- Repository search shows no active `lgtm-tempo` endpoint references except migration notes, if any.

#### Completion Gate

User confirms traces are stable from the new Tempo deployment.

#### Outputs

- Traces migrated to a separately managed Tempo deployment.

### Phase 6: Grafana Migration

- Status: Not Started
- Complexity: Medium
- Estimated Time: 60-120 minutes

#### Objective

Move the user-facing Grafana instance out of the deprecated umbrella chart while preserving access and datasources.

#### Prerequisites

- Loki, Mimir, and Tempo target endpoints are available.
- Grafana dashboard/datasource backup or provisioning plan exists.

#### Files

| File | Purpose |
| --- | --- |
| `charts/root-app/templates/grafana.yaml` | New Grafana Application |
| `charts/root-app/values.yaml` | Grafana ingress, admin secret, datasource values |

#### Implementation Tasks

- [ ] Deploy `grafana/grafana` separately.
- [ ] Reuse the existing Grafana admin secret keys.
- [ ] Preserve ingress host `grafana.gsingh.io`.
- [ ] Provision datasources for new Loki, Mimir, and Tempo.
- [ ] Restore or provision dashboards if needed.
- [ ] Cut ingress from old Grafana to new Grafana.

#### Verification

- Login works with the expected admin credentials.
- Grafana datasources for Loki, Mimir, and Tempo are healthy.
- Representative dashboards load and query the new backends.

#### Completion Gate

User confirms Grafana is usable and points only at the split backends.

#### Outputs

- Grafana independent from deprecated LGTM umbrella chart.

### Phase 7: Collector Cleanup and k8s-monitoring Adoption

- Status: Not Started
- Complexity: Medium
- Estimated Time: 60-120 minutes

#### Objective

Consolidate telemetry collection around k8s-monitoring/Alloy and remove duplicate or deprecated collection paths.

#### Prerequisites

- New Loki, Mimir, and Tempo endpoints are stable.
- Decision made on whether standalone Promtail remains necessary.

#### Files

| File | Purpose |
| --- | --- |
| `charts/root-app/templates/k8s-monitoring.yaml` | Kubernetes telemetry collection |
| `charts/root-app/templates/promtail.yaml` | Legacy log collection |
| `charts/root-app/templates/alloy.yaml` | Standalone Alloy chart |
| `charts/root-app/values.yaml` | Collector feature flags and endpoints |

#### Implementation Tasks

- [ ] Update `k8sMonitoring.endpoints` to point to the new split backends.
- [ ] Enable k8s-monitoring in a controlled way.
- [ ] Avoid duplicate log collection by disabling overlapping Promtail or Alloy paths when appropriate.
- [ ] Decide whether standalone `alloy` is still needed once k8s-monitoring deploys Alloy components.
- [ ] Remove stale `lgtm-*` endpoint values.

#### Verification

- No duplicate logs are observed.
- Metrics, logs, and traces continue flowing.
- No active telemetry clients point to `lgtm-*` services.

#### Completion Gate

User confirms telemetry collection is stable and duplicate collection has been avoided.

#### Outputs

- Cleaner telemetry collection architecture.
- Promtail and standalone Alloy status explicitly decided.

### Phase 8: Remove Deprecated LGTM Application

- Status: Not Started
- Complexity: Medium
- Estimated Time: 45-90 minutes plus observation time

#### Objective

Remove the deprecated umbrella chart after all traffic and dashboards have migrated.

#### Prerequisites

- Phases 3-7 complete.
- No clients or dashboards depend on `lgtm-*` services.
- User approval to delete old LGTM resources.

#### Files

| File | Purpose |
| --- | --- |
| `charts/root-app/templates/lgtm.yaml` | Deprecated Application to disable/remove |
| `charts/root-app/values.yaml` | Remove or disable old `lgtm` values |
| `AGENTS.md` | Update app list/workflow if it becomes stale |

#### Implementation Tasks

- [ ] Set `lgtm.enabled: false` for one controlled sync.
- [ ] Confirm ArgoCD deletion/pruning behavior is intended.
- [ ] Observe the cluster after old resources are removed.
- [ ] Remove stale `lgtm` values and template after one stable deployment cycle, if desired.
- [ ] Update `AGENTS.md` only if repository guidance is now stale.

#### Verification

- ArgoCD shows split Applications healthy.
- No workloads depend on `lgtm-*` services.
- `helm lint charts/root-app/` succeeds.
- `helm template root-app charts/root-app --values charts/root-app/values.yaml` succeeds.

#### Completion Gate

User confirms the deprecated LGTM Application is fully retired.

#### Outputs

- Deprecated `lgtm-distributed` chart removed from active deployment.
- Repository reflects the split observability stack.

## Phase Dependencies

```text
Phase 1 -> Phase 2
Phase 2 -> Phase 3, Phase 4, Phase 5, Phase 6
Phase 3 -> Phase 7
Phase 4 -> Phase 7
Phase 5 -> Phase 7
Phase 6 -> Phase 8
Phase 7 -> Phase 8
```

Loki should be handled before collector cleanup because logs have the highest migration-specific data-loss risk.

## Risks

- Loki data loss if old ingesters are removed before flushing and new Loki is verified.
- Duplicate logs if Promtail and k8s-monitoring collect the same pod logs at the same time.
- Grafana dashboards may break if datasource UIDs change.
- Service name changes can break producers such as Fission if endpoints are missed.
- Mimir or Tempo historical data may not be preserved if current storage is ephemeral.
- ArgoCD pruning could delete old resources earlier than intended if cutover flags are changed too aggressively.

## Questions for User

- Is preserving historical Mimir and Tempo data required, or is preserving new ingestion enough?
- Should the split components remain in `default`, or should a dedicated observability namespace be introduced after migration?
- Should Grafana dashboards/datasources be moved fully into code as part of this migration, or handled separately?
- After the split migration is complete, should Tempo Operator be evaluated as a follow-up project?
