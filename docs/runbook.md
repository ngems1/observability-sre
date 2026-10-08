# OpsDesk runbook

On-call guide for the alerts that open incident tickets. Every alert links to its section here (`runbook_url`) and
names the **layer** it points at: Kubernetes, application, queue, database or network.

## Find the layer first (2 minutes)

1. Open the ticket (UI → *Open* tab, badge **ALERT**). The alert card shows **Suspected layer**. Assign it to
   yourself and move it to *Triaged* within the SLA shown on the ticket.
2. Open Grafana → **OpsDesk - Where is the fault?** for the alert window. Read the five verdict tiles left to right:
   the red tile is the layer; its row below shows the detail on the same time axis.
3. Confirm with one trace: on *Request time vs database time*, click an exemplar dot → the slow or failing span in
   Tempo shows which call broke.
4. Go to the section for that alert below.

| Signal | Layer | Typical cause |
| --- | --- | --- |
| Pods unavailable, restarts, worker absent | Kubernetes | crash loop, image pull, probe failure, scaled to 0, no node capacity |
| 5xx or latency high, database time normal, no dependency errors | Application | bad release, code path, CPU starvation, chaos switch |
| Messages piling up in SQS, DLQ not empty | Queue | worker slow or stopped, poison messages |
| Database time high, `too_many_connections`, `query_timeout` | Database | missing index, locks, connection limit |
| `connect_timeout`, `dns`, `refused`, `connection_lost` errors | Network | NetworkPolicy, security group, NACL, route, DNS, dependency endpoint down |
| `pool_timeout` errors, database time normal | Application config | connection pool too small for the load |

### How alerts become tickets

```
Prometheus rule fires (for: 1-15 min)
  -> Alertmanager: routes critical, and warnings with a team label; mutes symptoms while a cause fires
  -> POST /integrations/alertmanager (bearer token)
  -> OpsDesk opens an "Incident follow-up" ticket: priority from severity, team from labels.team,
     "Suspected layer" from labels.layer, auto-assigned, notification via SQS -> worker
  -> alert resolves -> comment "recovered after X" + opsdesk_incident_time_to_recover_seconds
```

- **Causes beat symptoms.** Alerts are either a *cause* (one layer) or a *symptom* (`OpsDeskErrorBudgetBurn`,
  `OpsDeskApiLatencyHigh`: users are affected, layer unknown). While any cause alert fires, Alertmanager mutes the
  symptoms, so the ticket you get names the layer. A symptom ticket on its own means: no layer alert matched — use
  the dashboard. Pods made unready by an unreachable dependency do not open a second ticket either.
- **Repeats are no-ops.** One alert fingerprint maps to one open incident; a re-fire while the ticket is open adds a
  comment. Recovery does not close the ticket: add evidence and the postmortem, then resolve it.
- **Drills do not break the pipeline.** Chaos switches skip `/integrations/*`.

---

## Symptoms

### OpsDeskErrorBudgetBurn

**Meaning.** Requests fail fast enough to spend the 30-day error budget of the availability SLO (99.5 %) far too
early. *Fast* (critical): 14.4x the allowed rate over 1 h and 5 min — the whole budget would be gone in about 2 days.
*Slow* (warning): 6x over 6 h and 30 min. Users are affected; the layer is not known yet.

**Do.** Follow *Find the layer first*. If every verdict tile except Application is green, the fault is in the app:

| Cause | Fix |
| --- | --- |
| Error injection (`errors-on`) | Actions → Ops → `errors-off` |
| Bad release | Actions → Ops → `rollback` (Release already rolls back when its smoke test fails) |
| Code bug in one route | *Errors by dependency and kind* is empty → read the `unhandled error` logs (CloudWatch Logs Insights `opsdesk-demo/errors-last-hour`) |

### OpsDeskApiLatencyHigh

**Meaning.** p95 latency of ticket-api above 500 ms for 10 minutes.

**Do.** *Request time vs database time*: request slow and database slow → **database** (see OpsDeskDatabaseSlow);
request slow and database fast → **application** (`drill2-latency-off` if injected; CPU throttling on the
*CPU used vs requested* panel → raise requests or replicas).

---

## Kubernetes

### OpsDeskWorkerDown

**Meaning.** No ticket-worker pod has been up for 2 minutes. Notifications queue up in SQS; the API keeps working.

