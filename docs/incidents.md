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

The showpiece: the database is **healthy**, and the platform still says *network*. Every naive
dashboard blames the database here.

```
Impact:
Detection:     OpsDeskDependencyUnreachable{dependency=postgres,kind=connect_timeout}, layer network
               fired at:        ticket created at:        triaged at:
Root cause:    egress NetworkPolicy no longer allows 5432; RDS itself answered normally throughout
               (4 Database tile green, 5 Network tile red — that pair is the whole finding)
Resolution:    drill6-network-block-db-off restored port 5432; pods reconnected
Evidence:      docs/screenshots/drill6-*.png, trace id:        , run:
Follow-ups:    owner + due date
```
