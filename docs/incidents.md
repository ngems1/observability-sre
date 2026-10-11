# Incident drills — evidence log

Seven failure drills on **dev**, each run from Actions → Ops with `environment: dev`.
Every run prints `injected/started at <UTC>` and `finished at <UTC>`, so the run log is the
timestamp source. Fill a row per drill, then write the full postmortem for drill 6 below.

## Ground rules

- **Load must be running.** Actions → Ops → `load-start` before the first drill, `load-stop` after
  the last one. Without traffic the SLIs are flat and the dashboard proves nothing.
- **One drill at a time.** Wait for the alert to resolve and the tiles to go green before injecting
  the next fault, otherwise two tiles are red and no screenshot says which fault caused which.
- **Recovery does not close the ticket.** Add the evidence and the postmortem, then resolve it.
- Alerts need their `for:` window to elapse. The wait column is inject → ticket, not inject → alert.

## Drills

| # | Action | Expected alert | Layer | Red tile | Wait | Recover with |
|---|---|---|---|---|---|---|
| 1 | `drill1-pod-kill` | none — probes + rollout self-heal | — | all green | ~1 min | automatic |
| 2a | `drill2-latency-on` | `OpsDeskApiLatencyHigh` (symptom) | slo | 2 Application | ~12 min | `drill2-latency-off` |
| 2b | `drill2-seed-1m-tickets` → `drill2-explain` | `OpsDeskDatabaseSlow` | database | 4 Database | ~7 min | `drill2-fix-index` |
| 3a | `drill3-stuck-queue-on` | `OpsDeskWorkerDown`, then `OpsDeskQueueBacklog` | kubernetes + queue | 1 then 3 | 2 min, 5 min | `drill3-stuck-queue-off` |
| 3b | `drill3-poison-message` | `OpsDeskDlqNotEmpty` | queue | 3 Queue | ~3 min | purge/redrive the DLQ |
| 4 | `drill4-pool-exhaustion-on` | `OpsDeskDbPoolExhausted` / `OpsDeskDatabaseErrors` | app / database | 2 or 4 | ~3 min | `drill4-pool-exhaustion-off` |
| 5 | `errors-on` | `OpsDeskErrorBudgetBurn` 14x (critical) | slo | 2 Application | ~3 min | `errors-off` |
| 6 | `drill6-network-block-db-on` | `OpsDeskDependencyUnreachable{postgres,connect_timeout}` | network | 5 Network | ~3 min | `drill6-network-block-db-off` |
| 7 | `drill7-noisy-neighbour-on` | none — ResourceQuota refuses the pods | — | all green | ~1 min | `drill7-noisy-neighbour-off` |

Drills 1 and 7 produce no alert **by design**, and that is the finding: the platform absorbed the
fault. Evidence is the workflow output (rollout status; `exceeded quota` events), not a ticket.

Drill 3a opens **two** tickets. Both are cause alerts, so neither is muted: the worker being down is
the cause, the backlog is its consequence. Screenshot both and say so in the postmortem.

## Evidence per drill

Four screenshots, saved as `docs/screenshots/drill<N>-<n>-<what>.png`:

1. `-1-alert.png` — the alert firing (Grafana → Alert rules, or Alertmanager), name and labels visible
2. `-2-dashboard.png` — **OpsDesk - Where is the fault?** over the alert window, red tile plus its row
3. `-3-ticket.png` — the OpsDesk ALERT ticket, **Suspected layer** visible
4. `-4-recovered.png` — tiles green and the ticket's "recovered after X" comment

Plus, per row: the two UTC timestamps and the Actions run URL.

## Log

All times UTC; the OpsDesk UI shows them in US/Eastern (UTC-4), so 15:06Z reads as 11:06 AM there.

