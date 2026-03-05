# Implementation Plan: Helm Sub-App Upgrades

## Overview

Upgrade all sub-applications managed by the `root-app` ArgoCD App-of-Apps pattern to their latest Helm chart versions. Work is organized into phases by risk level: patch upgrades first, then minor upgrades, then manual-verification apps, then major/breaking upgrades for disabled apps, and finally a deprecation review. ArgoCD itself is excluded from this plan and will be handled separately.

## Global Context

### Current Architecture
- **Pattern**: ArgoCD App-of-Apps. `charts/root-app/` contains ArgoCD Application CRDs that point to external Helm repos.
- **Version pinning**: All chart versions are pinned in `charts/root-app/values.yaml` via `<app>.version`.
- **ArgoCD self-management**: ArgoCD manages itself via `charts/argo-cd/` (a wrapper chart with a dependency on `argo-cd` from `argoproj/argo-helm`). Version is pinned in `charts/argo-cd/Chart.yaml`.
- **Testing**: Use `helm lint charts/root-app/` and `just test-render <app>` to validate templates.

### Version Audit Summary (as of 2026-03-04)

| App | Chart | Repo | Current | Latest (AH) | Delta | Enabled | Risk |
|-----|-------|------|---------|-------------|-------|---------|------|
| lgtm | lgtm-distributed | grafana | 3.0.1 | 3.0.1 | None | Yes | **DEPRECATED** |
| alloy | alloy | grafana | 1.0.3 | 1.6.1 | Minor (+6) | Yes | Medium |
| authentik | authentik | goauthentik | 2025.10.3 | 2026.2.1 | **Major** (year) | No | High |
| airflow | airflow | bitnami | 25.0.2 | 25.0.2 | None | No | N/A |
| argowf | argo-workflows | argoproj | 0.45.6 | 0.47.4 | Minor (+2) | No | Low |
| argocd | argo-cd | argoproj | 7.3.6 | 9.4.7 | **MAJOR** (3 chart majors) | Yes | **Critical** |
| coder | coder | coder-v2 | 2.29.6 | 2.31.2 | Minor (+2) | Yes | Low |
| fission | fission-all | fission | 1.22.1 | ? (not on AH) | Unknown | Yes | Unknown |
| fissionauth | oauth2-proxy | oauth2-proxy | 10.1.2 | 10.1.4 | Patch | Yes | Very Low |
| ghost | ghost | bitnami | 24.0.1 | 25.0.4 | **Major** (+1) | No | Medium |
| langfuse | langfuse | langfuse-k8s | 1.5.18 | ? (not on AH) | Unknown | Yes | Unknown |
| protonbridge | protonmail-bridge | k8s-at-home | 5.4.2 | N/A | **Repo archived** | No | Dead |
| rancher | rancher | rancher | 2.11.2 | ? (not on AH) | Unknown | Yes | Unknown |
| uptime | uptime-kuma | dirsigler | 2.24.0 | ? (not on AH) | Unknown | Yes | Unknown |
| promtail | promtail | grafana | 6.17.0 | 6.17.1 | Patch | Yes | **DEPRECATED** |
| k8sMonitoring | k8s-monitoring | grafana | 3.5.7 | 3.8.1 | Minor (+3) | No | Low |
| zitadel | zitadel | zitadel | 9.17.1 | 9.24.0 | Minor (+7) | Yes | Medium |
| windmill | windmill | windmill-labs | 4.0.21 | ? (not on AH) | Unknown | No | Unknown |
| trino | trino | trinodb | 1.42.0 | 1.42.0 | None | Yes | N/A |
| dagster | dagster | dagster-io | 1.12.13 | 1.12.17 | Patch | Yes | Very Low |
| oauth2Proxy | oauth2-proxy | oauth2-proxy | 10.1.2 | 10.1.4 | Patch | Yes | Very Low |
| prefect | prefect-server | prefecthq | 2026.1.30002458 | ? (not on AH) | Unknown | Yes | Unknown |
| prefectWorker | prefect-worker | prefecthq | 2026.1.30002458 | ? (not on AH) | Unknown | Yes | Unknown |
| openproject | openproject | openproject | 10.3.0 | ? (not on AH) | Unknown | No | Unknown |
| kyuubi | kyuubi (git) | awesome-kyuubi | HEAD | HEAD | N/A | No | N/A |