```bash
kubectl -n opsdesk get deploy,pods -l app.kubernetes.io/component=worker
kubectl -n opsdesk describe pod -l app.kubernetes.io/component=worker | tail -20
```

| Cause | Fix |
| --- | --- |
| Scaled to 0 (drill 3) | Actions → Ops → `drill3-stuck-queue-off` |
| CrashLoopBackOff after a deploy | Actions → Ops → `rollback` |
| `CreateContainerConfigError` | ExternalSecret not synced: Ops → `status` |

**Verify.** *SQS depth* drains to ~0; queued notifications on recent tickets turn `sent`.

### OpsDeskPodsUnavailable

**Meaning.** An OpsDesk deployment has had unready pods for 5 minutes.
`kubectl -n opsdesk describe pod <pod>` → *Events*: `ImagePullBackOff` (tag / ECR access), `CrashLoopBackOff`
(`kubectl logs --previous`), `Insufficient cpu` (Cluster Autoscaler, node group max), readiness failing (`/readyz`
returns 503 when the database is unreachable — then the network or database alert is the real incident).

---

## Network

### OpsDeskDependencyUnreachable

**Meaning.** Pods cannot open connections to PostgreSQL, SQS or Slack. The `kind` label says how:

| kind | What it means | Check |
| --- | --- | --- |
| `connect_timeout` | packets dropped, no answer | NetworkPolicy egress ports (`kubectl -n opsdesk get networkpolicy opsdesk-egress -o yaml`), RDS security group, NACL, route table / NAT |
| `dns` | name does not resolve | CoreDNS panel (SERVFAIL), the endpoint name in the secret |
| `refused` | host reachable, nothing listening | dependency down or wrong port (RDS status in the console) |
| `connection_lost` | connection dropped mid-request | RDS failover/reboot, idle timeouts |

Drill 6 (`drill6-network-block-db-on`) removes port 5432 from the egress NetworkPolicy: the database stays healthy,
and this alert fires with `dependency=postgres, kind=connect_timeout`. Fix: `drill6-network-block-db-off`.

**Verify.** *Failed connections per minute* back to 0; pods ready again.

---

## Database

### OpsDeskDatabaseSlow

**Meaning.** p99 time inside PostgreSQL above 250 ms for 5 minutes.
Actions → Ops → `drill2-explain`: a `Seq Scan` on `tickets` = missing index → `drill2-fix-index`, then codify it as
an Alembic migration. Otherwise RDS console → Monitoring (CPU, read IOPS) and locks in `pg_stat_activity`.

### OpsDeskDatabaseErrors

**Meaning.** PostgreSQL is reachable but rejects requests.
`too_many_connections`: replicas × (pool size + overflow) exceeds `max_connections` (drill 4) → `drill4-pool-exhaustion-off`.
`auth`: the DB credentials in the secret are wrong or rotated → check the ExternalSecret sync.
`query_timeout`: statements cancelled → see OpsDeskDatabaseSlow.

### OpsDeskDbPoolExhausted

**Meaning.** Requests waited for a free connection from the app's own pool and timed out, while the database answers
normally. This is **app configuration**, not the database: raise `OPSDESK_DB_POOL_SIZE` / `OPSDESK_DB_MAX_OVERFLOW`
within the RDS connection limit, or add replicas.

---

## Queue

### OpsDeskQueueBacklog

**Meaning.** More than 20 notifications waiting in SQS for 5 minutes while the worker is running (a stopped worker
raises OpsDeskWorkerDown instead). Check *Delivery outcome and time*: `retried` rising = Slack or the database failing
for the worker (see *Errors by dependency and kind*); otherwise scale the worker.

### OpsDeskDlqNotEmpty

**Meaning.** A message failed 3 deliveries or could not be parsed (drill 3 poison message). AWS console → SQS →
`opsdesk-notifications-dlq` → *Send and receive messages* → *Poll*. The matching notification row is `failed` with
`last_error`. Fix the cause, then *Start DLQ redrive* for valid messages; delete poison messages.

---

## Postmortem template (paste into the ticket)

```
Impact:        who/what was affected, for how long (time to recover from the alert card)
Detection:     alert name, layer, fired at, ticket created at, triaged at
Root cause:
Resolution:
Evidence:      fault-domain dashboard screenshot, trace id, workflow run link
Follow-ups:    owner + due date for each
```
