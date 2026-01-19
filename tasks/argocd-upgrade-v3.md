# ArgoCD Staged Upgrade: v7.3.6 → v9.3.4

**Upgrade Strategy**: 5-Stage Incremental  
**Started**: ________________  
**Completed**: ________________  
**Executed By**: ________________

---

## Upgrade Progress

| Stage | Chart | App Version | Status | Date | Duration |
|-------|-------|-------------|--------|------|----------|
| **Current** | v7.3.6 | ~v2.11.x | ✅ Complete | - | - |
| **Stage 1** | v7.9.1 | v2.14.11 | ⏸️ Not Started | | |
| **Stage 2** | v8.0.0 | v3.0.0 | ⏸️ Not Started | | |
| **Stage 3** | v8.6.4 | v3.1.8 | ⏸️ Not Started | | |
| **Stage 4** | v9.0.0 | v3.1.8 | ⏸️ Not Started | | |
| **Stage 5** | v9.3.4 | v3.2.5 | ⏸️ Not Started | | |

**Legend**: ⏸️ Not Started | 🔄 In Progress | ✅ Complete | ❌ Failed | ↩️ Rolled Back

---

## Pre-Upgrade Preparation

**Date**: ________________

### Detection & Assessment
- [ ] Run detection script: `./tasks/detect-argocd-upgrade-impact.sh`
- [ ] Review all critical issues identified
- [ ] Review all warnings identified
- [ ] Document current ArgoCD version: ________________
- [ ] Document total applications count: ________________

**Detection Results**:
```
Critical Issues: ____
Warnings: ____
Status: ____
```

### Backup Creation
- [ ] Create backup directory: `mkdir -p argocd-backup-$(date +%Y%m%d-%H%M%S)`
- [ ] Backup Applications: `kubectl get applications -n argocd -o yaml > applications.yaml`
- [ ] Backup Projects: `kubectl get appprojects -n argocd -o yaml > projects.yaml`
- [ ] Backup argocd-cm: `kubectl get cm argocd-cm -n argocd -o yaml > argocd-cm.yaml`
- [ ] Backup argocd-rbac-cm: `kubectl get cm argocd-rbac-cm -n argocd -o yaml > argocd-rbac-cm.yaml`
- [ ] Backup argocd-cmd-params-cm: `kubectl get cm argocd-cmd-params-cm -n argocd -o yaml > argocd-cmd-params-cm.yaml`
- [ ] Backup Secrets: `kubectl get secrets -n argocd -o yaml > secrets.yaml`
- [ ] Backup Helm values: `helm get values argocd -n argocd > helm-values.yaml`
- [ ] Verify all backups are readable
- [ ] Document backup location: ________________

### Pre-Flight Checks
- [ ] All ArgoCD pods running: `kubectl get pods -n argocd`
- [ ] All applications healthy: `kubectl get applications -n argocd`
- [ ] No pending operations
- [ ] Cluster has sufficient resources
- [ ] Network connectivity verified
- [ ] Team notified of upgrade schedule

### Fix Critical Issues
- [ ] Remove null values: `find charts/ -name "values.yaml" -exec sed -i '/: null$/d' {} \;`
- [ ] Verify no null values remain: `find charts/ -name "values.yaml" -exec grep -l ": null" {} \;`
- [ ] Address any other critical issues from detection script

**Pre-Upgrade Checklist Complete**: ☐ Yes ☐ No  
**Approved to Proceed**: ☐ Yes ☐ No  
**Approved By**: ________________

---

## Stage 1: Upgrade to v7.9.1 (ArgoCD v2.14.11)

**Status**: ⏸️ Not Started  
**Started**: ________________  
**Completed**: ________________

### Overview
- **Breaking Changes**: Redis downgrade (7.4 → 7.2)
- **Risk Level**: LOW
- **Rollback**: Easy (git revert)

### Pre-Stage Checklist
- [ ] Review Stage 1 breaking changes
- [ ] Confirm backup exists
- [ ] All applications synced and healthy

### Execution Steps

#### 1. Update Chart Version
```bash
cd charts/argo-cd
sed -i 's/version: 7.3.6/version: 7.9.1/' Chart.yaml
```
- [ ] Chart.yaml updated
- [ ] Verified version in file: `cat Chart.yaml | grep version`

