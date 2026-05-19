# Pod CrashLoopBackOff Troubleshooting Runbook

**Scope:** production, staging  
**Maintainer:** SRE Team  
**Last Updated:** 2025-10-15

---

## Alert Mapping

| Alert Name | Trigger Condition | Severity |
|---------|---------|---------|
| `PodCrashLoopBackOff` | Pod restart count > 5 times/hour | SEV-2 |
| `PodRestartingHigh` | Pod restart count > 3 times/30 minutes | SEV-3 |

---

## Quick Diagnosis

### Step 1: Confirm Pod Status

```bash
# Find the problematic Pod
kubectl get pods -n <namespace> | grep -E "CrashLoopBackOff|Error|OOMKilled"

# View detailed status
kubectl describe pod <pod-name> -n <namespace>

# Focus on the latest events at the bottom of the Events section
```

### Step 2: View Recent Logs

```bash
# View current container logs
kubectl logs <pod-name> -n <namespace> --tail=100

# View logs from the previous crash (--previous is very important)
kubectl logs <pod-name> -n <namespace> --previous --tail=200
```

### Step 3: Determine Crash Cause

| Exit Code in `describe` | Meaning | Go To |
|--------------------------|------|------|
| `0` | Clean exit (design issue) | Action A |
| `1` | Application error | Check logs |
| `137` | OOMKilled (Out of Memory) | Action B |
| `139` | Segmentation Fault | Notify dev team |
| `143` | SIGTERM not handled properly | Action C |

---

## Emergency Actions

### Action A: Application Exits Immediately on Start (Exit Code 0 or 1)

Usually caused by configuration errors or missing environment variables.

```bash
# Confirm ConfigMap and Secret exist
kubectl get configmap -n <namespace>
kubectl get secret -n <namespace>

# Confirm Pod environment variables
kubectl exec <pod-name> -n <namespace> -- env | sort

# Confirm mounted Volumes are correct
kubectl describe pod <pod-name> -n <namespace> | grep -A 20 "Volumes:"

# Temporarily enter container for debugging (override entrypoint)
kubectl debug <pod-name> -n <namespace> --image=busybox --share-processes
```

### Action B: OOMKilled (Out of Memory)

```bash
# Confirm Pod resource limit settings
kubectl describe pod <pod-name> -n <namespace> | grep -A 10 "Limits:"

# View recent memory usage
kubectl top pod <pod-name> -n <namespace>

# Temporarily increase memory limit (modify Deployment)
kubectl set resources deployment/<deploy-name> -n <namespace> \
  --limits=memory=512Mi --requests=memory=256Mi

# Or patch directly
kubectl patch deployment <deploy-name> -n <namespace> \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"<container-name>","resources":{"limits":{"memory":"512Mi"}}}]}}}}'
```

> ⚠️ Long-term solution: profile application memory usage, tune HPA or VPA settings.

### Action C: SIGTERM Not Handled Properly (Graceful Shutdown Issues)

```bash
# Check terminationGracePeriodSeconds setting
kubectl describe pod <pod-name> -n <namespace> | grep "Termination Grace Period"

# Temporarily increase grace period (give the application more time to shut down)
kubectl patch deployment <deploy-name> -n <namespace> \
  --patch '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":60}}}}'
```

---

## Liveness / Readiness Probe Failures

CrashLoopBackOff is sometimes caused by misconfigured Probes.

```bash
# Check Probe configuration
kubectl describe pod <pod-name> -n <namespace> | grep -A 10 "Liveness\|Readiness"

# Manually test Probe endpoints
kubectl exec <pod-name> -n <namespace> -- curl -f http://localhost:<port>/health
kubectl exec <pod-name> -n <namespace> -- curl -f http://localhost:<port>/ready
```

Common fix: increase `initialDelaySeconds` or `failureThreshold` to give the application enough startup time.

---

## Emergency Rollback

If the issue was introduced by a recent deployment:

```bash
# View rollout history
kubectl rollout history deployment/<deploy-name> -n <namespace>

# Roll back to the previous version
kubectl rollout undo deployment/<deploy-name> -n <namespace>

# Roll back to a specific version
kubectl rollout undo deployment/<deploy-name> -n <namespace> --to-revision=<N>

# Confirm rollback status
kubectl rollout status deployment/<deploy-name> -n <namespace>
```

---

## Escalation Criteria

- Problem persists after rollback → Escalate to SEV-1, notify on-call manager
- Multiple services CrashLoopBackOff simultaneously → Suspect shared dependency failure (DB, Config Server)
- OOMKilled cannot be resolved by increasing limits → Notify dev team for memory analysis

---

## Related Resources

- **Related Post-Mortem:** `incident-2024-11-03-oom-kill.md`
- **Slack Channel:** `#oncall-k8s`
- **Grafana Dashboard:** `Kubernetes Pod Overview`
