# Implementation Plan: OpenObserve Deployment with Dual-Shipping

## Overview

Deploy OpenObserve alongside the existing LGTM stack via the ArgoCD app-of-apps pattern, using basic auth from an existing secret, external S3-compatible storage, and external Postgres for metadata. Then add an Alloy instance that ships logs and metrics to OpenObserve while LGTM keeps its existing paths — giving both stacks live data.

## Global Context

- Cluster: k3s (Rancher), Traefik ingress, Longhorn/local-path storage, ~7 nodes with moderate memory headroom.
- Repo pattern: `charts/root-app/` Application CRDs with inline helm values (`lgtm.yaml` is the model); secrets follow `existingSecret` convention; `just push "<message>"` for commits.
- Current ingestion: promtail → Loki gateway; fission → Tempo OTLP. **Alloy and k8s-monitoring are not actually deployed** (enabled in values but absent in-cluster).
- Chart: `openobserve` from `https://charts.openobserve.ai` (repo `openobserve/openobserve-helm-chart`). It's HA-shaped: router/ingester/querier/compactor/alertmanager + NATS (subchart) + Postgres (CNPG subchart, **skipped**) + reportserver + o2ai.
- Auth: `externalSecret.enabled: true` with a secret keyed by env names (`ZO_ROOT_USER_EMAIL`, `ZO_ROOT_USER_PASSWORD`).

## Architecture Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Metadata store | External Postgres `192.168.2.119` via `ZO_META_POSTGRES_DSN`, chart `postgres.enabled: false` | Avoids installing the CNPG operator; same pattern as Authentik |
| Object storage | New bucket `openobserve` on `s3v2.gsingh.io`, dedicated secret `openobserve-s3-credentials` (`ZO_S3_ACCESS_KEY`/`ZO_S3_SECRET_KEY`) | Isolated creds, dedicated bucket |
| Web UI auth | Basic auth (root email/password) via external secret `openobserve-credentials` | Per user decision; OIDC deferred |
| Ingestion | New Alloy instance ships logs+metrics to OpenObserve only; LGTM paths unchanged | True dual-stack data without touching working pipelines; avoids Loki-API incompatibility (OO has no Loki push API — Alloy uses OTLP/Prom-remote-write to OO) |
| Footprint | 10Gi PVCs, `o2ai` disabled, defaults otherwise | Home-cluster sizing; chart defaults are 100Gi×3 |
| Enterprise flag | Keep chart default `enterprise.enabled: true` | Runs fine without a license; can flip to OSS image later if desired |

## Assumptions

- External PG at `192.168.2.119` is reachable from pods; an `openobserve` database/user can be created there.
- `s3v2.gsingh.io` accepts new buckets/credentials created out-of-band (manual step, not in this repo).
- Ingress TLS follows existing pattern (host-only config, Traefik handles certs as with other apps).
- OpenObserve org is `default`.

## Phase Strategy

Two phases, commit-as-we-go (`just push`). Phase 2 depends on Phase 1 completion.

## Phases

### Phase 1 — Deploy OpenObserve core

- **Objective**: OpenObserve running, UI login works with secret-supplied credentials, S3 + Postgres connected.
- **Status**: In Progress
- **Complexity**: Medium
- **Estimated Time**: 60–90 min
- **Prerequisites**: none

#### Context for this Phase

Model the Application CRD on `charts/root-app/templates/lgtm.yaml` (external helm repo, inline values, finalizer, automated sync with selfHeal/prune). Pin the chart version explicitly in `values.yaml`. Credentials live only in in-cluster secrets; the secret for `externalSecret` must use env-var names as keys.

#### Files

| Path | Purpose |
|---|---|
| `charts/root-app/templates/openobserve.yaml` | New ArgoCD Application CRD |
| `charts/root-app/values.yaml` | New `openobserve:` section |
| In-cluster secrets (manual): `openobserve-credentials`, `openobserve-s3-credentials` | Credentials, never committed |

#### Implementation Tasks