#### 2. Commit Changes
```bash
git add Chart.yaml
git commit -m "chore(argocd): upgrade to chart v7.9.1 (app v2.14.11) - Stage 1/5"
git push
```
- [ ] Changes committed
- [ ] Changes pushed to remote
- [ ] Commit hash: ________________

#### 3. Monitor Deployment
```bash
# Watch pods restart
kubectl get pods -n argocd -w
```
- [ ] Deployment started
- [ ] All pods restarted successfully
- [ ] No CrashLoopBackOff or errors

### Verification Steps

#### 1. Check ArgoCD Version
```bash
kubectl exec -n argocd deployment/argocd-server -- argocd version
```
- [ ] Server version: v2.14.11
- [ ] Client version matches

#### 2. Check Pod Status
```bash
kubectl get pods -n argocd
```
- [ ] argocd-server: Running
- [ ] argocd-repo-server: Running
- [ ] argocd-application-controller: Running
- [ ] argocd-redis: Running
- [ ] All pods ready (x/x)

#### 3. Check Applications
```bash
kubectl get applications -n argocd
```
- [ ] All applications visible
- [ ] All applications synced
- [ ] All applications healthy

#### 4. Check UI Access
```bash
curl -k https://argocd.gsingh.io/healthz
```
- [ ] UI accessible
- [ ] Can login successfully
- [ ] Applications visible in UI

#### 5. Check Logs for Errors
```bash
kubectl logs -n argocd deployment/argocd-server --tail=100
kubectl logs -n argocd deployment/argocd-repo-server --tail=100
kubectl logs -n argocd statefulset/argocd-application-controller --tail=100
```
- [ ] No critical errors in server logs
- [ ] No critical errors in repo-server logs
- [ ] No critical errors in controller logs

### Post-Stage Actions
- [ ] Monitor for 24-48 hours
- [ ] Check application sync cycles
- [ ] Verify no degraded performance
- [ ] Document any issues encountered

**Stage 1 Status**: ☐ Complete ☐ Failed ☐ Rolled Back  
**Issues Encountered**: ________________  
**Wait Period**: 24-48 hours before Stage 2

---

## Stage 2: Upgrade to v8.0.0 (ArgoCD v3.0.0) ⚠️ CRITICAL

**Status**: ⏸️ Not Started  
**Started**: ________________  
**Completed**: ________________

### Overview
- **Breaking Changes**: MAJOR - Logs RBAC, Annotation Tracking, Fine-Grained RBAC
- **Risk Level**: HIGH
- **Rollback**: Moderate (requires RBAC restore)

### Critical Breaking Changes
1. ⚠️ **Logs RBAC Enforcement** - Requires explicit `logs, get` permission
2. ⚠️ **Annotation-Based Tracking** - Default changed from labels to annotations
3. ⚠️ **Fine-Grained RBAC** - `update`/`delete` no longer apply to sub-resources
4. ⚠️ **Default Resource Exclusions** - Many resources excluded by default

### Pre-Stage Checklist
- [ ] Stage 1 completed successfully
- [ ] Waited 24-48 hours since Stage 1
- [ ] No issues from Stage 1
- [ ] All applications still healthy

### REQUIRED: Pre-Stage RBAC Configuration

**CRITICAL: Must be done BEFORE upgrading to v8.0.0**

#### 1. Create RBAC ConfigMap

Create file: `argocd-rbac-v3.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.csv: |
    # Global log viewer role (required for v3.0)
    p, role:global-log-viewer, logs, get, */*, allow
    
    # Example: Developer role with full permissions
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, */*, allow
    p, role:developer, applications, create, */*, allow
    p, role:developer, applications, update, */*, allow
    p, role:developer, applications, delete, */*, allow
    p, role:developer, logs, get, */*, allow
    p, role:developer, applications, update/*, */*, allow
    p, role:developer, applications, delete/*, */*, allow
    
    # Admin role (has everything)
    p, role:admin, *, *, *, allow
    
  policy.default: role:global-log-viewer
```

#### 2. Apply RBAC Configuration
```bash
kubectl apply -f argocd-rbac-v3.yaml
```
- [ ] RBAC ConfigMap created/updated
- [ ] Verified ConfigMap: `kubectl get cm argocd-rbac-cm -n argocd -o yaml`

