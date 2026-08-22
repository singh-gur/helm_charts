# Simple Implementation Plan: Enrich OpenObserve Kubernetes Logs

## Overview

Enrich new Kubernetes pod logs in Alloy with curated Kubernetes and Argo CD ownership metadata before exporting them to OpenObserve. Enable exact filtering by Argo CD Application, workload, node, image, namespace, and standard application labels without copying arbitrary labels.

## Relevant Context

- `charts/root-app/templates/alloy.yaml` currently derives only namespace, pod, and container from log-file paths.
- The parser already captures pod UID but does not promote it to `k8s.pod.uid`.
- Alloy chart `1.8.2` runs Alloy `v1.16.1`.
- The chart's default RBAC already includes pod, namespace, node, and ReplicaSet read/watch permissions needed by `otelcol.processor.k8sattributes`.
- The live Argo CD configuration uses `argocd.argoproj.io/instance` as its tracking label; standard workload owners carry it even when generated pods do not.
- OpenObserve automatically discovers OTLP fields; secondary indexes are optional optimizations.

## Assumptions

- Alloy can resolve Argo ownership from the pod or its Deployment, StatefulSet, DaemonSet, or Job owner.
- Only newly ingested logs receive the new attributes; historical records are not backfilled.
- System or unmanaged pods may legitimately have no `argocd.application.name`.

## Single-Phase Plan

- **Objective:** Make fresh OpenObserve logs queryable by stable Kubernetes and Argo CD ownership attributes.
- **Status:** In Progress
- **Complexity:** Medium
- **Estimated Time:** 45–90 minutes

## Attribute Contract

Preserve existing fields and add:

- `argocd.application.name`
- `k8s.pod.uid`
- `k8s.pod.start_time`
- `k8s.node.name`
- `k8s.deployment.name`
- `k8s.statefulset.name`
- `k8s.daemonset.name`
- `k8s.replicaset.name`
- `k8s.job.name`
- `k8s.cronjob.name`
- `container.image.name`
- `container.image.tag`
- `k8s.app.instance`
- `k8s.app.name`
- `k8s.app.component`
- `k8s.app.part_of`
- `k8s.app.version`

Do not copy all labels or annotations. Skip `k8s.cluster.name` until logs from multiple clusters share the stream.

## Files

| Path | Purpose |
|---|---|
| `charts/root-app/templates/alloy.yaml` | Add UID association and Kubernetes metadata enrichment |
| `charts/root-app/values.yaml` | Confirm pinned Alloy version; no change expected |
| `charts/root-app/values.schema.json` | No change unless new values become necessary |
| `charts/argo-cd/values.yaml` | Confirm tracking configuration; no change expected |
| `charts/root-app/templates/openobserve.yaml` | No change expected |
| `scripts/expand-app.sh` | Correctly preserve inline Helm values when expanding external charts |

## Implementation Tasks

- [x] Inspect representative Deployment, StatefulSet, DaemonSet, Job, generated, and system pods. `argocd.argoproj.io/instance` is the reliable Argo label on pods or their workload owners.
- [x] Map `argocd.argoproj.io/instance` to `argocd.application.name`; retain the Helm label separately as `k8s.app.instance`.
- [x] Move the UID already parsed from the log path into `resource["k8s.pod.uid"]`.
- [x] Route filelog output through `otelcol.processor.k8sattributes`.
- [x] Associate telemetry by `k8s.pod.uid`.
- [x] Limit each DaemonSet processor to `env("K8S_NODE_NAME")` to avoid every Alloy instance caching the entire cluster's pods.
- [x] Extract the curated metadata and exact label allowlist above.
- [x] Route enriched logs to the existing OpenObserve exporter without changing traces or metrics.
- [x] Render the Alloy chart with the configured inline values and confirm RBAC keeps the existing metadata access plus targeted `get`, `list`, and `watch` access for Deployments, StatefulSets, DaemonSets, and Jobs.
- [ ] Verify the resulting field names in OpenObserve's actual stream schema.
- [ ] Test exact filtering by Argo Application for at least two workload types.
- [ ] Measure representative query latency.
- [ ] Only if filtering is slow, add secondary indexes for low-cardinality fields such as Argo Application, namespace, and application name. Do not initially index pod UID, pod name, or image fields.
- [ ] Optionally enable distinct values for Argo Application and namespace if useful in the OpenObserve UI.

## Verification

- [x] `helm lint charts/root-app/`
- [x] `just test-render alloy`
- [x] `just expand-app alloy` correctly applies inline values; the helper was fixed to preserve indented values and blank lines.
- [ ] Validate the rendered Alloy configuration using Alloy `v1.16.1` with public-preview components enabled. Alloy parses the configuration successfully, but standalone validation cannot initialize the Kubernetes-dependent components outside the cluster.
- [ ] Confirm Alloy reports no configuration, RBAC, metadata lookup, dropped-log, or exporter errors.
- [ ] Confirm fresh logs retain existing namespace, pod, and container fields.
- [ ] Query fresh logs by `argocd.application.name` for at least two applications.
- [ ] Confirm unmanaged/system logs remain present with a missing Argo field rather than being dropped.
- [ ] Confirm trace and metric ingestion remains unaffected.

## Completion Gate

User confirms fresh logs are searchable by Argo CD Application and the curated fields are useful in OpenObserve.

## Outputs

- Updated Alloy log-enrichment pipeline.
- Verified OpenObserve field names and example filters.
- Conditional OpenObserve index changes only if measurement justifies them.

## Risks

- Generated pods may not inherit Argo tracking labels; ownership therefore depends on Kubernetes owner lookup for standard workload types.
- Custom operators whose generated pods and supported owners both omit the Argo label will have no `argocd.application.name`.
- OpenObserve may flatten OTLP attribute names; queries must use the observed schema names.
- Metadata enrichment adds Kubernetes API watches, mitigated by filtering each Alloy instance to its node.
- Current Alloy documentation may differ from pinned `v1.16.1`; validate against the deployed version.

## Questions for User

None.
