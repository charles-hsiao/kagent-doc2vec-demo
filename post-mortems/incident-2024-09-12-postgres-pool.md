# Incident Post-Mortem: PostgreSQL Connection Pool Exhaustion

**Incident ID:** INC-2024-09-12  
**Severity:** SEV-2  
**Status:** Closed  
**Duration:** 47 minutes (03:17 – 04:04)  
**Author:** Charlie Wang (SRE)  
**Reviewer:** SRE Team Lead  
**Last Updated:** 2024-09-15

---

## Summary

On 2024-09-12 at 03:17, the production PostgreSQL connection pool was exhausted, causing `api-gateway`, `user-service`, and `payment-service` to return HTTP 503. The impact affected 35% of user requests. The incident lasted 47 minutes and was fully resolved at 04:04.

**Root Cause:** The scheduled backup job (`pg-backup-job`), which started at 03:00, lacked proper connection release logic, causing the connection pool to be exhausted within 17 minutes.

---

## Impact

| Metric | Value |
|------|------|
| Affected Users | ~8,400 (~35% of active users) |
| Affected Services | api-gateway, user-service, payment-service |
| Failed Requests | ~21,000 |
| Peak Error Rate | 89% (peak at 03:28) |
| Estimated Revenue Loss | ~USD 1,200 (payment-service unable to process transactions) |

---

## Timeline

| Time | Event |
|------|------|
| 03:00 | `pg-backup-job` CronJob starts on schedule |
| 03:17 | Prometheus alert fires: `PostgresConnectionPoolExhausted` (connections at 98/100) |
| 03:19 | PagerDuty notifies on-call SRE (Charlie Wang) |
| 03:24 | Charlie acknowledges alert, posts initial investigation update in #oncall-alerts |
| 03:28 | Confirmed all three services returning 503; connections at 100/100 |
| 03:35 | Large number of idle connections from `pg_backup_job` discovered via `pg_stat_activity` |
| 03:40 | Backup job confirmed as root cause |
| 03:43 | Executed `kubectl delete job pg-backup-job` to forcibly terminate the backup job |
| 03:45 | Executed `pg_terminate_backend` to forcibly terminate remaining idle connections |
| 03:47 | Connection count begins to drop (72/100) |
| 03:51 | Services begin recovering, error rate drops to 15% |
| 04:04 | Fully recovered, error rate returns to baseline (< 0.1%) |
| 04:06 | Alert cleared, PagerDuty resolved |

---

## Root Cause Analysis

### Technical Cause

`pg-backup-job` used a Python script to connect to PostgreSQL for data export, but the code did not properly call `connection.close()` after establishing a connection, nor did it use a context manager (`with` statement) to ensure connection release.

**Problematic code snippet (simplified):**

```python
# Incorrect: connection not closed
def backup_table(table_name):
    conn = psycopg2.connect(DSN)
    cursor = conn.cursor()
    cursor.execute(f"SELECT * FROM {table_name}")
    rows = cursor.fetchall()
    write_to_s3(rows)
    # ❌ Missing conn.close() or context manager
```

The backup script ran in parallel against 12 tables, accumulating 100 unreleased connections within 17 minutes, exhausting the entire connection pool.

### Why It Was Not Caught Earlier

1. `pg-backup-job` was created by the dev team 3 months prior without an SRE code review
2. During staging testing, the issue was not observed because staging's `max_connections` was set to 500
3. There was no early-warning alert for idle connection count

---

## Remediation Steps (For Future Reference)

1. Check Prometheus alert content, log into the Grafana `PostgreSQL Overview` Dashboard
2. Run `kubectl describe pod <pg-pod>` to confirm Pod status
3. Log into PostgreSQL and run diagnostic queries:
   ```sql
   SELECT count(*), state, application_name
   FROM pg_stat_activity
   GROUP BY state, application_name
   ORDER BY count DESC;
   ```
4. If large number of idle connections found from a specific `application_name` → locate the corresponding Kubernetes Job/Deployment
5. Force terminate the problem source: `kubectl delete job <job-name> -n production`
6. Force terminate remaining connections:
   ```sql
   SELECT pg_terminate_backend(pid)
   FROM pg_stat_activity
   WHERE state = 'idle'
     AND application_name = '<problematic_app>'
     AND state_change < NOW() - INTERVAL '2 minutes';
   ```
7. Monitor connection count decrease and confirm service recovery

**For detailed steps, see:** `runbooks/database/postgres-connection.md`

---

## Action Items

| # | Action Item | Owner | Due Date | Status |
|---|---------|-------|---------|------|
| 1 | Fix `pg-backup-job` connection management code (add context manager + connection.close) | Backend Dev Team | 2024-09-19 | ✅ Done |
| 2 | Add `PostgresIdleConnectionsHigh` alert (idle connections > 30 for 5 minutes) | SRE Charlie | 2024-09-20 | ✅ Done |
| 3 | Create Grafana `pg_stat_activity` detailed Dashboard | SRE Alice | 2024-09-25 | ✅ Done |
| 4 | Add SRE Code Review process for all Jobs/CronJobs that directly connect to PostgreSQL | SRE Team Lead | 2024-10-01 | ✅ Done |
| 5 | Evaluate introducing PgBouncer as connection pooler | SRE + DBA | 2024-10-31 | 🔄 In Progress |
| 6 | Update staging environment `max_connections` to match production (100) | Infra Team | 2024-09-26 | ✅ Done |

---

## Lessons Learned

1. **Staging and production configuration mismatch** was the key reason the issue was not caught earlier. Critical resource limits (such as max_connections) should match production.
2. **Third-party jobs connecting directly to the DB** should be included in the SRE review process to ensure proper connection management.
3. **Multi-tier alerting** is important: in addition to "exhausted" alerts, "near-exhaustion" pre-warning alerts are needed (e.g., > 80%).
4. Use `application_name` in PostgreSQL connection strings to tag the source for faster diagnosis:
   ```python
   psycopg2.connect(f"{DSN} application_name=pg_backup_job")
   ```

---

## Related Resources

- **Runbook:** `runbooks/database/postgres-connection.md`
- **Grafana Dashboard:** PostgreSQL Overview (ID: 9628)
- **Fix PR:** github.com/company/backend/pull/4521
- **Slack thread:** #oncall-alerts (2024-09-12 03:19)
