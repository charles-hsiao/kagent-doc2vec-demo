# PostgreSQL Connection Issues Troubleshooting Runbook

**Scope:** production, staging  
**Maintainer:** SRE Team  
**Last Updated:** 2025-08-01

---

## Alert Mapping

| Alert Name | Trigger Condition | Severity |
|---------|---------|---------|
| `PostgresConnectionPoolExhausted` | Connections ≥ 90% of `max_connections` | SEV-2 |
| `PostgresConnectionHighLatency` | Connection establishment latency > 500ms for 5 minutes | SEV-3 |
| `PostgresIdleConnectionsHigh` | Idle connections > 50 for 10 minutes | SEV-3 |

---

## Quick Diagnosis (Complete Within 5 Minutes)

### Step 1: Confirm Pod Status

```bash
kubectl describe pod <pg-pod> -n production
kubectl logs <pg-pod> -n production --tail=100
```

### Step 2: Query Connection Status

Log into PostgreSQL:

```bash
kubectl exec -it <pg-pod> -n production -- psql -U postgres
```

Run diagnostic queries:

```sql
-- Check current connection limit and usage
SHOW max_connections;
SELECT count(*) AS total_connections FROM pg_stat_activity;

-- View connection distribution (grouped by state)
SELECT count(*), state, wait_event_type
FROM pg_stat_activity
GROUP BY state, wait_event_type
ORDER BY count DESC;

-- Find long-running idle connections (over 5 minutes)
SELECT pid, usename, application_name, state, query_start, state_change
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < NOW() - INTERVAL '5 minutes'
ORDER BY state_change;

-- Find queries waiting for locks
SELECT pid, usename, query, wait_event_type, wait_event
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
ORDER BY query_start;
```

### Step 3: Identify Problem Type

| Symptom | Diagnosis | Go To |
|------|------|------|
| Large number of idle connections (> 50) | Connection Leak | Action A |
| Normal connection count but slow queries | Lock Contention | Action B |
| Connections near limit, normal application usage | max_connections set too low | Action C |
| Sudden spike of connections late at night | Batch job not releasing connections | Action D |

---

## Emergency Actions

### Action A: Force Terminate Idle Connections (Connection Leak)

```sql
-- First confirm the list of connections to terminate
SELECT pid, usename, application_name, state_change
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < NOW() - INTERVAL '5 minutes'
  AND usename != 'postgres';

-- Execute termination after confirming
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < NOW() - INTERVAL '5 minutes'
  AND usename != 'postgres';
```

> ⚠️ Note: `pg_terminate_backend` will forcibly disconnect connections. Applications will receive errors and reconnect — confirm that the application has a retry mechanism.

### Action B: Resolve Lock Contention

```sql
-- Find the blocking query
SELECT
  blocking.pid AS blocking_pid,
  blocking.query AS blocking_query,
  blocked.pid AS blocked_pid,
  blocked.query AS blocked_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;

-- Cancel the blocking query (confirm it's safe to cancel first)
SELECT pg_cancel_backend(<blocking_pid>);
-- If cancel fails, force terminate
SELECT pg_terminate_backend(<blocking_pid>);
```

### Action C: Temporarily Increase max_connections

```sql
-- Check current setting
SHOW max_connections;
SHOW shared_buffers;

-- Temporarily increase (reload config, no restart needed)
ALTER SYSTEM SET max_connections = 200;
SELECT pg_reload_conf();

-- Confirm applied
SHOW max_connections;
```

> ⚠️ Note: Each connection consumes approximately 5–10MB of memory. Confirm the Pod's memory limit is sufficient before increasing.  
> Permanent changes must also be updated in Helm values or ConfigMap.

### Action D: Terminate Abnormal Batch Jobs

```bash
# Find Kubernetes Jobs
kubectl get jobs -n production

# Confirm if a backup or batch job is consuming many connections
kubectl describe job <job-name> -n production

# Force delete the Job (terminates connections)
kubectl delete job <job-name> -n production
```

---

## Confirm Recovery

```bash
# Confirm connection count has returned to normal
kubectl exec -it <pg-pod> -n production -- psql -U postgres \
  -c "SELECT count(*) FROM pg_stat_activity;"

# Confirm affected services have recovered
kubectl get pods -n production
kubectl logs deployment/<affected-service> -n production --tail=50 | grep -i error

# Confirm Prometheus alert has cleared (wait 1–2 scrape intervals)
```

---

## Common Causes Summary

| Cause | Symptom | Long-term Fix |
|------|------|------|
| Application connection leak | Idle connections accumulate and are not released | Fix code; add connection timeout settings |
| Backup job not releasing connections | Sudden exhaustion during late-night hours | Add `statement_timeout`, use short-lived connections |
| HPA scale-out causing connection spike | Connection count doubles in short period | Introduce PgBouncer connection pooler |
| `max_connections` set too low | Connection count persistently near limit | Evaluate and increase `max_connections` |
| Not using connection pool | Each app instance connects directly to DB | Introduce PgBouncer or application-layer connection pool |

---

## Escalation Criteria

Escalate immediately to SEV-1 and notify the DBA in the following situations:

- Connection count persistently fails to decrease and is affecting production transactions
- Database Pod enters OOMKilled or CrashLoopBackOff
- Replication lag > 30 seconds

---

## Related Resources

- **Grafana Dashboard:** `PostgreSQL Overview` (ID: 9628)
- **Related Post-Mortem:** `incident-2024-09-12-postgres-pool.md`
- **PgBouncer Setup Guide:** `runbooks/database/pgbouncer-setup.md`
- **Slack Channel:** `#oncall-db`
