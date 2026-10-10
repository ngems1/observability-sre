# Reading the evidence: what to look at, and what it proves

Companion to [incidents.md](incidents.md). For each drill: the panel, the number, and the one
sentence that screenshot supports.

## The idea that makes "before and after" easy

**A timeseries panel carries its own "before" inside one screenshot.** Set the Grafana time range
wide enough to include the healthy period, and the flat baseline to the left of the fault *is* the
"before". You do not need a separate screenshot taken earlier — you need a wide enough window.

So:

- **Graphs (every row panel): one screenshot each**, time range **last 1 hour**, taken during or just
  after the fault. The eye reads flat → broken → flat.
- **Verdict tiles: two screenshots.** Tiles are instantaneous — they show *now*, with no history. So
  take **one baseline shot of all five tiles green** at the start of the session, with load running,
  and reuse it as the "before" for every drill. Then one shot per drill with the red tile.

Grafana setup before you start: time range **last 1 hour**, auto-refresh **10s**, namespace variable
**opsdesk-dev**. Keep the legend visible in every screenshot — the series names are half the proof.

## Verdict tile thresholds (what "red" means)

| Tile | Measures | Red at |
|---|---|---|
| 1 Kubernetes | unavailable replicas + restarts (10 min) | ≥ 1 |
| 2 Application | 5xx ÷ all requests | > 0.5% |
| 3 Queue | main visible + DLQ visible | > 20 messages |
| 4 Database | statement time p99 | > 0.25 s |
| 5 Network | failed connections per minute | > 0.5 |
| Error budget left | 30 d budget against a 99.5% SLO | orange < 25%, red < 0 |

---

## Drill 1 — pod kill

**Panel:** *Ready pods by deployment*. Two series per deployment: `ready` and `wanted`.

**Before:** the two lines sit on top of each other (2 and 2).
**After:** `ready` dips to 1 for 30–60 s while `wanted` stays 2, then rejoins.

**The gap between the lines is the whole story.** Also check *Container restarts (10 min)*: it stays
at 0, which distinguishes "the pod was replaced" from "the container is crash-looping".

**Proves:** a pod died and the ReplicaSet replaced it in under a minute. No alert fired, because
`OpsDeskPodsUnavailable` requires 5 minutes of unavailability — the platform self-healed well inside
the alerting threshold. That is a pass, not a miss.

---

## Drill 2a — injected latency (800 ms)

**Panel:** *Request time vs database time (p95)*. Two series: `request p95`, `database statement p95`.

**Before:** both low and close together (request maybe 20–50 ms, database 5–10 ms).
**After:** `request p95` jumps to roughly 850 ms. **`database statement p95` does not move.**

**The divergence is the proof.** The widening gap between the two lines is time spent inside the
application — not waiting on PostgreSQL.

**Proves:** the application got slow on its own. The database was never involved.

**What will *not* move:** the *2 Application* verdict tile, because it measures the 5xx ratio and
injected latency produces no errors. A latency-only fault lights no tile; it surfaces as the
`OpsDeskApiLatencyHigh` symptom alert, and the request-vs-database panel is what localizes it. Say
this out loud rather than hiding it, and put "add p95 latency to the Application verdict tile" on
your next-steps slide.

---

## Drill 2b — 1M rows, missing index

**Panels:** *Statement time p99 by operation*, and the two workflow logs.

**Before:** every operation under ~10 ms; tile 4 green.
**After seeding:** the auto-assign SELECT climbs past 0.25 s; **tile 4 Database red**.
**After `drill2-fix-index`:** back under threshold within a couple of minutes.

**The strongest single pair of screenshots in the project** is the two `EXPLAIN` outputs from the
workflow logs:

- `drill2-explain` → `Seq Scan on tickets … rows=1000000 … actual time=…`
- `drill2-fix-index` → `Index Scan using ix_tickets_status_assignee … actual time=…`

Put the two execution times side by side.

**Proves:** the database was reachable and healthy but doing too much work per query; an index fixed
it. Root cause at the storage layer, not the app.

**Pair this with drill 2a on one slide.** Same user-visible symptom — "the app is slow" — and in 2a
only the request line rose while in 2b both rose together. Two screenshots, one argument: the model
tells apart two faults that look identical from outside.

---

## Drill 3a — worker scaled to zero

**Panel:** *SQS depth*. Series `main visible`, `main in_flight`, `dlq visible`.

**Before:** `main visible` hugs zero (the worker keeps up).
**After:** a straight diagonal climb. **The slope is the arrival rate** — about 5/s, so ~300/min.
Crossing 20 turns **tile 3 Queue red**.

**Panel:** *Seconds since the worker last polled*. This is the cleanest "the worker is gone" proof in
the dashboard. Before: a sawtooth between 0 and 10 s (the SQS long-poll wait). After: a straight
unbounded climb.

