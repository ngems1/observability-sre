# OpsDesk — telecom observability & SRE platform on EKS

When a telecom service degrades, the expensive part is not fixing it. It is working out **which layer broke** —
Kubernetes, the application, the queue, the database or the network — while three teams each look at a dashboard
that says their own layer is fine.

OpsDesk answers that question automatically. Every layer is instrumented with a signal only that layer can move, so
an incident ticket arrives naming the failing layer **before anyone joins a call**.

Then the platform is broken on purpose, repeatedly, to check the name it gives is the right one.

![Incident ticket naming the network layer](docs/screenshots/drill6-3-ticket-network.png)

*The application could not reach PostgreSQL. Every user-visible symptom said "database" — failing queries, unhealthy
pods, a 503 from the load balancer. RDS was healthy throughout. The platform said **network**, unprompted, two
minutes after the fault. [Full evidence →](docs/evidence.md)*

---

## The idea

Five layers, each with a question only it can answer:

| Layer | The question | The signal |
| --- | --- | --- |
| Kubernetes | Are the processes running? | ready vs wanted replicas, container restarts |
| Application | Is the code erroring or burning time? | 5xx ÷ requests, **request p95 − database p95** |
| Queue | Is work piling up faster than it drains? | SQS visible depth, seconds since last poll |
| Database | Is SQL slow, or refused? | statement p99, error kind |
| Network | Can we open a connection at all? | `connect_timeout` / `dns` / `refused` per minute |

Because these are independent, one fault answers *its* layer's question badly and leaves the others normal. The
pattern across all five is a fingerprint, and no two faults share one.

The subtraction in the Application row is the core of it. Request time is application time plus database time, so
measuring both and subtracting tells you where the time went:

- both rise together → **database**
- request rises, database flat → **application**
- database reports *no data* while connection errors climb → **network**

Alerts are typed to match. A **cause** names one layer; a **symptom** (`ErrorBudgetBurn`, `ApiLatencyHigh`) says
users are affected but not why. Alertmanager mutes symptoms while any cause fires, and mutes a consequence while
its cause fires — so one fault produces one ticket with one owner, not six tickets describing its echoes.

## Evidence

Four faults were injected into a live cluster on 2026-10-11 under steady load. **[docs/evidence.md](docs/evidence.md)**
presents each one with the claim it supports, the signal that moved, and the signals that did not.

| Drill | Fault | Platform's verdict | Time to ticket |
| --- | --- | --- | --- |
| 6 | egress to PostgreSQL blocked | **network** (database reported no data) | ~2 min |
| 3a | notification worker scaled to zero | **kubernetes**, then **queue** | ~3 min |
| 1 | API pod deleted | none — self-healed inside the alert threshold | n/a |
| 2a | 800 ms latency injected | application, from the request/database divergence | ~10 min |

Three alert conditions were true during the drill window and **exactly one ticket existed at a time**, each naming
its own layer. That ordering — cause before consequence, symptoms suppressed — is the answer to "doesn't this page
everyone at once?"

The drills also found five defects that reading the code would not have: a NetworkPolicy that does not bite while
connection pools hold open connections, unready pods leaving Prometheus's scrape targets exactly when the fault is
worst, a self-hosted incident recorder that cannot record its own outage, synthetic load burying real tickets, and
a panel that reports "63.4 years" when the worker is absent. They are written up in
[docs/incidents.md](docs/incidents.md).

## The application

**OpsDesk** is an internal telecom ticketing and access-request portal — the thing being observed, and also where
incidents are recorded. Two workloads:

- **ticket-api** (FastAPI) — web UI and REST API, publishes notification events to SQS
- **ticket-worker** — consumes them and delivers notifications

Postgres for state, SQS with a dead-letter queue between the two. Delivery is at-least-once with the notification
row as the idempotency key; failures are retried three times and then parked in the DLQ. Every failure is
classified by `(dependency, kind)` — the `kind` is what tells the layers apart.

Alertmanager posts to `/integrations/alertmanager`, which opens an incident ticket carrying the suspected layer,
priority from severity, team from labels, and a link to the matching runbook section.

## Architecture

One EKS cluster (3 × m5.large) runs **dev and prod**, isolated by namespace, ResourceQuota, NetworkPolicy and
separate databases, queues, secrets and IAM roles. Sharing the cluster is the single biggest cost saving; the
isolation controls are what make it defensible.