#### 3. Test RBAC (Optional but Recommended)
```bash
# Test logs access
argocd app logs <app-name>
```
- [ ] Logs access working with new RBAC

### Execution Steps

#### 1. Update Chart Version
```bash
cd charts/argo-cd
sed -i 's/version: 7.9.1/version: 8.0.0/' Chart.yaml
```
- [ ] Chart.yaml updated
- [ ] Verified version in file: `cat Chart.yaml | grep version`

#### 2. Commit Changes
```bash
git add Chart.yaml
git commit -m "chore(argocd): upgrade to chart v8.0.0 (app v3.0.0) - Stage 2/5 - MAJOR VERSION"
git push
```
- [ ] Changes committed
- [ ] Changes pushed to remote
- [ ] Commit hash: ________________

#### 3. Monitor Deployment (CLOSELY)
```bash
# Watch pods restart
kubectl get pods -n argocd -w
```
- [ ] Deployment started
- [ ] All pods restarted successfully
- [ ] No CrashLoopBackOff or errors
- [ ] Monitor for at least 10 minutes

### Verification Steps

#### 1. Check ArgoCD Version
```bash
kubectl exec -n argocd deployment/argocd-server -- argocd version
```
- [ ] Server version: v3.0.0 or higher
- [ ] Client version matches

#### 2. Check Pod Status
```bash
kubectl get pods -n argocd
```
- [ ] argocd-server: Running
- [ ] argocd-repo-server: Running
- [ ] argocd-application-controller: Running
- [ ] argocd-redis: Running
- [ ] All pods ready (x/x)

#### 3. Check Applications
```bash
kubectl get applications -n argocd
```
- [ ] All applications visible
- [ ] Applications may show OutOfSync (expected)

#### 4. Test Logs Access (CRITICAL)
```bash
argocd app logs <app-name>
```
- [ ] Logs accessible (verifies RBAC working)
- [ ] No permission denied errors

#### 5. Test UI Access
```bash
curl -k https://argocd.gsingh.io/healthz
```
- [ ] UI accessible
- [ ] Can login successfully
- [ ] Applications visible in UI
- [ ] Logs tab visible in pod view

#### 6. Check Logs for Errors
```bash
kubectl logs -n argocd deployment/argocd-server --tail=100
kubectl logs -n argocd deployment/argocd-repo-server --tail=100
kubectl logs -n argocd statefulset/argocd-application-controller --tail=100
```
- [ ] No critical errors in server logs
- [ ] No critical errors in repo-server logs
- [ ] No critical errors in controller logs

### Post-Stage Actions (CRITICAL)

#### REQUIRED: Sync All Applications

**This is CRITICAL for annotation-based tracking to work properly**

```bash
# Option 1: Sync all at once
argocd app sync --all

# Option 2: Sync individually (safer)
for app in $(kubectl get applications -n argocd -o name | cut -d/ -f2); do
  echo "Syncing $app..."
  argocd app sync $app
  sleep 5
done
```

- [ ] All applications synced
- [ ] Verified all applications healthy: `kubectl get applications -n argocd`
- [ ] No orphaned resources detected

#### Verification After Sync
```bash
kubectl get applications -n argocd
```
- [ ] All applications: Synced
- [ ] All applications: Healthy
- [ ] No applications in Unknown state

#### Extended Monitoring
- [ ] Monitor for 48-72 hours (longer than other stages)
- [ ] Check application sync cycles
- [ ] Verify no degraded performance
- [ ] Verify no unexpected resource deletions
- [ ] Test fine-grained RBAC (update/delete resources)
- [ ] Document any issues encountered

**Stage 2 Status**: ☐ Complete ☐ Failed ☐ Rolled Back  
**Issues Encountered**: ________________  
**Wait Period**: 48-72 hours before Stage 3

---

## Stage 3: Upgrade to v8.6.4 (ArgoCD v3.1.8)

**Status**: ⏸️ Not Started  
**Started**: ________________  
**Completed**: ________________

### Overview
- **Breaking Changes**: Minor improvements, bug fixes
- **Risk Level**: LOW
- **Rollback**: Easy (git revert)

### Pre-Stage Checklist
- [ ] Stage 2 completed successfully
- [ ] Waited 48-72 hours since Stage 2
- [ ] All applications synced and healthy
- [ ] No issues from Stage 2

### Execution Steps