**After recovery:** the depth falls off a cliff; the slope of the drop is your drain rate. On
*Delivery outcome and time*, `sent /min` spikes during the drain, and `delivery p95 (s)` spikes high
then collapses — those are the messages that waited.

**Proves:** the queue decoupled the failure. The API kept accepting tickets and not one notification
was lost; they were delivered late instead. That is the resilience argument, and the recovery
screenshot is what makes it.

**What will *not* move:** the *1 Kubernetes* tile. `kubectl scale --replicas=0` sets *wanted* to 0 as
well, so nothing is "unavailable" and the tile stays green — which is exactly why
`OpsDeskWorkerDown` is written as `absent(up{...})` rather than a replica count. Worth saying: a
deployment scaled to zero is invisible to replica-based monitoring, and that is a trap in real
systems.

---

## Drill 3b — poison message

**Panel:** *SQS depth*, series `dlq visible`: 0 → 1.
**Panel:** *Delivery outcome and time*: a `poison` series appears, and `retried` ticks up three times
first (one per receive) before SQS gives up.

**Proves:** an unparseable message is retried a bounded number of times and then parked, instead of
blocking the queue behind it forever.

**What will *not* move:** tile 3, which needs more than 20 messages — one poison message won't reach
it. The evidence here is the `OpsDeskDlqNotEmpty` alert and its ticket, not the tile.

---

## Drill 4 — connection pool exhaustion

**Panel:** *Connection pool (all pods)*. Series `in_use`, `idle`, `overflow`, `size`.

**Before:** `in_use` low (1–2), `idle` around 4, `overflow` at 0.
**After:** 6 replicas × (20 + 10) = 180 requested connections against a `db.t3.micro` that allows
roughly 110. `in_use` pins to `size`, `overflow` maxes out, `idle` goes to zero.

**Panel:** *Database errors by kind* — watch which label appears, because it decides the layer:

- `pool_timeout` → the app's own pool is too small. **Layer: app config.** The database is fine.
- `too_many_connections` → PostgreSQL is refusing. **Layer: database.**

**Proves:** you can tell "we are queueing on our own connection pool" apart from "the database turned
us away", which call for opposite fixes — lower concurrency versus a bigger instance.

---

## Drill 5 — 20% error injection

**Panel:** *Requests and 5xx per second*. Before: `5xx` flat at zero. After: `5xx` rises to roughly a
fifth of `all`. **Tile 2 Application goes from ~0% to ~20%**, far past the 0.5% threshold — the most
dramatic tile movement of any drill, so make this your tile screenshot.

**Tile:** *Error budget left (30 d)* visibly drops.

**Panel:** *Errors by dependency and kind* stays flat — chaos failures are deliberately not
classified as dependency errors. **Panel:** *Request time vs database time* unchanged.

**Proves:** users are getting errors, nothing downstream is at fault, and the code itself is the
cause. The flat dependency panel is what rules out everything else.

---

## Drill 6 — PostgreSQL unreachable (the showpiece)

**Panel:** *Failed connections per minute*. A `postgres connect_timeout` series appears and climbs.
**Tile 5 Network red.**

**Panel:** *Statement time p99 by operation* — goes to **no data**. No statement completes, so there
is no statement time. **Tile 4 Database does not go red.** That is not a bug; it is the finding. A
slow database has high statement time, an unreachable one has none at all.

**Add one screenshot from outside Grafana:** AWS console → RDS → your dev instance → Monitoring,
covering the same window. CPU normal, connections dropping to zero, no errors. That is independent
proof, from AWS rather than from your own app, that the database was healthy throughout.

**Proves, in one sentence for the slide:** every symptom pointed at the database — the application
couldn't talk to it, requests failed — and the platform said *network*, which RDS's own metrics
confirm. A dashboard built on averages would have sent an engineer to the wrong team.

---

## Drill 7 — noisy neighbour

Mostly workflow-log evidence rather than Grafana.

**Before:** `kubectl describe resourcequota environment-quota` — `used` well under `hard`.
**After:** `used` pinned at `hard`, the deployment shows far fewer ready pods than the 30 requested,
and `FailedCreate` events read `exceeded quota`.

**The Grafana half, and the better evidence:** switch the dashboard's namespace variable to
**opsdesk-prod** over the same window and screenshot it unchanged — same requests per second, same
latency, all tiles green.

**Proves:** a runaway workload in dev was capped at its namespace boundary and prod never noticed.
That is the justification for running both environments on one cluster, which is also your biggest
cost saving — so this drill defends an architectural decision, not just a quota setting.

---

## Writing the caption

Every screenshot gets one sentence in `incidents.md` naming **the panel, the number, and the
conclusion**:

> `drill6-2-dashboard.png` — *Failed connections per minute*: `postgres connect_timeout` at 42/min
> from 15:04, while *Statement time p99* reports no data. The database is unreachable, not slow.

A screenshot without that sentence is decoration. With it, it's evidence.
