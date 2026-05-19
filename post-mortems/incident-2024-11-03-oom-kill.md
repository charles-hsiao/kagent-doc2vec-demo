# Incident Post-Mortem: api-gateway OOMKilled Cascading Failure

**Incident ID:** INC-2024-11-03  
**Severity:** SEV-1  
**Status:** Closed  
**Duration:** 1 hour 23 minutes (14:42 – 16:05)  
**Author:** Alice Chen (SRE)  
**Reviewer:** VP Engineering, SRE Team Lead  
**Last Updated:** 2024-11-07

---

## Summary

On 2024-11-03 at 14:42, all Pods of the `api-gateway` service successively entered CrashLoopBackOff due to memory limit exceeded (OOMKilled), triggering a cascading failure that caused request backlogs in `user-service` and `notification-service`, ultimately resulting in a 100% full-site outage lasting 1 hour and 23 minutes — the most severe SEV-1 incident in the past 18 months.

**Root Cause:** `api-gateway` v2.3.1 introduced a memory leak where Go goroutines were not properly terminated under high traffic, causing each Pod's memory to grow from 128MB to 512MB (exceeding the limit) within 40 minutes, triggering OOMKilled.

---

## Impact

| Metric | Value |
|------|------|
| Affected Users | All users (100% service outage) |
| Affected Services | api-gateway, user-service, notification-service |
| Failed Requests | ~480,000 |
| Peak Error Rate | 100% (14:51 – 15:40) |
| Estimated Revenue Loss | ~USD 18,500 |

---

## Timeline

| Time | Event |
|------|------|
| 13:15 | `api-gateway` v2.3.1 deployed to production (Blue/Green deploy) |
| 14:42 | Prometheus alert: `PodOOMKilled` (1st Pod) |
| 14:43 | PagerDuty notifies on-call SRE (Alice Chen) |
| 14:47 | Alice acknowledges alert but misjudges it as a sporadic OOM; no immediate action |
| 14:51 | 2nd and 3rd Pods OOMKilled in succession; service enters degraded state |
| 14:55 | All 6 api-gateway Pods enter CrashLoopBackOff |
| 14:57 | Service 100% down; Alice escalates to Team Lead (Max Liu) |
| 15:02 | Max joins; parallel investigation begins: confirmed as caused by v2.3.1 |
| 15:08 | Decision made to roll back to v2.3.0 |
| 15:10 | Executed `kubectl rollout undo deployment/api-gateway` |
| 15:14 | Rollback Pods begin starting |
| 15:21 | Some Pods Ready; error rate drops to 60% |
| 15:40 | All Pods Ready; error rate drops to 5% (backlogged requests draining) |
| 16:05 | Fully recovered; error rate < 0.1%; alerts cleared |

**MTTD (Detection Time):** 1 minute  
**MTTA (Initial Response):** 4 minutes  
**MTTR (Recovery Time):** 83 minutes

---

## 根本原因分析

### 技術原因

`api-gateway` v2.3.1 在處理 WebSocket 連線時，goroutine 在 client 斷線後未正確呼叫 `cancel()` 結束 context，導致 goroutine leak。

**有問題的程式碼（簡化）：**

```go
// 錯誤寫法
func handleWebSocket(w http.ResponseWriter, r *http.Request) {
    ctx, cancel := context.WithCancel(r.Context())
    // ❌ cancel 從未被呼叫，goroutine 永遠不會釋放
    
    go func() {
        // 這個 goroutine 在 client 斷線後仍然存活
        for {
            select {
            case msg := <-messageChan:
                sendToClient(ctx, msg)
            }
        }
    }()
}
```

在高流量下（每秒約 200 個 WebSocket 連線），goroutine 數量每分鐘增加約 400 個，持有的記憶體每分鐘增加約 8MB，在 40 分鐘內即達到 512MB limit。

### 為何未被 Staging 測試發現

