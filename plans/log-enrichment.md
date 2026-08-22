# Simple Implementation Plan: Enrich OpenObserve Kubernetes Logs

## Overview

Enrich new Kubernetes pod logs in Alloy with curated Kubernetes and Argo CD ownership metadata before exporting them to OpenObserve. Enable exact filtering by Argo CD Application, workload, node, image, namespace, and standard application labels without copying arbitrary labels.

## Relevant Context

- `charts/root-app/templates/alloy.yaml` currently derives only namespace, pod, and container from log-file paths.
- The parser already captures pod UID but does not promote it to `k8s.pod.uid`.
- Alloy chart `1.8.2` runs Alloy `v1.16.1`.
- The chart's default RBAC already includes pod, namespace, node, and ReplicaSet read/watch permissions needed by `otelcol.processor.k8sattributes`.
- Argo CD uses its default tracking configuration; runtime inspection must confirm whether `app.kubernetes.io/instance` matches the Application name.
- OpenObserve automatically discovers OTLP fields; secondary indexes are optional optimizations.

## Assumptions

- Representative pods expose `app.kubernetes.io/instance` or another targeted label that identifies their Argo CD Application.
- Only newly ingested logs receive the new attributes; historical records are not backfilled.
- System or unmanaged pods may legitimately have no `argocd.application.name`.

## Single-Phase Plan

- **Objective:** Make fresh OpenObserve logs queryable by stable Kubernetes and Argo CD ownership attributes.
- **Status:** Not Started
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

## Implementation Tasks

- [ ] Inspect representative Deployment, StatefulSet, Job, and system pods to establish which label reliably matches their Argo CD Application.
- [ ] Prefer `app.kubernetes.io/instance`; use `argocd.argoproj.io/instance` or targeted pod-template labels only where runtime evidence requires it.
- [ ] Move the UID already parsed from the log path into `resource["k8s.pod.uid"]`.
- [ ] Route filelog output through `otelcol.processor.k8sattributes`.
- [ ] Associate telemetry by `k8s.pod.uid`.
- [ ] Limit each DaemonSet processor to `env("K8S_NODE_NAME")` to avoid every Alloy instance caching the entire cluster's pods.
- [ ] Extract the curated metadata and exact label allowlist above.
- [ ] Route enriched logs to the existing OpenObserve exporter without changing traces or metrics.
- [ ] Expand the Alloy chart and confirm the generated RBAC remains sufficient and least-privilege.
- [ ] Verify the resulting field names in OpenObserve's actual stream schema.
- [ ] Test exact filtering by Argo Application for at least two workload types.
- [ ] Measure representative query latency.
- [ ] Only if filtering is slow, add secondary indexes for low-cardinality fields such as Argo Application, namespace, and application name. Do not initially index pod UID, pod name, or image fields.
- [ ] Optionally enable distinct values for Argo Application and namespace if useful in the OpenObserve UI.

## Verification

- [ ] `helm lint charts/root-app/`
- [ ] `just test-render alloy`
- [ ] `just expand-app alloy`
- [ ] Validate the rendered Alloy configuration using Alloy `v1.16.1` with public-preview components enabled.
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

- Helm and Argo CD can both use `app.kubernetes.io/instance`; runtime verification is required before treating it as ownership.
- Operator-generated pods may not inherit Argo tracking labels and may need targeted workload labels.
- OpenObserve may flatten OTLP attribute names; queries must use the observed schema names.
- Metadata enrichment adds Kubernetes API watches, mitigated by filtering each Alloy instance to its node.
- Current Alloy documentation may differ from pinned `v1.16.1`; validate against the deployed version.

## Questions for User

None.