```
GitHub Actions ──OIDC──► AWS          (no long-lived credentials anywhere)
      │
      ├─ CI        pytest · ruff · Trivy · Checkov · helm lint · kubeconform
      └─ Release   build (SHA-tagged, immutable) → ECR → dev → approval → prod
                                                     └ smoke test, automatic rollback

         ┌──────────────── EKS "opsdesk" ────────────────┐
ALB ───► │ opsdesk-dev   ticket-api · ticket-worker       │ ──► RDS (per env)
ALB ───► │ opsdesk-prod  ticket-api · ticket-worker       │ ──► SQS + DLQ (per env)
         │ observability Prometheus · Alertmanager · Grafana · Tempo · OTel
         │ kube-system   ALB controller · external-dns · autoscaler · metrics-server
         │ logging       Fluent Bit ──► CloudWatch Logs
         └───────────────────────────────────────────────┘
```

Workloads authenticate to AWS with **IRSA** — a short-lived OIDC token exchanged for temporary credentials, scoped
per service account. Combined with GitHub OIDC in CI, there is no stored AWS key anywhere in the system.

## Running it

Everything runs from GitHub Actions; no local AWS tooling is required.

| Step | Workflow | Time |
| --- | --- | --- |
| 0 | **Bootstrap** — state bucket, ACM certificate (once) | ~1 min |
| 1 | **Infrastructure** → `apply` | ~30 min |
| 2 | **Release** — build, scan, dev, approve, prod | ~13 min |
| 3 | **Ops** → `load-start`, then drills | 1 min each |
| 4 | **Destroy** — tear everything down | ~15 min |

Release is deliberately manual: CI gates every pull request, but deploying is a decision rather than a side effect
of merging. Full setup, including the optional custom domain and HTTPS, is in [docs/aws.md](docs/aws.md).

**Failure drills** run from **Ops** against `dev` — `drill1-pod-kill`, `drill2-latency-on`,
`drill3-stuck-queue-on`, `drill6-network-block-db-on` and others, each with a matching `-off`.
[docs/drill-evidence.md](docs/drill-evidence.md) explains which panel to read for each and what it proves.

## Repository layout

```
app/            FastAPI service, worker, UI, migrations, tests
helm/opsdesk/   chart: deployments, HPA, probes, NetworkPolicies, ServiceMonitor, PrometheusRule
terraform/      bootstrap (state, certificate) · infra (VPC, EKS, RDS, SQS, IAM) · platform (controllers,
                observability); one module per component under terraform/modules
deploy/         Grafana dashboards, kube-prometheus-stack and Tempo values
.github/        CI, Release, Infrastructure, Ops (drills), Destroy
scripts/aws/    up / down / deploy / smoke / load, called by the workflows
load/           k6 constant-arrival-rate load generator
docs/           see below
```

## Documentation

| | |
| --- | --- |
| [evidence.md](docs/evidence.md) | the drills, presented with the claim each screenshot supports |
| [incidents.md](docs/incidents.md) | operational log, alert ordering, findings from running the drills |
| [drill-evidence.md](docs/drill-evidence.md) | how to read each panel, and what each metric means |
| [runbook.md](docs/runbook.md) | find the layer in two minutes; one section per alert |
| [aws.md](docs/aws.md) | setup, workflows, HTTPS on a custom domain |
| [cost.md](docs/cost.md) | where the money goes, and three optimizations |
| [security/findings.md](docs/security/findings.md) | scan findings, owners, remediation |

## Honest limits

- **Four of seven drills were run.** Database indexing, poison messages, pool exhaustion, error injection and
  namespace isolation were not exercised. The dev/prod isolation is therefore a *design* property here, not a
  demonstrated one.
- **One panel is wrong.** *Seconds since the worker last polled* reports "63.4 years" when the worker is absent.
- **The error-budget tile averages over 30 days** in an environment rebuilt daily, so it reads red from a single
  startup burst. An SLO window must be shorter than the lifetime of the thing it measures.
- **Traces are wired but thin.** Tempo and OpenTelemetry are deployed and exemplars link from the latency panel,
  but tracing is not exercised in the drills.
- **Synthetic load is uniform.** k6 drives a steady arrival rate; real traffic has peaks, bursts and retries.
