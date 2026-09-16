# Implementation Plan: Upgrade ArgoCD 7.3.6 → 9.7.1

## Overview

Upgrade the self-managed ArgoCD installation from chart `7.3.6` (Argo CD `v2.11.4`) to chart `9.7.1` (Argo CD `v3.4.4`) in three version hops. A hardening phase runs first to defuse the two failure modes that caused the reverted 2024 and Feb-2025 upgrade attempts, and a dedicated final phase migrates resource tracking from labels to annotations.

Hops: `7.3.6` → **P1** `7.9.1` (v2.14.11) → **P2** `8.6.4` (v3.1.8) → **P3** `9.7.1` (v3.4.4)

Explicitly out of scope: chart `10.x` / Argo CD `v3.5.x`, which bundles Helm 4 and re-renders every child chart. That is a separate project.

## Planning Profile

- Executor: Smart
- Detail: Standard
- Mode: Phased (5 phases)

## Global Context

- ArgoCD self-manages through `charts/root-app/templates/argo-cd.yaml`, which points an Application at `charts/argo-cd` in this repo at `targetRevision: HEAD`.
- Helm release `argo-cd` lives in namespace `default` (not `argocd`). `argocdNamespace: default` in `charts/root-app/values.yaml:1`.
- The Application owns all 3 argoproj CRDs (`crds.install: true`, `helm.sh/resource-policy: keep`).
- Cluster: k3s `v1.36.2+k3s1`, HA with embedded etcd across control-plane nodes `opl01`, `opl04`, `opl05`. Traefik is the default IngressClass.
- Chart `kubeVersion` is `>=1.25.0-0` for every version on this path. Kubernetes imposes no constraint.
- 20 Applications exist; **16 have `automated.prune: true` and `selfHeal: true`**.
- No OIDC/Dex (`admin.enabled: true`, `policy.csv` and `policy.default` both empty), no ApplicationSets, no redis-ha, no `ApplyOutOfSyncOnly` on any app.
- `argocd-cm` has no `application.resourceTrackingMethod` key, so tracking is label-based via `application.instanceLabelKey: argocd.argoproj.io/instance`.

### Why the previous attempts failed

Two independent landmines, both still present:

1. **CRD size vs client-side apply.** The `applications` CRD is 275 KB in 7.3.6 and grows on every hop. ArgoCD applies client-side, writing the manifest into `kubectl.kubernetes.io/last-applied-configuration`, which has a hard 262,144-byte limit. Live annotations are already at 130 KB (`applications`) and 222 KB (`applicationsets`). Chart `9.4.12` was the first to ship `crds.annotations: {argocd.argoproj.io/sync-options: ServerSideApply=true}` — charts `7.9.1` and `8.6.4` do **not** have it.
2. **Stale `redis-secret-init` Helm hooks.** The ServiceAccount, Role, RoleBinding and completed Job have existed for 566 days. argo-helm issue [#3756](https://github.com/argoproj/argo-helm/issues/3756) (open, reproduced on chart 9.4.4) is exactly this: PreSync Role/RoleBinding fail `already exists` → `SyncFailed`.

Server-side apply resolves both, because apply adopts existing objects instead of creating them.

## Architecture Decisions

1. **ServerSideApply is configured before any version bump** (Phase 0), not later. Required for the 7.9.1 and 8.6.4 hops which have no chart-native SSA annotation.
2. **Stop at chart 9.7.1 / v3.4.4.** Argo CD v3.5 replaces bundled Helm with Helm 4 and ignores `spec.source.helm.version: v3`, re-rendering all ~35 child charts. Too large a blast radius to append here.
3. **Resource tracking stays pinned to `label` through every version hop**, then migrates in Phase 4. v3.0 flips the default to `annotation`; pinning keeps the version upgrade and the tracking migration from ever being in flight together.
4. **Auto-sync is disabled on the `argo-cd` Application for Phases 0–3** and restored in Phase 4. All other Applications keep auto-sync throughout.
5. **Accept Argo CD v3.0's new defaults**: default `resource.exclusions`, `resource.customizations.ignoreResourceUpdates`, `ignoreResourceStatusField: all`, and `controller.resource.health.persist: false`.
6. **Version control strategy: checkpoint commits on `main`.** ArgoCD deploys from `targetRevision: HEAD`, so each phase is one commit and rollback is `git revert` plus a manual sync. Do not batch phases into one commit.

## Assumptions

- The `private-apps` SSH deploy key for `git@github.com:singh-gur/private_charts.git` is regenerable by the user, so losing that Secret is recoverable rather than fatal.
- `.backups/` is gitignored, so anything written there will not be committed.
- The repo's `values_local.yaml` override mechanism is not in play for `charts/argo-cd/`.

## Constraint: Secret handling

The executing agent must **not** read, dump, decode, or inspect Kubernetes Secrets. Every step in this plan touching Secret contents is marked *(user-performed)*. Note that `just backup-argocd` writes full Secret data into `.backups/` — running it is the user's decision.

## Phase Strategy

Phase 0 carries all the risk reduction and ends by syncing at the **current** chart version, proving SSA works before anything moves. Phases 1–3 are then mechanically identical single-version hops, each independently revertable. Phase 4 is the one deliberate behavior migration.

---

## Phase 0 — Backup & Pre-flight Hardening

- **Objective**: Establish a restore point and reconfigure ArgoCD so that CRD apply and Helm hooks cannot fail, verified by a clean sync at the unchanged chart version.
- **Status**: Not Started
- **Complexity**: Medium
- **Estimated Time**: 60–90 min
- **Prerequisites**: None

### Context for this Phase

No version changes here. The final gate is a manual sync at `7.3.6` that must succeed with server-side apply active. If that sync fails, the version hops will fail too, and this is the cheapest possible place to discover it.

### Files

| Path | Action | Purpose |
| --- | --- | --- |
| `justfile` | modify | Fix recipes that target the wrong namespace and the broken `sed` |
| `charts/root-app/templates/argo-cd.yaml` | modify | Add `ServerSideApply=true` to `syncOptions` |
| `charts/root-app/values.yaml` | modify | Set `argocd.syncPolicy.automated: false` |
| `charts/argo-cd/values.yaml` | modify | Pin tracking/params/networkPolicy, add CRD SSA annotation and CRD ignoreDifferences, remove dead key |

### Implementation Tasks

- [ ] **Backup** *(user-performed)*: on a control-plane node, run `sudo k3s etcd-snapshot save --name pre-argocd-upgrade`, then confirm with `sudo k3s etcd-snapshot ls`. Snapshots default to `/var/lib/rancher/k3s/server/db/snapshots/`. Copy the snapshot off-node before proceeding.
- [ ] `justfile` — fix `backup-argocd` and `validate-argocd`: they query `-n argocd`, but this install is in `default`, so they have silently produced empty backups. Make the namespace a recipe variable defaulting to `default`.
- [ ] `justfile` — fix `upgrade-argocd`/`rollback-argocd`: `sed -i 's/version: .*/version: {{version}}/'` rewrites **both** `version:` lines in `Chart.yaml`, clobbering the parent chart version. Target only the dependency version. Also fix `CURRENT_VERSION`, which greps `apiVersion: v2` first and reports `v2`.
- [ ] `justfile` — fix `list-argocd-versions`: uses repo name `argo-cd/argo-cd`; the configured repo is `argo`, so the correct search is `argo/argo-cd`.
- [ ] Run `just backup-argocd` *(user decides; writes Secret data to `.backups/`)*.
- [ ] `charts/root-app/templates/argo-cd.yaml` — add `- ServerSideApply=true` to both `syncOptions` lists (the `automated` and non-`automated` branches).
- [ ] `charts/root-app/values.yaml` — set `argocd.syncPolicy.automated: false` to stop auto-sync on the ArgoCD app for the duration.
- [ ] `charts/argo-cd/values.yaml` — apply all of the following under the `argo-cd:` key:
  - Remove `applicationSet.enabled: false`. This key exists in **no** chart version 7.x–10.x; the controller is deployed regardless and the line is misleading. No ApplicationSets exist, so the idle controller is harmless.
  - Add `crds.annotations."argocd.argoproj.io/sync-options": ServerSideApply=true`.
  - Add `configs.cm."application.resourceTrackingMethod": label` to pin v2 tracking behavior across the v3.0 boundary.
  - Add `configs.cm."resource.customizations.ignoreDifferences.apiextensions.k8s.io_CustomResourceDefinition"` with `jsonPointers: [/spec/preserveUnknownFields]`, since v3.0 stops auto-ignoring that field and other charts' CRDs would drift OutOfSync.
  - Add `configs.params."applicationsetcontroller.policy": sync` to preserve current behavior past chart 9.0.0, which drops the chart default.
  - Add `global.networkPolicy.create: false` to preserve current behavior past chart 10.0.0. Not strictly needed at 9.7.1, but pinning now avoids a surprise later.
- [ ] `helm dependency update charts/argo-cd && helm lint charts/argo-cd`, then render and diff against live to confirm the only changes are the intended ConfigMap keys and CRD annotations — no image or workload changes.
- [ ] Commit and push. Manually sync the `argo-cd` Application and watch it to completion.

### Verification

- [ ] `sudo k3s etcd-snapshot ls` lists `pre-argocd-upgrade`, and a copy exists off-node
- [ ] `kubectl get crd applications.argoproj.io -o yaml` shows an `argocd.argoproj.io` entry under `metadata.managedFields` with `manager: argocd-controller` and `operation: Apply`
- [ ] No `already exists` errors on `redis-secret-init` resources in the sync result
- [ ] `kubectl get cm argocd-cm -n default -o jsonpath='{.data.application\.resourceTrackingMethod}'` returns `label`
- [ ] `kubectl get applications -A` — all 20 Synced/Healthy
- [ ] ArgoCD server image still `v2.11.4` (nothing should have upgraded)

### Completion Gate

User confirms the sync succeeded with SSA active and no hook collisions. **If this gate fails, do not proceed** — the version hops depend on it.

### Outputs

- Verified etcd snapshot
- ArgoCD syncing its own chart via server-side apply
- Tracking, params, and networkPolicy pinned; dead config removed
- Working `justfile` backup/validate/upgrade recipes

---

## Phase 1 — Chart 7.9.1 (Argo CD v2.14.11)

- **Objective**: Reach the last v2.x chart, proving the hop mechanics before the major.
- **Status**: Not Started
- **Complexity**: Low
- **Estimated Time**: 30 min
- **Prerequisites**: Phase 0 complete

### Context for this Phase

Crosses Argo CD v2.12, v2.13, v2.14. Low risk here: the v2.12 cluster-secret `project` scoping change needs no action (no cluster secrets carry a `project`), and the v2.13/v2.14 changes concern Dex and CronJob job naming. Never target `v2.14.0`, which shipped a broken image reference; chart `7.9.1` is `v2.14.11`.

Chart 7.9.0's redis-ha advisory does not apply — this install uses the single `argocd-redis` Deployment.

### Files

| Path | Action | Purpose |
| --- | --- | --- |
| `charts/argo-cd/Chart.yaml` | modify | Dependency version `7.3.6` → `7.9.1` |
| `charts/argo-cd/Chart.lock` | modify | Regenerated by `helm dependency update` |

### Implementation Tasks

- [ ] Bump the **dependency** version only (leave the parent chart `version: 1.0.0` alone), then `helm dependency update charts/argo-cd`
- [ ] Render the new chart and diff against the previous render; confirm changes are limited to image tags, chart labels, and expected CRD growth
- [ ] Commit, push, manually sync, watch to completion
- [ ] Restart-watch the control plane: the application-controller StatefulSet and server Deployment roll during this sync

### Verification

- [ ] `kubectl get deploy argo-cd-argocd-server -n default -o jsonpath='{.spec.template.spec.containers[0].image}'` returns `v2.14.11`
- [ ] All 5 ArgoCD workloads Running and Ready
- [ ] `kubectl get applications -A` — all 20 Synced/Healthy
- [ ] UI reachable at `https://argocd.gsingh.io` and login works

### Completion Gate

User confirms ArgoCD is on v2.14.11 and all applications are healthy.

### Outputs

- Chart 7.9.1 deployed; hop procedure validated

---

## Phase 2 — Chart 8.6.4 (Argo CD v3.1.8) — the major

- **Objective**: Cross the v2 → v3 major boundary with tracking behavior unchanged.
- **Status**: Not Started
- **Complexity**: Medium
- **Estimated Time**: 60–90 min
- **Prerequisites**: Phase 1 complete

### Context for this Phase

The v2.14 → v3.0 upgrade is documented as low-risk, and most of its breaking changes are already neutralized: tracking is pinned to `label` (Phase 0), CRD `preserveUnknownFields` diffs are ignored (Phase 0), and Dex/ApplicationSet/legacy-repo changes do not apply to this install.

Two remaining items to handle here:

- **Logs RBAC** becomes enforced by default and `server.rbac.log.enforce.enable` is removed. This install technically matches the "affected" profile (empty `policy.default`, flag set to `false`), but with `admin.enabled: true` and no OIDC, the admin user bypasses RBAC and nothing breaks in practice.
- **Bundled Helm moves to 3.17.1**, which changed `null` handling: a `null` in values now genuinely overrides instead of being warned-and-ignored. `charts/root-app/templates/airflow.yaml:55` and `:68` set `ttlSecondsAfterFinished: null`, and airflow is enabled.

v3.0's accepted new defaults mean `.status.resources[].health` disappears from Application CRs (`resourceHealthSource: appTree`). `just backup-all-apps` dumps will no longer carry per-resource health — expected, not a regression to fix.

### Files

| Path | Action | Purpose |
| --- | --- | --- |
| `charts/argo-cd/Chart.yaml` | modify | Dependency version `7.9.1` → `8.6.4` |
| `charts/argo-cd/Chart.lock` | modify | Regenerated |
| `charts/root-app/templates/airflow.yaml` | inspect | Verify Helm 3.17.1 null-override behavior |

### Implementation Tasks

- [ ] Before syncing, render the airflow Application's Helm output and determine whether `ttlSecondsAfterFinished: null` now emits an explicit null into the rendered Job spec. If it materially changes the manifest, remove the `null` lines rather than relying on the old ignore behavior.
- [ ] Bump the dependency version to `8.6.4` and `helm dependency update charts/argo-cd`
- [ ] Render and diff; confirm the CRD SSA annotation from Phase 0 is still present on all 3 CRDs (chart 8.x has no native default)
- [ ] Commit, push, manually sync, watch to completion
- [ ] Confirm `argocd-cm` no longer carries `server.rbac.log.enforce.enable`; if the chart still emits it, drop it from values

### Verification

- [ ] Server image reports `v3.1.8`
- [ ] `kubectl get cm argocd-cm -n default -o jsonpath='{.data.application\.resourceTrackingMethod}'` still returns `label`
- [ ] Resources still carry the `argocd.argoproj.io/instance` label; no `tracking-id` annotations have appeared
- [ ] `kubectl get applications -A` — all 20 Synced/Healthy, **no unexpected pruning**
- [ ] Airflow app Synced/Healthy and its scheduled jobs unaffected
- [ ] UI reachable and login works

### Completion Gate

User confirms ArgoCD is on v3.1.8, tracking is still label-based, and no resources were pruned.

### Outputs

- Chart 8.6.4 deployed; v2 → v3 major crossed with tracking untouched

---

## Phase 3 — Chart 9.7.1 (Argo CD v3.4.4)

- **Objective**: Reach the target version.
- **Status**: Not Started
- **Complexity**: Medium
- **Estimated Time**: 45–60 min
- **Prerequisites**: Phase 2 complete

### Context for this Phase

Crosses Argo CD v3.2, v3.3, v3.4. Chart 9.7.1 is `>= 9.4.12`, so the SSA annotation is now chart-native and the Phase 0 pin becomes redundant but harmless — keep it, since removing it would be a behavior change for no gain.

Expected non-failures:

- **v3.2 adds CronJob health checks.** The only CronJobs are Rancher/fleet-managed (`fleet-cleanup-gitrepo-jobs`, `rke2-machineconfig-cleanup-cronjob`), so the `rancher` app may display `Degraded` based on last-job health. Cosmetic; does not trigger deletion.
- **v3.4 changes `Missing` health** to apply only when *all* an app's resources are missing.
- **v3.4 changes stored cluster version format** to `vMajor.Minor.Patch`.
- Chart 9.0.0 drops chart defaults under `configs.params`; `applicationsetcontroller.policy` and `server.insecure` are explicitly pinned so this is a no-op.

### Files

| Path | Action | Purpose |
| --- | --- | --- |
| `charts/argo-cd/Chart.yaml` | modify | Dependency version `8.6.4` → `9.7.1` |
| `charts/argo-cd/Chart.lock` | modify | Regenerated |

### Implementation Tasks

- [ ] Bump the dependency version to `9.7.1` and `helm dependency update charts/argo-cd`
- [ ] Render and diff; confirm `configs.params` still contains `server.insecure: true` and `applicationsetcontroller.policy: sync` after the 9.0.0 default removal
- [ ] Commit, push, manually sync, watch to completion
- [ ] Review any app that flips to `Degraded` and confirm it traces to the v3.2 CronJob health check rather than a real fault

### Verification

- [ ] Server image reports `v3.4.4`
- [ ] `kubectl get cm argocd-cmd-params-cm -n default -o jsonpath='{.data.server\.insecure}'` returns `true`
- [ ] Ingress still serves `argocd.gsingh.io` over Traefik; UI login works
- [ ] `kubectl get applications -A` — all 20 Synced, Healthy except any explained-and-accepted CronJob `Degraded`
- [ ] Tracking still `label`

### Completion Gate

User confirms ArgoCD is on v3.4.4 and any `Degraded` status is understood and accepted.

### Outputs

- Chart 9.7.1 / Argo CD v3.4.4 deployed; version upgrade complete

---

## Phase 4 — Tracking Migration & Restore Auto-Sync

- **Objective**: Migrate from label-based to annotation-based resource tracking as the only variable in play, then restore normal automation.
- **Status**: Not Started
- **Complexity**: Medium
- **Estimated Time**: 45 min
- **Prerequisites**: Phase 3 complete and stable for at least one reconciliation cycle

### Context for this Phase

Annotation-based tracking has been the Argo CD default since v3.0 and is more reliable than labels, which external tooling can copy between resources.

The documented edge case: if the **first sync after the switch** includes a resource deletion, ArgoCD will not recognize the resource as managed and will **fail to delete it**, leaving an orphan. The failure mode leaves things behind rather than removing them, so the 16 apps with `prune: true` are not a mass-deletion hazard. The remedy is to explicitly sync every application right after the flip, even ones already showing Synced, so orphan detection is correct on subsequent syncs.

No app uses `ApplyOutOfSyncOnly=true`, which is the condition requiring special handling.

### Files

| Path | Action | Purpose |
| --- | --- | --- |
| `charts/argo-cd/values.yaml` | modify | `application.resourceTrackingMethod` → `annotation` |
| `charts/root-app/values.yaml` | modify | Restore `argocd.syncPolicy.automated: true` |

### Implementation Tasks

- [ ] Change `configs.cm."application.resourceTrackingMethod"` from `label` to `annotation`. Keep the key explicit rather than deleting it, so the setting stays visible in git.
- [ ] Commit, push, manually sync the `argo-cd` Application, confirm the controller restarts cleanly
- [ ] Explicitly sync **all 20 applications**, including ones reporting Synced
- [ ] Spot-check several resources across different apps for the `argocd.argoproj.io/tracking-id` annotation in the format `<app>:<group>/<kind>:<namespace>/<name>`
- [ ] Restore `argocd.syncPolicy.automated: true` in `charts/root-app/values.yaml`, commit, push, and sync once manually so auto-sync resumes from a known-good state
- [ ] Check for orphaned resources left carrying only the old `argocd.argoproj.io/instance` label with no owning app

### Verification

- [ ] `kubectl get cm argocd-cm -n default -o jsonpath='{.data.application\.resourceTrackingMethod}'` returns `annotation`
- [ ] Sampled resources carry `argocd.argoproj.io/tracking-id`
- [ ] `kubectl get applications -A` — all Synced/Healthy
- [ ] `kubectl get app argo-cd -n default -o jsonpath='{.spec.syncPolicy.automated}'` is populated
- [ ] A trivial test change reconciles automatically, confirming auto-sync is live

### Completion Gate

User confirms annotation tracking is active, no orphans were introduced, and auto-sync is restored.

### Outputs

- Annotation-based tracking active
- Auto-sync restored on the ArgoCD Application
- Upgrade complete: chart 9.7.1 / Argo CD v3.4.4

---

## Phase Dependencies

Strictly sequential — `Phase 0 → 1 → 2 → 3 → 4`. No phase may run in parallel with another, since every phase mutates the same control plane. Phase 0's gate is load-bearing for all later phases.

## Rollback

Per phase: `git revert` the phase commit, push, manually sync. Because auto-sync is off for Phases 0–3, a failed sync leaves the previous state running rather than cascading.

Caveats:

- **CRD downgrade is the least-tested path.** CRDs are `resource-policy: keep`, and reverting a chart applies an older CRD schema over newer stored objects. Argo CD's v3 CRDs are supersets of v2's, so this is usually safe, but prefer fixing forward over reverting a CRD-bearing phase.
- If the control plane is unusable and a revert cannot be synced because ArgoCD itself is broken, restore from the Phase 0 etcd snapshot.
- `helm rollback` is not available — the release is ArgoCD-managed, and the `sh.helm.release.v1.argo-cd.v1` secret is a stale artifact of the original install, not a live release history.

## Risks

- **Rollback across CRD versions** — mitigated by the etcd snapshot and a fix-forward preference.
- **Bundled Helm moves 3.15 → 3.19** across these hops, re-rendering all child charts. Mitigated by rendering and diffing at each phase. The known concrete instance is airflow's `ttlSecondsAfterFinished: null` under Helm 3.17.1.
- **16 apps with `prune: true`** could act on a half-upgraded control plane. Mitigated by auto-sync being off for the ArgoCD app and by syncing one phase at a time.
- **Stale `redis-secret-init` hooks** (argo-helm [#3756](https://github.com/argoproj/argo-helm/issues/3756)). Primary mitigation is SSA adoption. Contingency: delete the stale `argo-cd-argocd-redis-secret-init` ServiceAccount, Role, RoleBinding and Job. **Never delete the `argocd-redis` Secret** — that rotates redis auth and requires restarting every component.
- **`targetRevision: HEAD`** means the source is re-read on every reconciliation. Avoid pushing unrelated commits to `main` mid-phase.

## Questions for User

None outstanding.