**Already at latest (no action):** lgtm (3.0.1, but deprecated), airflow (25.0.2), trino (1.42.0)

## Architecture Decisions

1. **Upgrade enabled apps before disabled apps** -- production stability first; disabled apps can be upgraded with less urgency.
2. **ArgoCD upgrade is out of scope** -- it self-manages and crosses 3 chart majors + 1 app major (v2 -> v3). It will be handled in a dedicated separate plan.
3. **Apps not on Artifact Hub require manual version checks** -- these are grouped into a research phase before any version bumps.
4. **Deprecation review is a separate final phase** -- lgtm-distributed, promtail, and protonbridge all have upstream deprecation/archival issues that need migration planning.

## Assumptions

1. ArgoCD auto-sync is enabled, so version bumps in `values.yaml` will trigger automatic rollout.
2. All apps use the existing secrets pattern -- no secrets will need rotation during upgrades.
3. For apps not on Artifact Hub, the implementer will need to manually check the Helm repo index or GitHub releases for latest versions.

---

## Phases

### Phase 1: Patch Upgrades (Enabled Apps)

**Objective**: Bump all enabled apps with patch-level updates to latest -- minimal risk, no breaking changes expected.

**Complexity**: low
**Estimated Time**: 15 min

**Prerequisites**:
- None

**Context for this Phase**:
- All changes are in `charts/root-app/values.yaml`
- Patch upgrades are backward-compatible by semver convention
- After changes, validate with `helm lint charts/root-app/` and `just test-render <app>` for each modified app
- These apps are all **currently enabled** in the cluster, so ArgoCD will auto-sync the changes

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Bump version strings for patch-level upgrades |

**Implementation Steps**:
1. In `charts/root-app/values.yaml`, update the following versions:
   - `promtail.version`: `6.17.0` -> `6.17.1` (line 315)
   - `dagster.version`: `1.12.13` -> `1.12.17` (line 414)
   - `oauth2Proxy.version`: `"10.1.2"` -> `"10.1.4"` (line 460)
   - `fissionauth.version`: `"10.1.2"` -> `"10.1.4"` (line 193)
2. Run `helm lint charts/root-app/` to validate chart syntax
3. Run `just test-render promtail` to verify promtail template renders correctly
4. Run `just test-render dagster` to verify dagster template renders correctly
5. Run `just test-render oauth2-proxy` to verify oauth2-proxy template renders
6. Visually inspect rendered output for any unexpected changes

**Verification**:
- [ ] `helm lint charts/root-app/` passes with no errors
- [ ] `just test-render promtail` renders without errors
- [ ] `just test-render dagster` renders without errors
- [ ] Rendered templates show only the version number changed in `targetRevision`

**Outputs**:
- Updated `values.yaml` with 4 patch-level version bumps

**Git**: Commit after this phase
```
git add charts/root-app/values.yaml
git commit -m "phase 1: patch upgrades for promtail, dagster, oauth2-proxy, fission-auth"
```

---

### Phase 2: Minor Upgrades - Alloy (1.0.3 -> 1.6.1)

**Objective**: Upgrade Grafana Alloy from 1.0.3 to 1.6.1 (6 minor versions, enabled app).

**Complexity**: medium
**Estimated Time**: 30 min

**Prerequisites**:
- Phase 1 completed

**Context for this Phase**:
- Alloy chart is at `https://grafana.github.io/helm-charts`, chart name `alloy`
- Template is at `charts/root-app/templates/alloy.yaml` -- very simple, no helm values passthrough (just targetRevision)
- Jumping 6 minor versions (1.0 -> 1.6). The alloy template passes no custom values, so breaking changes in values schema are unlikely to affect this deployment.
- Alloy appVersion moves from an older version to v1.13.2
- Check the Alloy changelog at https://github.com/grafana/alloy/releases for any behavioral changes

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Bump `alloy.version` from `1.0.3` to `1.6.1` |