| # | Fault | Injected | Alert fired | Ticket | Layer named | Recovered | Evidence |
|---|---|---|---|---|---|---|---|
| 6 | PostgreSQL unreachable (egress 5432 blocked) | 15:04 | 15:06:10 `OpsDeskDependencyUnreachable` | OPS-1821 | **network** | 15:23:40 (17 min 30 s) | `drill6-0..4` |
| 3a | ticket-worker scaled to 0 | 16:18 | 16:20 `OpsDeskWorkerDown` | OPS-13674 | **kubernetes** | 16:39 | `drill3-0..3` |
| 3a | backlog (consequence of the above) | — | 16:40 `OpsDeskQueueBacklog` | OPS-15858 | **queue** | — | `drill3-4` |
| 1 | API pod deleted | 16:41 | none — by design | — | — | < 1 min, automatic | `drill1-1`, `drills-overview-1h` |
| 2a | 800 ms latency injected | 16:56 | 17:06 `OpsDeskApiLatencyHigh` (suppressed) | — | — | 17:4x | `drill2a-1` |
| 2b, 3b, 4, 5, 7 | not run | | | | | | |

### What the alert ordering proves

Three alert conditions were true during drill 3a and drill 2a, and exactly one ticket existed at a time:

```
16:18  worker scaled to 0
16:20  OpsDeskWorkerDown fires           -> OPS-13674, layer kubernetes
16:20  OpsDeskQueueBacklog suppressed       (WorkerDown inhibits it)
16:39  worker restored, WorkerDown resolves
16:40  OpsDeskQueueBacklog now free       -> OPS-15858, layer queue
17:06  OpsDeskApiLatencyHigh suppressed     (QueueBacklog is a cause; symptoms are muted)
```

The inhibition rules in `terraform/platform/observability.tf` produced this: a cause mutes every symptom in its
namespace, and `OpsDeskWorkerDown` specifically mutes `OpsDeskQueueBacklog`. One fault, one ticket, one owner.

Each screenshot is presented with the claim it supports in [evidence.md](evidence.md).

## Findings from running the drills

Each of these was discovered by running a drill, not by reading the code.

**A NetworkPolicy does not bite while connection pools hold open connections.** Drill 6 produced no signal on its
first design: the policy blocks only NEW connections, and the API pods kept serving from their existing pool. Fixed
by restarting both workloads as part of the drill, so the new pods start with an empty pool and must reconnect.

**Unready pods leave Prometheus's scrape targets.** During drill 6 the error rate climbed, then fell back to zero
while the fault was still active — the pods reporting the errors had failed readiness and were no longer scraped.
The metric goes quiet exactly when the incident is worst.

**A self-hosted incident recorder cannot record its own outage.** Drill 6 took the ticket API down with the
database, so Alertmanager's webhook had nowhere to deliver. OpsDesk monitors OpsDesk, which works for every fault
except one that makes OpsDesk unavailable.

**Synthetic load buries real incidents.** The k6 load test writes into the same ticket queue, so the incident ticket
was several hundred rows down within minutes and had to be found by title search. Test traffic belongs in its own
queue — the same lesson as test notifications reaching a real Slack channel.

**A panel only ever seen healthy can be nonsense when broken.** *Seconds since the worker last polled* read
"63.4 years" with the worker scaled to zero, because the query subtracts a zero gauge from the current time.

---

## Postmortem — drill 6, PostgreSQL unreachable from the pods

Blameless: this describes what the system did and why it allowed it, not who did what. The fault was injected
on purpose; the findings were not expected.

**Summary.** For about 17 minutes the dev API pods could not open connections to PostgreSQL. The database was
healthy throughout. Alertmanager opened OPS-1821 naming the **network** layer, with no human judgement between the
fault and the ticket.

| | |
| --- | --- |
| **Environment** | dev (`opsdesk-dev`), under k6 load; prod unaffected (own namespace, RDS, queue, IAM) |
| **Severity** | critical (alert severity → ticket priority) |
| **Impact** | dev API returned 503 from the load balancer; ticket creation, approvals and comments failed; no data lost (all writes failed before commit, nothing half-written) |
| **Detection** | `OpsDeskDependencyUnreachable{dependency=postgres, kind=connect_timeout}`, `layer=network`, about 2 min after injection |
| **Duration** | 15:04 → 15:23:40 UTC, 17 min 30 s as measured by the platform (how long the fault was left running, not response time) |
| **Ticket** | OPS-1821, opened by Alertmanager, team Platform, runbook link attached |