1. Staging 環境的 WebSocket 測試流量極低（每秒 < 5 個連線），goroutine leak 的速度不明顯
2. 沒有針對 goroutine 數量或記憶體成長速率的告警
3. Blue/Green deploy 切換時，未等待足夠的「soak time」觀察記憶體趨勢

### 延誤處置原因

第一個 Pod OOMKilled 時（14:42），on-call SRE 判斷為「偶發性」，未立即採取行動。這導致了 9 分鐘的延誤，最終所有 Pod 陸續 OOMKilled。

**教訓：** `PodOOMKilled` 告警，尤其是在部署後數十分鐘內觸發的，應優先懷疑與最近部署相關，而非偶發性問題。

---

## Remediation Steps (For Future Reference)

1. Confirm it is OOMKilled causing CrashLoopBackOff:
   ```bash
   kubectl describe pod <pod-name> -n production | grep -A 5 "Last State"
   # Look for Exit Code: 137 = OOMKilled
   ```

2. **Immediately check recent deployment history**:
   ```bash
   kubectl rollout history deployment/<deploy-name> -n production
   ```

3. If the issue appeared within 1 hour after deployment, **prioritize rollback** rather than spending time on deep investigation:
   ```bash
   kubectl rollout undo deployment/<deploy-name> -n production
   kubectl rollout status deployment/<deploy-name> -n production
   ```

4. Temporarily increase memory limit (if current version must be maintained):
   ```bash
   kubectl patch deployment <deploy-name> -n production \
     --patch '{"spec":{"template":{"spec":{"containers":[{"name":"<container>","resources":{"limits":{"memory":"1Gi"}}}]}}}}'
   ```

**For detailed steps, see:** `runbooks/kubernetes/pod-crashloopbackoff.md`

---

## Action Items

| # | Action Item | Owner | Due Date | Status |
|---|---------|-------|---------|------|
| 1 | Fix api-gateway WebSocket goroutine leak (v2.3.2) | Backend Dev Team | 2024-11-10 | ✅ Done |
| 2 | Add Go goroutine count monitoring alert (> 10,000 for 5 minutes) | SRE Alice | 2024-11-12 | ✅ Done |
| 3 | Add memory growth rate alert (> 50% growth within 1 hour) | SRE Alice | 2024-11-12 | ✅ Done |
| 4 | Add 30-minute soak period to Blue/Green deploy; monitor memory trends before switching 100% traffic | SRE + DevOps | 2024-11-20 | ✅ Done |
| 5 | Update On-Call Runbook: OOMKilled alerts should first check recent deployments | SRE Team Lead | 2024-11-15 | ✅ Done |
| 6 | Add WebSocket load testing to staging (simulate 50% of production traffic) | QA Team | 2024-11-30 | 🔄 In Progress |
| 7 | Build Grafana memory trend Dashboard with automatic deployment event markers | SRE Alice | 2024-11-25 | ✅ Done |

---

## Lessons Learned

1. **OOMKilled after a deployment = roll back first, investigate later.** Don't spend time debugging during a service outage; restore the service first, then find the root cause.
2. **Goroutine / thread leaks are hard to detect in low-traffic environments.** Load testing near production traffic levels is required.
3. **Blue/Green deploy is not zero-risk.** Memory leaks take time to accumulate before triggering; a 30-minute soak period is necessary.
4. **When the first alert is not sporadic**, assume it is a real problem first, then disprove it. The judgment of "sporadic" requires evidence (such as recurring and self-resolving).

---

## Related Resources

- **Runbook:** `runbooks/kubernetes/pod-crashloopbackoff.md`
- **Fix PR:** github.com/company/api-gateway/pull/891 (v2.3.2)
- **Grafana Dashboard:** Kubernetes Pod Memory Trends
- **Slack thread:** #oncall-alerts (2024-11-03 14:43)
- **Post-incident All-Hands meeting notes:** Confluence > SRE > Post-Mortems > 2024-11-03