#### 1. Update Chart Version
```bash
cd charts/argo-cd
sed -i 's/version: 8.0.0/version: 8.6.4/' Chart.yaml
```
- [ ] Chart.yaml updated
- [ ] Verified version in file: `cat Chart.yaml | grep version`

#### 2. Commit Changes
```bash
git add Chart.yaml
git commit -m "chore(argocd): upgrade to chart v8.6.4 (app v3.1.8) - Stage 3/5"
git push
```
- [ ] Changes committed
- [ ] Changes pushed to remote
- [ ] Commit hash: ________________

#### 3. Monitor Deployment
```bash
kubectl get pods -n argocd -w
```
- [ ] Deployment started
- [ ] All pods restarted successfully
- [ ] No CrashLoopBackOff or errors

### Verification Steps

#### 1. Check ArgoCD Version
```bash
kubectl exec -n argocd deployment/argocd-server -- argocd version
```
- [ ] Server version: v3.1.8
- [ ] Client version matches

#### 2. Check Pod Status
```bash
kubectl get pods -n argocd
```
- [ ] All pods running and ready

#### 3. Check Applications
```bash
kubectl get applications -n argocd
```
- [ ] All applications synced
- [ ] All applications healthy

#### 4. Check UI Access
```bash
curl -k https://argocd.gsingh.io/healthz
```
- [ ] UI accessible
- [ ] Can login successfully

#### 5. Check Logs for Errors
```bash
kubectl logs -n argocd deployment/argocd-server --tail=100
```
- [ ] No critical errors

### Post-Stage Actions
- [ ] Monitor for 24-48 hours
- [ ] Verify no issues
- [ ] Document any issues encountered

**Stage 3 Status**: ☐ Complete ☐ Failed ☐ Rolled Back  
**Issues Encountered**: ________________  
**Wait Period**: 24-48 hours before Stage 4

---

## Stage 4: Upgrade to v9.0.0 (ArgoCD v3.1.8)

**Status**: ⏸️ Not Started  
**Started**: ________________  
**Completed**: ________________

### Overview
- **Breaking Changes**: Chart v9 - Removed `.Values.configs.params`, ApplicationSet policy change
- **Risk Level**: MEDIUM
- **Rollback**: Moderate

### Breaking Changes
1. **Removed `.Values.configs.params`** - Only `create` and `annotations` remain
2. **ApplicationSet Policy** - Default changed from `'sync'` to `""`

### Pre-Stage Checklist
- [ ] Stage 3 completed successfully
- [ ] Waited 24-48 hours since Stage 3
- [ ] All applications synced and healthy
- [ ] No issues from Stage 3

### Pre-Stage Checks

#### Check for Custom Params
```bash
kubectl get cm argocd-cm -n argocd -o yaml | grep -A 10 "configs.params"
```
- [ ] Checked for custom params
- [ ] Documented any custom params: ________________

#### Check ApplicationSets
```bash
kubectl get applicationsets -n argocd
```
- [ ] Checked ApplicationSets
- [ ] ApplicationSet count: ________________

### Execution Steps

#### 1. Update Chart Version
```bash
cd charts/argo-cd
sed -i 's/version: 8.6.4/version: 9.0.0/' Chart.yaml
```
- [ ] Chart.yaml updated
- [ ] Verified version in file: `cat Chart.yaml | grep version`

#### 2. Commit Changes
```bash
git add Chart.yaml
git commit -m "chore(argocd): upgrade to chart v9.0.0 (chart v9 breaking changes) - Stage 4/5"
git push
```
- [ ] Changes committed
- [ ] Changes pushed to remote
- [ ] Commit hash: ________________

#### 3. Monitor Deployment
```bash
kubectl get pods -n argocd -w
```
- [ ] Deployment started
- [ ] All pods restarted successfully
- [ ] No CrashLoopBackOff or errors

### Verification Steps

#### 1. Check ArgoCD Version
```bash
kubectl exec -n argocd deployment/argocd-server -- argocd version
```
- [ ] Server version: v3.1.8
- [ ] Client version matches

#### 2. Check Pod Status
```bash
kubectl get pods -n argocd
```
- [ ] All pods running and ready

#### 3. Check Applications
```bash
kubectl get applications -n argocd
```
- [ ] All applications synced
- [ ] All applications healthy