**Implementation Steps**:
1. Review the Alloy Helm chart changelog for versions 1.1.0 through 1.6.1 for any breaking changes or new required values. Check https://github.com/grafana/alloy/releases and https://grafana.github.io/helm-charts
2. In `charts/root-app/values.yaml`, update `alloy.version`: `1.0.3` -> `1.6.1` (line 38)
3. Run `helm lint charts/root-app/`
4. Run `just test-render alloy` and compare output with pre-upgrade render
5. Verify the rendered ArgoCD Application CRD has the correct `targetRevision: 1.6.1`

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] `just test-render alloy` renders without errors
- [ ] No new required values were introduced that need to be added to the template

**Outputs**:
- Updated alloy version to 1.6.1

**Git**: Commit after this phase
```
git add charts/root-app/values.yaml
git commit -m "phase 2: upgrade alloy 1.0.3 -> 1.6.1"
```

---

### Phase 3: Minor Upgrades - Coder (2.29.6 -> 2.31.2)

**Objective**: Upgrade Coder from 2.29.6 to 2.31.2 (2 minor versions, enabled app).

**Complexity**: low
**Estimated Time**: 20 min

**Prerequisites**:
- Phase 1 completed (can run in parallel with Phase 2)

**Context for this Phase**:
- Coder chart is at `https://helm.coder.com/v2`, chart name `coder`
- Template is at `charts/root-app/templates/coder.yaml`
- The template passes env vars for OIDC, DB connection, access URL, and ingress config via `coder.env[]`
- Coder uses environment variables for configuration (not Helm values), so chart value schema changes are unlikely to break this setup
- AppVersion moves from 2.29.6 to 2.31.2 -- review https://github.com/coder/coder/releases for breaking changes

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Bump `coder.version` from `2.29.6` to `2.31.2` |

**Implementation Steps**:
1. Review Coder release notes for 2.30.x and 2.31.x at https://github.com/coder/coder/releases for any breaking changes
2. In `charts/root-app/values.yaml`, update `coder.version`: `2.29.6` -> `2.31.2` (line 159)
3. Run `helm lint charts/root-app/`
4. Run `just test-render coder` and verify template renders correctly
5. Verify all env var names are still valid in the new version (check Coder docs if any were renamed/removed)

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] `just test-render coder` renders without errors
- [ ] No env var names were deprecated or renamed in the version range

**Outputs**:
- Updated coder version to 2.31.2

**Git**: Commit after this phase
```
git add charts/root-app/values.yaml
git commit -m "phase 3: upgrade coder 2.29.6 -> 2.31.2"
```

---

### Phase 4: Minor Upgrades - Zitadel (9.17.1 -> 9.24.0)

**Objective**: Upgrade Zitadel from 9.17.1 to 9.24.0 (7 minor versions, enabled app, identity provider).

**Complexity**: medium
**Estimated Time**: 30 min

**Prerequisites**:
- Phase 1 completed (can run in parallel with Phases 2-3)

**Context for this Phase**:
- Zitadel chart is at `https://charts.zitadel.com`, chart name `zitadel`
- Template is at `charts/root-app/templates/zitadel.yaml`
- The template configures: `masterkeySecretName`, `configmapConfig` (ExternalPort, ExternalSecure, ExternalDomain, TLS), `configSecretName`, `login` (new login UI toggle), `initJob`, and ingress
- Zitadel is the identity provider (auth.gsingh.io) -- other apps depend on it for OIDC (argowf, coder, openproject, fission-auth, oauth2-proxy)
- AppVersion moves to v4.10.1 -- this is a significant app version jump
- **Risk**: As the IdP, a failed upgrade could break authentication for multiple services
- Check https://github.com/zitadel/zitadel/releases for breaking changes and https://github.com/zitadel/zitadel-charts/releases for chart changes
- The `login.enabled` field was recently introduced -- verify it's still supported in 9.24.0

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Bump `zitadel.version` from `9.17.1` to `9.24.0` |
| `charts/root-app/templates/zitadel.yaml` | possibly modify | If chart values schema changed |

