# SRE On-Call Onboarding Guide

**Audience:** Engineers joining the on-call rotation for the first time  
**Maintainer:** SRE Team Lead  
**Last Updated:** 2025-11-01

---

## Welcome to the On-Call Rotation

Congratulations on joining the on-call rotation! This guide will walk you through the basic processes, tools, and resources so you're prepared before your first shift.

> 💡 **First shift recommendation:** Shadow a senior colleague for at least one week before going on-call independently.

---

## Required Reading Checklist

Before your first shift, confirm you have read the following documents:

| Document | Path | Priority |
|------|------|------|
| Incident Response Process | `runbooks/oncall/incident-response-process.md` | ⭐⭐⭐ Required |
| PostgreSQL Troubleshooting | `runbooks/database/postgres-connection.md` | ⭐⭐⭐ Required |
| Pod CrashLoopBackOff | `runbooks/kubernetes/pod-crashloopbackoff.md` | ⭐⭐⭐ Required |
| Historical Incident Post-Mortems | `post-mortems/` directory | ⭐⭐ Recommended |

---

## Access Verification

Before going on-call, confirm you have access to the following systems:

```bash
# Confirm kubectl can connect to the production cluster
kubectl get nodes --context=prod-cluster

# Confirm Grafana login access
open https://grafana.internal.company.com

# Confirm PagerDuty setup (phone notifications)
# Go to https://company.pagerduty.com to configure notification preferences

# Confirm you have joined the following Slack channels
# - #oncall-alerts   (alert notifications)
# - #oncall-k8s      (Kubernetes related)
# - #oncall-db       (database related)
# - #oncall-handoff  (handoff logs)
```

---

## Alert Response SLA

| Severity | Description | Initial Response Time | Escalation Time |
|---------|------|------------|------|
| **SEV-1** | Complete production service outage | **5 minutes** | 15 minutes |
| **SEV-2** | Partial production service degradation | **15 minutes** | 30 minutes |
| **SEV-3** | Minor issues, no user impact | **1 hour** | Within business hours |
| **SEV-4** | Informational alerts | Within business hours | N/A |

---

## Alert Response Process (Quick Version)

1. **Acknowledge the alert** → Click Acknowledge in PagerDuty (lets the system know someone is handling it)
2. **Go to Slack** → Update status in `#oncall-alerts`: `Investigating [alert name]`
3. **Find the Runbook** → Locate the troubleshooting document based on the alert name
4. **Begin troubleshooting** → Follow the Runbook steps
5. **Unable to resolve** → Follow the escalation process to notify the next level (see "Escalation Contacts" below)
6. **Post-incident documentation** → Fill in the Incident Report and update the post-mortem (required for SEV-1/SEV-2)

---

## Quick Command Reference

```bash
# View all problematic Pods across production namespaces
kubectl get pods -A | grep -E "Error|CrashLoop|OOMKilled|Pending"

# View Kubernetes Events from the past 1 hour (sorted by time)
kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -50

# Quickly view status of all resources in a namespace
kubectl get all -n <namespace>

# Enter a debug container (without disrupting the original Pod)
kubectl debug <pod-name> -n <namespace> --image=busybox -it

# View HPA status
kubectl get hpa -n <namespace>

# View Ingress configuration
kubectl get ingress -A
```

---

## Escalation Contacts

| Role | Contact Method | When to Use |
|------|---------|------|
| SRE Team Lead | PagerDuty escalation / Slack DM | SEV-1 unresolved after 15 minutes |
| DBA On-Call | `#oncall-db` @ DBA | Database issues that cannot be resolved quickly |
| Dev Team On-Call | PagerDuty service escalation | Application bug causing SEV-1/2 |
| VP Engineering | SEV-1 only, after 30 minutes | Notified by Team Lead |

---

## Shift Handoff Process

Before the end of each shift (Sunday 18:00), post a handoff log in the `#oncall-handoff` channel:

```
📋 On-Call Handoff Log [Date]

Shift Period: [Start Time] ~ [End Time]

[Alerts Handled]
- [Alert Name] @ [Time]: [Summary and Resolution]
- (No alerts)

[Items to Follow Up]
- [Description] → Ticket: [Link]

[Notes for Next Person]
- [Any special situations or items to be aware of]
```

---

## FAQ

**Q: I'm not sure how to handle an alert. Can I wait?**  
A: No. Within the SLA window, you must Acknowledge and begin initial investigation. You can ask colleagues on Slack at the same time. When in doubt, escalate early.

**Q: What if I accidentally make a mistake?**  
A: Immediately explain what happened in `#oncall-alerts` and notify the Team Lead. Mistakes are not a big deal — hiding them is.

**Q: Can I sleep during my shift?**  
A: Yes, but your phone must have notifications enabled. PagerDuty's phone alert will automatically escalate if you don't respond within 5 minutes.

---

## Related Resources

- **Grafana:** https://grafana.internal.company.com
- **PagerDuty:** https://company.pagerduty.com
- **Kubernetes Dashboard:** https://k8s-dashboard.internal.company.com
- **All Runbooks:** `runbooks/` directory
- **Historical Post-Mortems:** `post-mortems/` directory
