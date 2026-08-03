# Implementation Plan: Migrate from LGTM to OpenObserve

## Overview

Consolidate observability onto OpenObserve as the single stack and UI, decommissioning the entire LGTM stack including Grafana. All signals (logs, metrics, traces) flow to OpenObserve only. Hard cut-over on historical data — pre-migration Loki/Mimir/Tempo data is accepted as lost.

## Global Context

- OpenObserve is already deployed and ingesting logs + metrics (dual-shipping via Alloy, see `plans/openobserve-deploy.md`).
- Current LGTM consumers (verified): fission traces → Tempo (OTLP gRPC 4317), promtail → Loki gateway, Alloy → Mimir (`lgtm-mimir-nginx`). Nothing else references LGTM.
- No PrometheusRules exist in the cluster — no alerts to migrate.
- No provisioned Grafana dashboards in the LGTM chart.
- OpenObserve ingestion requires Basic auth; fission's OTLP exporter has no header support — traces route **via Alloy** as an OTLP relay (Alloy adds the auth).
- Grafana ships inside the lgtm chart — disabling `lgtm` removes it automatically; nothing to extract.

## Architecture Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Trace path | fission → Alloy OTLP receiver → OpenObserve | OO requires auth on ingest; Alloy relay adds it without touching fission's limited OTel config |
| Grafana | Remove with LGTM | OpenObserve UI is the sole pane of glass; no provisioned dashboards to port |
| Historical LGTM data | Hard cut-over | Not portable to OO; user-approved |
| Decommission method | `lgtm.enabled: false` → finalizer cascade | Matches repo pattern; single change removes ~20 pods |

## Assumptions

- OpenObserve OTLP endpoint accepts traces at `/api/default/v1/traces` (OTLP HTTP) via Alloy's otlphttp exporter.
- Alloy `otelcol.receiver.otlp` (gRPC 4317) is GA stability — no stability-level change needed.
- Loki gateway ingress (`loki-gateway.gsingh.io`) already disabled in values — no ingress cleanup needed.

## Phase Strategy

Four sequential phases, commit-as-we-go (`just push`). Each phase has its own verification gate; LGTM keeps running untouched until Phase 4, so every phase is independently rollback-safe (revert one values change).

## Phases

### Phase 1 — Traces: fission → Alloy → OpenObserve

- **Objective**: Fission traces arrive in OpenObserve; Tempo stops receiving.
- **Status**: Complete
- **Complexity**: Low
- **Estimated Time**: 30–45 min
- **Prerequisites**: none

#### Context for this Phase

Add an OTLP gRPC receiver to the Alloy config (listens cluster-internally on 4317), forwarding to the existing `otelcol.exporter.otlphttp.openobserve` — add a `traces_endpoint` there. Then repoint fission's `otlpCollectorEndpoint` from `lgtm-tempo...:4317` to the Alloy service on 4317. Alloy needs a Service exposing 4317 (chart `alloy.extraPorts` + service type already ClusterIP — verify service name).

#### Files

| Path | Purpose |
|---|---|
| `charts/root-app/templates/alloy.yaml` | Add `otelcol.receiver.otlp`, `traces_endpoint`, extraPort 4317 |
| `charts/root-app/values.yaml` | `fission.openTelemetry.otlpCollectorEndpoint` → Alloy svc |

#### Implementation Tasks

- [x] Add to Alloy config: `otelcol.receiver.otlp "traces"` → otlphttp exporter; `traces_endpoint` added
- [x] Expose 4317 on Alloy service via `extraPorts` (svc `alloy`)
- [x] Update `fission.openTelemetry.otlpCollectorEndpoint` → `alloy.default.svc.cluster.local:4317`
- [x] `helm lint`, `just push` (commit 9bc95d4)
- [x] Verified via Alloy metrics: 31 spans accepted on receiver, 31 sent to OpenObserve, 0 failures
- [x] Traces visible in OpenObserve UI (user-confirmed)

**Incidents resolved during Phase 1**: orphaned duplicate ArgoCD install (`release-name-argocd-*`, broken Redis auth) was terminating every fission sync every ~3min — deleted the whole orphaned set; zombie operation state cleared via status patch; storagesvc rollout RWO multi-attach deadlock resolved by deleting stale pod.

#### Verification

- [x] Trace stream appears in OpenObserve UI (fission spans)
- [x] Tempo distributor logs show no new traffic
- [x] **Completion Gate**: user confirms traces visible in OO

### Phase 2 — Logs: Alloy-only path, retire promtail