**Implementation Steps**:
1. Review Zitadel Helm chart changelog from 9.18.0 to 9.24.0 at https://github.com/zitadel/zitadel-charts/releases
2. Review Zitadel app release notes for any database migration or breaking API changes
3. Check if `login.enabled` and `login.ingress.enabled` values are still supported in v9.24.0
4. Check if `initJob.command` is still required or has changed
5. In `charts/root-app/values.yaml`, update `zitadel.version`: `9.17.1` -> `9.24.0` (line 291)
6. Run `helm lint charts/root-app/`
7. Run `just test-render zitadel` and carefully compare output
8. Verify all passed helm values (`masterkeySecretName`, `configmapConfig`, `configSecretName`, `login`, `initJob`, `ingress`) are still valid

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] `just test-render zitadel` renders without errors
- [ ] All existing values still appear in the chart's values reference
- [ ] No new required values were introduced

**Outputs**:
- Updated zitadel version to 9.24.0

**Git**: Commit after this phase
```
git add charts/root-app/
git commit -m "phase 4: upgrade zitadel 9.17.1 -> 9.24.0"
```

---

### Phase 5: Manual Version Check (Apps Not on Artifact Hub)

**Objective**: Research and determine latest versions for apps whose Helm repos are not indexed on Artifact Hub, then bump versions where appropriate.

**Complexity**: medium
**Estimated Time**: 45 min

**Prerequisites**:
- Phase 1 completed

**Context for this Phase**:
Several apps use Helm repositories not indexed on Artifact Hub. Each needs manual version discovery by checking the Helm repo index or GitHub releases. The apps to check are:

| App | Current Version | Helm Repo URL | Enabled |
|-----|----------------|---------------|---------|
| fission | 1.22.1 | https://fission.github.io/fission-charts/ | Yes |
| rancher | 2.11.2 | https://releases.rancher.com/server-charts/latest | Yes |
| uptime | 2.24.0 | https://dirsigler.github.io/uptime-kuma-helm | Yes |
| langfuse | 1.5.18 | https://langfuse.github.io/langfuse-k8s | Yes |
| prefect | 2026.1.30002458 | https://prefecthq.github.io/prefect-helm | Yes |
| prefectWorker | 2026.1.30002458 | https://prefecthq.github.io/prefect-helm | Yes |
| windmill | 4.0.21 | https://windmill-labs.github.io/windmill-helm-charts/ | No |
| openproject | 10.3.0 | https://charts.openproject.org | No |

To find the latest version, fetch the `index.yaml` from each Helm repo:
```bash
curl -s <repoURL>/index.yaml | head -50
# or
helm repo add <name> <repoURL> && helm search repo <name>/<chart> --versions | head -5
```

All changes are in `charts/root-app/values.yaml`. For each app, validate the template renders after the version bump.

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Bump versions for non-AH apps after manual verification |

**Implementation Steps**:
1. For each of the 8 apps listed above, determine the latest chart version:
   - Add the Helm repo: `helm repo add <name> <url>`
   - Search for latest: `helm search repo <name>/<chart> --versions | head -5`
2. For each enabled app where a newer version exists:
   - Review the changelog/release notes for breaking changes
   - If the upgrade is patch or minor with no breaking changes, bump the version in `values.yaml`
   - If the upgrade is major or has breaking changes, **do not bump** -- document it for a later phase
3. For disabled apps (windmill, openproject), record the latest version but only bump if it's a safe minor/patch update
4. Run `helm lint charts/root-app/` after all changes
5. Run `just test-render <app>` for each modified enabled app
6. Document findings: for each app, record current version, latest version, and whether it was upgraded or deferred

**Verification**:
- [ ] Latest versions documented for all 8 apps
- [ ] `helm lint charts/root-app/` passes
- [ ] `just test-render <app>` passes for each modified app
- [ ] Any major/breaking upgrades are documented for future phases