### Timeline (UTC, 2026-10-11)

| Time | Event |
| --- | --- |
| 15:04 | `drill6-network-block-db-on`: port 5432 removed from the pods' egress NetworkPolicy, API and worker restarted |
| 15:04–15:06 | new pods cannot connect; `connect_timeout` climbs from 0 toward 380/min; readiness fails; ALB returns 503 |
| 15:06:10 | `OpsDeskDependencyUnreachable` fires; symptom alerts (`ErrorBudgetBurn`, `ApiLatencyHigh`) muted by inhibition |
| 15:06 | Alertmanager delivers to OpsDesk: OPS-1821, *Suspected layer: Network* |
| 15:23:40 | `drill6-network-block-db-off`; pods reconnect; alert resolves; "recovered after 17 min 30 s" written to the ticket |

> **Check before presenting:** OPS-1821 shows *Triage due 10:57:47 AM* (EDT), and critical tickets get 30 min,
> so the ticket appears to have been **created about 14:27 UTC**, before this run. The network-errors panel also
> shows two error bursts (around 14:20 and 15:05 UTC). Most likely an earlier drill 6 run opened OPS-1821 and this
> run re-fired onto the same open ticket (one open incident per alert fingerprint, by design). Confirm in Actions →
> Ops run history and correct the timeline: ticket created at ____, first injection at ____.

### Root cause

The egress NetworkPolicy no longer allowed TCP 5432 from the app pods to RDS. RDS answered normally throughout:
the **4 Database** tile stayed green (no statements completed, so no slow statements), while the **5 Network** tile
went red on `connect_timeout`. That pair is the whole finding.

### Why it was hard to diagnose

Every user-visible symptom pointed at the database: failed queries, unready pods, 503s. A dashboard built on
averages would have turned a database tile red and paged the database team. The distinguishing signal is the
*kind* of failure (`connect_timeout` rather than `query_timeout` or `too_many_connections`) and the database row
reporting *no data* rather than high latency.

### Resolution

`drill6-network-block-db-off` restored port 5432; new connections succeeded and the pods passed readiness.

### What went well

- The correct layer was named automatically, about 2 minutes after the fault.
- One ticket: symptom alerts stayed muted while the cause fired.
- Time to recover was measured and written to the ticket without anyone typing a number.

### What went badly (each found by running the drill, not by reading the code)

1. **The block did nothing at first.** A NetworkPolicy stops only *new* connections; pods kept serving from their
   existing pool. The drill now restarts both workloads after applying the policy.
2. **Metrics went quiet at the worst moment.** Pods that failed readiness dropped out of Prometheus's scrape
   targets, so the error rate fell back to zero while the fault was still active.
3. **OpsDesk could not reliably record its own outage.** The ticket API depends on the same database, so the
   Alertmanager webhook had nowhere to deliver while the fault lasted.

### Follow-ups

| # | Action | Owner | Due | Status |
| --- | --- | --- | --- | --- |
| 1 | Restart API and worker as part of `drill6-network-block-db-on` | Sebastien Ngembou | 2026-10-11 | done |
| 2 | Alert when an expected scrape target disappears (`up == 0` / absent target for opsdesk-api) | Sebastien Ngembou | 2026-10-18 | open |
| 3 | Send critical Alertmanager alerts to the SNS topic as well as OpsDesk (Alertmanager IRSA role with `sns:Publish`) | Sebastien Ngembou | 2026-10-18 | open |
| 4 | Confirm the ticket-creation time above from the Ops run history and correct the timeline | Sebastien Ngembou | before the presentation | open |

**Evidence:** `docs/screenshots/drill6-0-run-log.png` … `drill6-4-recovered-ttr.png`, Ops workflow run log
(injected / finished timestamps), ticket OPS-1821.