#### 4. Check ApplicationSets (if any)
```bash
kubectl get applicationsets -n argocd
```
- [ ] ApplicationSets working correctly
- [ ] No errors in ApplicationSet controller logs

#### 5. Check UI Access
```bash
curl -k https://argocd.gsingh.io/healthz
```
- [ ] UI accessible
- [ ] Can login successfully

#### 6. Check Logs for Errors
```bash
kubectl logs -n argocd deployment/argocd-server --tail=100
```
- [ ] No critical errors

### Post-Stage Actions
- [ ] Monitor for 24-48 hours
- [ ] Verify ApplicationSets working (if any)
- [ ] Verify no issues
- [ ] Document any issues encountered

**Stage 4 Status**: ☐ Complete ☐ Failed ☐ Rolled Back  
**Issues Encountered**: ________________  
**Wait Period**: 24-48 hours before Stage 5

---

## Stage 5: Upgrade to v9.3.4 (ArgoCD v3.2.5) - FINAL

**Status**: ⏸️ Not Started  
**Started**: ________________  
**Completed**: ________________

### Overview
- **Breaking Changes**: None (latest stable)
- **Risk Level**: LOW
- **Rollback**: Easy (git revert)

### Pre-Stage Checklist
- [ ] Stage 4 completed successfully
- [ ] Waited 24-48 hours since Stage 4
- [ ] All applications synced and healthy
- [ ] No issues from Stage 4

### Execution Steps

#### 1. Update Chart Version
```bash
cd charts/argo-cd
sed -i 's/version: 9.0.0/version: 9.3.4/' Chart.yaml
```
- [ ] Chart.yaml updated
- [ ] Verified version in file: `cat Chart.yaml | grep version`

#### 2. Commit Changes
```bash
git add Chart.yaml
git commit -m "chore(argocd): upgrade to chart v9.3.4 (app v3.2.5) - Stage 5/5 - FINAL"
git push
```
- [ ] Changes committed
- [ ] Changes pushed to remote
- [ ] Commit hash: ________________

#### 3. Monitor Deployment
```bash
kubectl get pods -n argocd -w
```
- [ ] Deployment started
- [ ] All pods restarted successfully
- [ ] No CrashLoopBackOff or errors

### Verification Steps

#### 1. Check ArgoCD Version
```bash
kubectl exec -n argocd deployment/argocd-server -- argocd version
```
- [ ] Server version: v3.2.5
- [ ] Client version matches

#### 2. Check Pod Status
```bash
kubectl get pods -n argocd
```
- [ ] All pods running and ready

#### 3. Check Applications
```bash
kubectl get applications -n argocd
```
- [ ] All applications synced
- [ ] All applications healthy

#### 4. Check UI Access
```bash
curl -k https://argocd.gsingh.io/healthz
```
- [ ] UI accessible
- [ ] Can login successfully

#### 5. Check Logs for Errors
```bash
kubectl logs -n argocd deployment/argocd-server --tail=100
```
- [ ] No critical errors

### Final Verification

#### Comprehensive Health Check
- [ ] All pods running: `kubectl get pods -n argocd`
- [ ] All applications synced: `kubectl get applications -n argocd`
- [ ] All applications healthy
- [ ] UI accessible and responsive
- [ ] Logs accessible in UI
- [ ] Can create/update/delete applications
- [ ] Can sync applications manually
- [ ] No errors in any component logs

#### Functional Testing
- [ ] Login to UI as admin
- [ ] Login to UI as regular user (if applicable)
- [ ] View application details
- [ ] View pod logs (verify RBAC)
- [ ] Sync an application manually
- [ ] View application resources
- [ ] Update an application (verify fine-grained RBAC)
- [ ] Delete a test resource (verify fine-grained RBAC)

#### Metrics & Monitoring
- [ ] Check Prometheus metrics available
- [ ] Verify `argocd_app_info` metric working
- [ ] Verify old metrics removed (`argocd_app_sync_status`, etc.)
- [ ] Update Grafana dashboards if needed
- [ ] Set up alerts for new metrics

### Post-Stage Actions
- [ ] Monitor for 7 days
- [ ] Verify long-term stability
- [ ] Update team documentation
- [ ] Update runbooks
- [ ] Archive upgrade logs
- [ ] Keep backups for 30 days
- [ ] Document lessons learned