- [ ] Create bucket `openobserve` + access credentials on `s3v2.gsingh.io`
- [ ] Create `openobserve` database + user on external PG; note DSN
- [ ] Create secret in `default` namespace: `openobserve-credentials` (keys `ZO_ROOT_USER_EMAIL`, `ZO_ROOT_USER_PASSWORD`, `ZO_META_POSTGRES_DSN`, `ZO_S3_ACCESS_KEY`, `ZO_S3_SECRET_KEY`) — chart mounts one externalSecret, so S3 keys merged into the same secret (plan deviation)
- [x] Add `charts/root-app/templates/openobserve.yaml` — Application CRD per repo standard (finalizer, selfHeal, prune), repoURL `https://charts.openobserve.ai`, chart `openobserve`, pinned chart version `2.0.2`
- [x] Add `openobserve:` values section: `enabled`, `version`, `ingress.host: openobserve.gsingh.io`, secret name, bucket, endpoint
- [x] Inline helm values: `externalSecret.enabled: true` + secret name; `postgres.enabled: false`; `minio.enabled: false`; `nats` PVC 10Gi; persistence sizes 10Gi (ingester/querier/alertmanager); `replicaCount.o2ai: 0`; `ingress.enabled`, `className: traefik`, nginx annotations stripped; `config` overrides: `ZO_S3_PROVIDER: "s3"`, `ZO_S3_SERVER_URL: https://s3v2.gsingh.io`, `ZO_S3_BUCKET_NAME`, region, `ZO_WEB_URL`
- [x] `helm lint charts/root-app/` + test render; `just push`

#### Execution Tracking Rules

- Status starts at `Not Started`; set `In Progress` when execution begins.
- Check off tasks as completed; strike through skipped/superseded tasks.
- Phase is `Complete` only after user review and explicit confirmation.

#### Verification

- [ ] ArgoCD app `Synced`/`Healthy`; all pods Ready
- [ ] Login at `https://openobserve.gsingh.io` with root creds from secret
- [ ] No S3/PG errors in pod logs; S3 bucket receives objects after first ingestion/compaction

#### Completion Gate

User confirms UI login + healthy pods.

#### Outputs

- New Application CRD + values section in `charts/root-app/`
- Working OpenObserve instance with S3 + external Postgres wired

### Phase 2 — Dual-shipping via Alloy (logs + metrics)

- **Objective**: New Alloy instance ships pod logs and cluster metrics to OpenObserve; LGTM ingestion unchanged and verified intact.
- **Status**: Not Started
- **Complexity**: Medium
- **Estimated Time**: 60–90 min
- **Prerequisites**: Phase 1 complete

#### Context for this Phase

The existing `alloy` Application has no inline values, so add helm values there (or confirm deployment state first — it is currently absent in-cluster). OpenObserve accepts OTLP logs at `http://<router-svc>:5080/api/default/v1/logs` and Prometheus-compatible remote write for metrics, both with Basic auth (root user). LGTM endpoints: Loki gateway push URL and Mimir push URL are already used elsewhere in `values.yaml`.

#### Files

| Path | Purpose |
|---|---|
| `charts/root-app/templates/alloy.yaml` | Add inline helm values (currently none) |
| `charts/root-app/values.yaml` | Extend `alloy:` section |
| In-cluster secret: Alloy OpenObserve Basic-auth credentials | Never committed |

#### Implementation Tasks

- [ ] Add Alloy config: pod-log discovery (`local.file_match` + `kubernetes.discovery`) → `loki.process` → `loki.write` to Loki gateway **and** `otlphttp.write` to OpenObserve logs endpoint (Basic auth from secret)
- [ ] Metrics: `prometheus.exporter.unix` (built-in node exporter) + kubelet/cAdvisor scrape → `prometheus.remote_write` to both Mimir (`lgtm-mimir.../api/v1/push`) and OpenObserve's Prometheus-compatible write endpoint
- [ ] Wire credentials via secretKeyRef (Alloy `extraEnv` or env references in config)
- [ ] Conservative resource limits; `helm lint` + render check; `just push`

#### Execution Tracking Rules

- Status starts at `Not Started`; set `In Progress` when execution begins.
- Check off tasks as completed; strike through skipped/superseded tasks.
- Phase is `Complete` only after user review and explicit confirmation.

#### Verification

- [ ] Log stream appears in OpenObserve UI within minutes
- [ ] Metrics queryable in OpenObserve UI
- [ ] Grafana/Loki/Mimir still receiving (existing dashboards/queries work)

#### Completion Gate

User confirms data visible in both stacks.

#### Outputs

- Alloy deployed with dual destinations; OpenObserve receiving logs + metrics; LGTM unaffected

## Phase Dependencies

Phase 2 requires Phase 1's Completion Gate. No parallelism.

## Risks

- **S3 provider quirks**: `s3v2.gsingh.io` may need `ZO_S3_PROVIDER: "minio"` or hosted-style toggling if path-style fails — diagnosed in Phase 1 verification, one-line config fix.
- **Resource pressure**: OpenObserve adds ~7-8 pods; monitor node memory after Phase 1, tune `resources` if needed.
- **Dual ingestion cost**: logs stored in both Loki and OO — expected, revisit when retiring one stack.
- **Chart drift**: pin chart version explicitly in values.

## Questions for User

None.
