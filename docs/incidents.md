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

| # | Injected (UTC) | Alert fired | Ticket | Recovered | TTR | Run URL | Screenshots |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | |
| 2a | | | | | | | |
| 2b | | | | | | | |
| 3a | | | | | | | |
| 3b | | | | | | | |
| 4 | | | | | | | |
| 5 | | | | | | | |
| 6 | | | | | | | |
| 7 | | | | | | | |

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