**Outputs**:
- Updated versions for non-AH apps (where safe)
- Documentation of latest available versions and any deferred major upgrades

**Git**: Commit after this phase
```
git add charts/root-app/values.yaml
git commit -m "phase 5: version bumps for non-artifact-hub apps (fission, rancher, uptime, langfuse, prefect)"
```

---

### Phase 6: Minor Upgrades (Disabled Apps)

**Objective**: Upgrade disabled apps with minor-level updates: argo-workflows and k8s-monitoring.

**Complexity**: low
**Estimated Time**: 15 min

**Prerequisites**:
- Phase 1 completed (can run in parallel with Phases 2-5)

**Context for this Phase**:
- These apps are **disabled** (`enabled: false`), so version bumps won't trigger any cluster changes until they are re-enabled
- `argowf` (argo-workflows): 0.45.6 -> 0.47.4, chart at `https://argoproj.github.io/argo-helm`, chart name `argo-workflows`. Template at `charts/root-app/templates/argo-wf.yaml` configures SSO, ingress, workflow service accounts.
- `k8sMonitoring` (k8s-monitoring): 3.5.7 -> 3.8.1, chart at `https://grafana.github.io/helm-charts`, chart name `k8s-monitoring`. Template at `charts/root-app/templates/k8s-monitoring.yaml` is complex with many value passthroughs for metrics, logs, traces, and alloy instances.
- Since these are disabled, template rendering still works but won't produce output. The lint check is still valuable.

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Bump `argowf.version` and `k8sMonitoring.version` |

**Implementation Steps**:
1. In `charts/root-app/values.yaml`, update:
   - `argowf.version`: `0.45.6` -> `0.47.4` (line 140)
   - `k8sMonitoring.version`: `3.5.7` -> `3.8.1` (line 329)
2. Review argo-workflows chart changelog (0.46.x, 0.47.x) for any renamed/removed values that affect the template at `templates/argo-wf.yaml`
3. Review k8s-monitoring chart changelog (3.6.x, 3.7.x, 3.8.x) for any renamed/removed values that affect the template at `templates/k8s-monitoring.yaml`
4. Run `helm lint charts/root-app/`
5. If any values schema changes are found, update the corresponding template and/or values

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] No template syntax errors when apps are conditionally enabled for test renders

**Outputs**:
- Updated disabled app versions

**Git**: Commit after this phase
```
git add charts/root-app/
git commit -m "phase 6: upgrade disabled apps - argo-workflows 0.47.4, k8s-monitoring 3.8.1"
```

---

### Phase 7: MAJOR Upgrade - Authentik (2025.10.3 -> 2026.2.1)

**Objective**: Upgrade authentik Helm chart from 2025.10.3 to 2026.2.1 (year-based major version, currently disabled).

**Complexity**: medium
**Estimated Time**: 30 min

**Prerequisites**:
- Phase 1 completed
- App is currently disabled, so this is safe to merge without cluster impact

**Context for this Phase**:
- Authentik chart is at `https://charts.goauthentik.io`, chart name `authentik`
- Template is at `charts/root-app/templates/authentik.yaml`
- Currently **disabled** (`authentik.enabled: false`)
- The template passes: postgresql config (external), authentik core settings, global env vars (secrets), server config (replicas, ingress, TLS), worker config, serviceAccount
- Version jump: 2025.10.3 -> 2026.2.1 (year-based versioning, so this is a "major" jump by convention)
- Key concern: The authentik chart readme shows the values schema uses `authentik.existingSecret` pattern differently in 2026.x -- it now uses `authentik.existingSecret.secretName` (an object) instead of a plain string. **This may require template changes.**
- Dependencies changed: The 2026.2.1 chart uses `authentik-remote-cluster` serviceAccount sub-chart (v2.1.0) and bitnami postgresql (16.7.27)

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Bump `authentik.version` from `2025.10.3` to `2026.2.1` |
| `charts/root-app/templates/authentik.yaml` | possibly modify | If values schema changed for secrets handling |