**Stage 5 Status**: ☐ Complete ☐ Failed ☐ Rolled Back  
**Issues Encountered**: ________________

---

## Upgrade Complete! 🎉

**Upgrade Completed**: ________________  
**Total Duration**: ________________  
**Final Version**: ArgoCD v3.2.5 (Chart v9.3.4)

### Final Checklist
- [ ] All 5 stages completed successfully
- [ ] All applications healthy and synced
- [ ] No critical issues outstanding
- [ ] Team notified of completion
- [ ] Documentation updated
- [ ] Backups archived

### Post-Upgrade Cleanup
- [ ] Remove old backups after 30 days
- [ ] Update monitoring dashboards
- [ ] Update team runbooks
- [ ] Schedule post-mortem meeting (if issues occurred)

**Sign-Off**: ________________  
**Date**: ________________

---

## Rollback Procedures

### Quick Rollback (Git Revert)

```bash
cd charts/argo-cd
git revert HEAD
git push
# Wait for ArgoCD to sync
kubectl get pods -n argocd -w
```

### Rollback to Specific Stage

```bash
cd charts/argo-cd

# Rollback to Stage 4 (v9.0.0)
sed -i 's/version: 9.3.4/version: 9.0.0/' Chart.yaml

# Rollback to Stage 3 (v8.6.4)
sed -i 's/version: 9.3.4/version: 8.6.4/' Chart.yaml

# Rollback to Stage 2 (v8.0.0)
sed -i 's/version: 9.3.4/version: 8.0.0/' Chart.yaml

# Rollback to Stage 1 (v7.9.1)
sed -i 's/version: 9.3.4/version: 7.9.1/' Chart.yaml

# Rollback to original (v7.3.6)
sed -i 's/version: 9.3.4/version: 7.3.6/' Chart.yaml

git commit -am "rollback(argocd): revert to v<version>"
git push
```

### Full Restore from Backup

```bash
cd argocd-backup-YYYYMMDD-HHMMSS

# Restore ConfigMaps
kubectl apply -f argocd-cm.yaml
kubectl apply -f argocd-rbac-cm.yaml
kubectl apply -f argocd-cmd-params-cm.yaml

# Restore Applications (if needed)
kubectl apply -f applications.yaml

# Restart ArgoCD components
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart statefulset/argocd-application-controller -n argocd

# Verify
kubectl get pods -n argocd
kubectl get applications -n argocd
```

**Rollback Executed**: ☐ Yes ☐ No  
**Rollback Date**: ________________  
**Rollback Reason**: ________________  
**Rolled Back To**: ________________

---

## Monitoring Commands

### During Each Stage

```bash
# Watch pods
kubectl get pods -n argocd -w

# Watch applications
watch kubectl get applications -n argocd

# Follow server logs
kubectl logs -n argocd deployment/argocd-server -f

# Check events
kubectl get events -n argocd --sort-by='.lastTimestamp' | tail -20
```

### Health Checks

```bash
# Quick health check
kubectl get pods -n argocd && kubectl get applications -n argocd

# Detailed health check
kubectl describe pods -n argocd
kubectl describe applications -n argocd

# Check resource usage
kubectl top pods -n argocd
```

---

## Issue Tracking

### Issues Log

| Stage | Issue | Severity | Resolution | Time to Resolve |
|-------|-------|----------|------------|-----------------|
| | | ☐ Critical ☐ High ☐ Medium ☐ Low | | |
| | | ☐ Critical ☐ High ☐ Medium ☐ Low | | |
| | | ☐ Critical ☐ High ☐ Medium ☐ Low | | |
| | | ☐ Critical ☐ High ☐ Medium ☐ Low | | |

### Lessons Learned

1. ________________
2. ________________
3. ________________
4. ________________
5. ________________

---

## References

- [ArgoCD v2.14 to v3.0 Upgrade Guide](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/)
- [ArgoCD v3.0 Release Blog](https://blog.argoproj.io/argo-cd-v3-0-release-candidate-a0b933f4e58f)
- [Helm Chart Changelog](https://artifacthub.io/packages/helm/argo/argo-cd?modal=changelog)
- [Detection Script](./detect-argocd-upgrade-impact.sh)

---

**Document Version**: 1.0  
**Last Updated**: 2026-01-18