- **Objective**: All pod logs reach OpenObserve via Alloy; promtail and Loki ingestion retired.
- **Status**: Complete
- **Complexity**: Low
- **Estimated Time**: 20–30 min
- **Prerequisites**: Phase 1 complete (optional but sequential by design)

#### Context for this Phase

Alloy's filelog receiver already ships every pod's logs to OpenObserve (verified in deploy plan Phase 2). This phase only removes the redundant promtail path. Loki itself stays up until Phase 4.

#### Files

| Path | Purpose |
|---|---|
| `charts/root-app/values.yaml` | `promtail.enabled: false` |

#### Implementation Tasks

- [x] Verify OO log streams are current (Alloy log ingestion requests returning HTTP 200)
- [x] Set `promtail.enabled: false`; `just push`
- [x] Confirm promtail daemonset pruned by ArgoCD

#### Verification

- [x] OO log streams continue receiving (Alloy ingestion requests return HTTP 200)
- [x] Loki distributor/gateway logs quiet (no pushes)
- [x] **Completion Gate**: log flow verified and user approved proceeding

### Phase 3 — Metrics: OpenObserve only

- **Objective**: Alloy remote-writes metrics to OpenObserve only; Mimir receives nothing.
- **Status**: In Progress
- **Complexity**: Low
- **Estimated Time**: 20–30 min
- **Prerequisites**: Phase 2 complete

#### Files

| Path | Purpose |
|---|---|
| `charts/root-app/templates/alloy.yaml` | Remove `prometheus.remote_write.mimir` + its references from forward_to lists |

#### Implementation Tasks

- [x] Delete the mimir remote_write block; drop it from the three `forward_to` lists (node, kubelet, cadvisor scrapes)
- [x] `helm lint`, `just push`

#### Verification

- [ ] OO metrics queries return fresh data (HTTP ingestion verified; UI query pending)
- [x] No remote_write errors in Alloy logs
- [ ] **Completion Gate**: user confirms metrics queryable in OO

### Phase 4 — Decommission LGTM entirely (Grafana included)

- **Objective**: Entire LGTM stack including Grafana removed; OpenObserve is the only observability UI; cluster footprint reduced.
- **Status**: Not Started
- **Complexity**: Low
- **Estimated Time**: 20–30 min
- **Prerequisites**: Phase 3 complete

#### Files

| Path | Purpose |
|---|---|
| `charts/root-app/values.yaml` | `lgtm.enabled: false` |

#### Implementation Tasks

- [ ] (Optional) Recreate any ad-hoc Grafana dashboards as OpenObserve dashboards before deletion
- [ ] Set `lgtm.enabled: false`; `just push`
- [ ] Watch cascade deletion (ArgoCD finalizer removes Application → Helm uninstall removes Grafana + ~20 LGTM pods, PVCs, services)
- [ ] Verify no orphaned LGTM resources remain (`kubectl get all -n default | grep lgtm`)
- [ ] Optional cleanup: delete `loki-s3` bucket and `grafana-admin-credentials` secret once comfortable (hard cut-over approved)
- [ ] Optional cleanup: remove dead `k8sMonitoring` section from `values.yaml`

#### Execution Tracking Rules

- Status starts at `Not Started`; set `In Progress` when execution begins.
- Check off tasks as completed; strike through skipped/superseded tasks.
- Phase is `Complete` only after user review and explicit confirmation.

#### Verification

- [ ] No `lgtm-*` or Grafana pods, services, or PVCs remain
- [ ] `grafana.gsingh.io` ingress gone
- [ ] OpenObserve unaffected (still ingesting logs/metrics/traces)
- [ ] **Completion Gate**: user confirms cluster clean and OpenObserve covers all needs

## Phase Dependencies

1 → 2 → 3 → 4, strictly sequential. Each phase is independently rollback-safe (single values revert) because LGTM stays fully running until Phase 4.

## Risks

- **Alloy trace relay load**: fission trace volume is low (0.1 sampling already) — negligible.
- **Alloy Service for 4317**: chart creates a service; if port plumbing fails, fallback is a NodePort or dedicated small deployment — diagnose during Phase 1.
- **Grafana loss**: no provisioned dashboards exist, so only ad-hoc UI dashboards are lost; recreate them in OpenObserve if needed.
- **Cascade deletion surprises**: finalizer-based deletion is well-tested in this repo (same pattern used for every app); watch the first 5 minutes after disabling.
- **Data loss**: hard cut-over approved — no rollback of historical Loki/Mimir/Tempo data after Phase 4.

## Questions for User

None.