**Implementation Steps**:
1. Review authentik changelog from 2025.10 to 2026.2: https://goauthentik.io/docs/releases and https://github.com/goauthentik/helm/releases
2. Specifically check if the `global.env` approach for passing secrets is still supported, or if `authentik.existingSecret.secretName` is now required
3. Check if `authentik.postgresql.host/port/name/user` keys are still valid or have been renamed
4. In `charts/root-app/values.yaml`, update `authentik.version`: `"2025.10.3"` -> `"2026.2.1"` (line 42)
5. If the values schema changed, update `charts/root-app/templates/authentik.yaml` to match the new schema
6. Run `helm lint charts/root-app/`
7. Temporarily enable authentik in values (`enabled: true`) and run `just test-render authentik` to verify template renders, then set it back to `false`

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] Template renders correctly when temporarily enabled
- [ ] Secret reference pattern is compatible with the new chart version
- [ ] PostgreSQL configuration keys are valid

**Outputs**:
- Updated authentik version to 2026.2.1
- Template updated if needed for schema changes

**Git**: Commit after this phase
```
git add charts/root-app/
git commit -m "phase 7: upgrade authentik 2025.10.3 -> 2026.2.1 (disabled)"
```

---

### Phase 8: MAJOR Upgrade - Ghost (24.0.1 -> 25.0.4)

**Objective**: Upgrade Bitnami Ghost from chart 24.0.1 to 25.0.4 (major version bump, currently disabled).

**Complexity**: medium
**Estimated Time**: 30 min

**Prerequisites**:
- Phase 1 completed

**Context for this Phase**:
- Ghost chart is from `registry-1.docker.io/bitnamicharts`, chart name `ghost` (OCI registry)
- Template is at `charts/root-app/templates/ghost.yaml`
- Currently **disabled** (`ghost.enabled: false`)
- The template passes: ghostHost, ingress hostname, ghostUsername, existingSecret, ghostEmail, ghostBlogTitle, mysql disabled, external database config
- Bitnami major version bumps typically involve significant values restructuring
- AppVersion moves from Ghost 5.x to 6.0.5 -- this is a major Ghost application upgrade
- Key concerns: Bitnami charts often rename values keys in major bumps (e.g., `ghostHost` -> different key, ingress structure changes)

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Bump `ghost.version` from `24.0.1` to `25.0.4` |
| `charts/root-app/templates/ghost.yaml` | possibly modify | If Bitnami values schema changed |

**Implementation Steps**:
1. Review Bitnami Ghost chart changelog for breaking changes between 24.x and 25.x
2. Check if these values are still valid in 25.x:
   - `ghostHost`, `ghostUsername`, `ghostEmail`, `ghostBlogTitle`
   - `ingress.enabled`, `ingress.hostname`
   - `existingSecret`
   - `mysql.enabled`, `externalDatabase.*`
3. In `charts/root-app/values.yaml`, update `ghost.version`: `24.0.1` -> `25.0.4` (line 213)
4. Update `charts/root-app/templates/ghost.yaml` if any values were renamed
5. Run `helm lint charts/root-app/`
6. Temporarily enable ghost and run `just test-render ghost` to verify, then disable again

**Verification**:
- [ ] `helm lint charts/root-app/` passes
- [ ] Template renders correctly when temporarily enabled
- [ ] All passed values are valid in the new chart version

**Outputs**:
- Updated ghost version to 25.0.4
- Template updated if needed

**Git**: Commit after this phase
```
git add charts/root-app/
git commit -m "phase 8: upgrade ghost 24.0.1 -> 25.0.4 (disabled)"
```

---

### Phase 9: Deprecation & End-of-Life Review

**Objective**: Address deprecated and archived upstream charts: lgtm-distributed, promtail, and protonmail-bridge.

**Complexity**: high
**Estimated Time**: 45 min (research and planning only; migration implementation is out of scope)

**Prerequisites**:
- Phases 1-8 completed

**Context for this Phase**:
Three charts have upstream deprecation or archival issues:

1. **lgtm-distributed** (grafana): Marked as **deprecated** on Artifact Hub. Current version 3.0.1 is the final version. The Grafana team recommends migrating to individual charts (grafana, loki, mimir, tempo) or the `k8s-monitoring` chart. This is currently **enabled** and provides the entire observability stack.

2. **promtail** (grafana): Marked as **deprecated** on Artifact Hub. Grafana recommends migrating to Grafana Alloy for log collection. This is currently **enabled** alongside Alloy (both are running). Version 6.17.1 is likely the last release.

3. **protonmail-bridge** (k8s-at-home): The entire k8s-at-home Helm chart repository has been **archived**. No further updates will be released. Chart URL `https://k8s-at-home.com/charts` may stop working. Currently **disabled**.

This phase produces a migration plan document, not code changes.

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| (no code changes) | research | Document migration paths |

**Implementation Steps**:
1. **lgtm-distributed migration research**:
   - Investigate `k8s-monitoring` chart (already in values at v3.8.1, currently disabled) as a replacement
   - Determine if k8s-monitoring can fully replace lgtm-distributed + promtail + alloy
   - Document the migration path: what values need to be carried over, what endpoints change
   - Check if Grafana dashboards/datasources will still work after migration

2. **promtail deprecation**:
   - Alloy is already deployed (1.0.3 -> 1.6.1 after Phase 2)
   - Determine if Alloy can fully replace promtail for log shipping to Loki
   - Document the overlap: are both currently sending logs to the same Loki endpoint?
   - Plan to disable promtail once Alloy log collection is confirmed working

3. **protonmail-bridge archival**:
   - Search for community forks or alternative charts
   - Consider creating a local chart under `charts/proton-bridge/` if no alternatives exist
   - Since it's disabled, this is low priority but should be documented

4. Document findings and recommended migration timeline

**Verification**:
- [ ] Migration path documented for lgtm-distributed
- [ ] Promtail -> Alloy migration feasibility confirmed
- [ ] Protonmail-bridge alternatives identified or local chart plan documented

**Outputs**:
- Deprecation migration plan (can be added as comments in values.yaml or a separate doc)
- Clear understanding of which deprecated apps can be safely removed

**Git**: Commit after this phase (if any values.yaml comments are added)
```
git add charts/root-app/values.yaml
git commit -m "phase 9: document deprecation migration paths for lgtm, promtail, protonbridge"
```

---

## Phase Dependencies

```
Phase 1 (patch upgrades)
    |-- Phase 2 (alloy minor)           \
    |-- Phase 3 (coder minor)            |-- can run in parallel
    |-- Phase 4 (zitadel minor)          |
    |-- Phase 5 (manual version check)   |
    |-- Phase 6 (disabled app minors)    |
    |-- Phase 7 (MAJOR: authentik)       |
    |-- Phase 8 (MAJOR: ghost)          /
            |
            v
    Phase 9 (deprecation review)  <-- final phase, research only
```

**Out of scope:** ArgoCD upgrade (7.3.6 -> 9.4.7) -- requires its own dedicated plan due to self-management complexity and v2->v3 app migration.

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Zitadel upgrade breaks OIDC for dependent apps | Auth fails for coder, argowf, fission, dagster | Upgrade during low-usage window; have rollback version ready |
| Values schema changes in minor upgrades | Templates render incorrectly | Always `helm lint` + `test-render` before pushing |
| Apps not on AH have unknown latest versions | May miss important security patches | Phase 5 handles manual checking |
| lgtm-distributed deprecation | No future security patches for observability stack | Phase 9 plans migration to k8s-monitoring |
| protonmail-bridge repo goes offline | Chart URL stops resolving | Currently disabled; plan local chart if ever re-enabled |

## Questions for User

1. **Deprecation urgency**: How urgently do you want to address the lgtm-distributed/promtail deprecation? Should we add a full migration phase, or is the research phase sufficient for now?
2. **Non-AH apps**: For apps not on Artifact Hub (fission, rancher, uptime, langfuse, prefect, windmill, openproject), do you have any known target versions, or should we just upgrade to whatever is latest?
3. **Disabled apps**: Should we skip upgrading disabled apps entirely and focus only on enabled ones?
