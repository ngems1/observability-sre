# OpsDesk on AWS — deployed by GitHub Actions

Nothing runs on your laptop. **GitHub Actions** runs Terraform, builds and scans the image, deploys to EKS,
runs the failure drills and tears everything down. It authenticates to AWS with **GitHub OIDC** (short-lived
credentials, no AWS keys stored anywhere). The only manual AWS step is a one-time CloudFormation stack created
from the AWS console. (AWS CloudShell scripts in `scripts/aws/` remain as a fallback; see the end.)

```mermaid
flowchart LR
  user([Your browser<br/>allowed_cidrs only]) -->|HTTP :80| alb[ALB<br/>group: opsdesk]
  subgraph vpc[VPC 10.40.0.0/16 · 2 AZs]
    subgraph public[Public subnets]
      alb
      nat[NAT gateway x1]
    end
    subgraph private[Private subnets · EKS managed node group]
      api[ticket-api x2-6<br/>HPA] -->|OTLP| otel[OTel Collector] --> tempo[Tempo]
      worker[ticket-worker]
      prom[Prometheus + Alertmanager] --> graf[Grafana /grafana]
      graf --> tempo
      fb[Fluent Bit]
      eso[External Secrets]
    end
    subgraph db[Database subnets]
      rds[(RDS PostgreSQL 16<br/>KMS · force_ssl)]
    end
  end
  alb -->|/| api
  alb -->|/grafana| graf
  api -->|5432| rds
  worker -->|5432| rds
  api -->|SendMessage · IRSA| sqs[[SQS notifications<br/>KMS]]
  sqs -->|Receive · IRSA| worker
  sqs -. 3 failed receives .-> dlq[[DLQ]]
  eso -->|GetSecretValue · IRSA| sm[(Secrets Manager<br/>app + RDS-managed DB secret)]
  fb -->|IRSA| cw[(CloudWatch Logs<br/>7-day retention)]
  ecr[(ECR · immutable tags<br/>scan on push)] -.image.-> api
  cwa[CloudWatch alarms<br/>DLQ · queue age · RDS] --> sns[SNS → email]
  prom -. alert webhook .-> api
```

| Layer | Terraform root | What it creates |
| --- | --- | --- |
| State | `terraform/bootstrap` | S3 bucket for state (versioned, encrypted, TLS-only, native S3 locking) |
| Infrastructure | `terraform/infra` → `terraform/modules/*` (network, kms, eks, ecr, sqs, rds, secrets, irsa, observability, security) | VPC (1 NAT, flow logs), EKS + managed node group, ECR, RDS PostgreSQL, SQS + DLQ, KMS key, IRSA roles, Secrets Manager, CloudWatch log groups + alarms + SNS, AWS Budget; Day-4 toggles for GuardDuty, Security Hub, Inspector, CloudTrail |
| Platform | `terraform/platform` | gp3 StorageClass, namespaces with Pod Security levels, AWS Load Balancer Controller, External Secrets Operator, metrics-server, Cluster Autoscaler, Fluent Bit → CloudWatch, kube-prometheus-stack (Grafana on the ALB at `/grafana`), Tempo, OpenTelemetry Collector, the OpsDesk dashboard |
| App | Helm (`helm/opsdesk` + `values-eks.yaml`) | ticket-api, ticket-worker, Ingress (ALB), ExternalSecret, IRSA service accounts, NetworkPolicies, ServiceMonitors, HPA, PDB |

## Cost while it runs (approximate, us-east-1 on-demand)

About **$12–14 per day**: EKS control plane ~$2.40, 3× m5.large ~$6.90, NAT ~$1.10 + data,
ALB ~$0.60, RDS db.t4g.micro ~$0.40, EBS volumes ~$0.40, public IPv4 addresses ~$0.40, small amounts for KMS,
Secrets Manager and CloudWatch. **Run the Destroy workflow whenever you stop working**; Infrastructure + Release
rebuild everything in about 40 minutes. Breakdown and savings recommendations: [cost.md](cost.md).

## One-time setup (browser only)

**1. GitHub** — push the repo (e.g. `ngems1/opsdesk`). The CI workflow runs on pull requests right away; the AWS
workflows skip themselves until step 3 is done.

**2. AWS console → CloudFormation** (region **us-east-1**) → *Create stack* → *With new resources* →
*Upload a template file* → `bootstrap/github-oidc-bootstrap.yaml`:

| Parameter | Value |
| --- | --- |
| Stack name | `opsdesk-bootstrap` |
| GitHubOwner | your GitHub user, e.g. `ngems1` |
| GitHubRepo | `opsdesk` |
| CreateOIDCProvider | `true` (use `false` only if IAM → Identity providers already lists `token.actions.githubusercontent.com`) |

Tick *"I acknowledge that AWS CloudFormation might create IAM resources with custom names"* → Submit.
When it shows `CREATE_COMPLETE`, copy **DeployRoleArn** from the *Outputs* tab. The stack also creates the
Terraform state bucket `opsdesk-tfstate-<account>-us-east-1`.

**3. GitHub → repository Settings**

- *Environments* → **New environment** `demo` → *Required reviewers*: add yourself (every apply, deploy, drill and
  destroy then waits for your approval: the protected-environment requirement of the plan).
- *Secrets and variables → Actions → Variables* → add:

| Variable | Example | Purpose |
| --- | --- | --- |
| `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/opsdesk-github-deploy` | role GitHub Actions assumes (from step 2) |
| `OWNER` | `sebastien` | `Owner` cost-allocation tag |
| `ALERT_EMAIL` | `you@example.com` | budget + CloudWatch alarm emails |
| `ALLOWED_CIDRS` | `["203.0.113.10/32"]` | who can open the app/Grafana: your public IP (https://checkip.amazonaws.com) + `/32`, JSON list |
| `CONSOLE_ADMIN_ARNS` *(optional)* | `["arn:aws:iam::123456789012:user/sebastien"]` | lets your console user see workloads in the EKS console |

  Optional secret: `SLACK_WEBHOOK_URL` (otherwise notifications are log-only). Optional Day-4 variables:
  `ENABLE_GUARDDUTY`, `ENABLE_SECURITYHUB`, `ENABLE_INSPECTOR`, `ENABLE_CLOUDTRAIL` = `true`. Optional cost variables
  ([cost.md](cost.md)): `NODE_CAPACITY_TYPE` = `SPOT`, `NODE_INSTANCE_TYPES` = `["m5.large","m5a.large","m6i.large"]`,
  `NODE_DESIRED_SIZE` = `2`.

**4. Billing → Cost allocation tags** → activate `Project`, `Env`, `Owner` after the first apply (takes up to 24 h),
and confirm the SNS subscription email AWS sends to `ALERT_EMAIL`.

## Bring it up

| Step | GitHub → Actions | Time |
| --- | --- | --- |
| 1 | **Infrastructure** → Run workflow → `apply` → approve | ~30 min (EKS ~15, RDS ~8, platform ~10) |
| 2 | **Release** → Run workflow → approve the deploy | ~8 min (CI, build, Trivy gate, ECR push, Helm, smoke test) |
| 3 | **Ops** → `load-start` | 1 min (k6 at 5 req/s) |

The Release run summary shows the **Web UI** and **Grafana** URLs (`http://<alb>/` and `/grafana`).
Logins live in **AWS console → Secrets Manager**: `opsdesk-demo/app` (`bootstrap_users` = `name:role:api_key`
entries; paste a key on the sign-in page) and `opsdesk-demo/grafana`.

After that, every push to `main` runs CI → build → scan → (approval) → deploy → smoke test → rollback if it fails.

## Workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| **CI** | pull requests; called by Release | pytest + ruff, Docker build, Trivy (deps + image, SARIF to the Security tab), terraform validate, Checkov (Terraform, CloudFormation, rendered Helm), helm lint, kubeconform |
| **Infrastructure** | PR / push: plan · manual: apply | Terraform `infra` + `platform` (apply needs `demo` approval) |
| **Release** | push to `main`, manual | CI → image tagged with the commit SHA → Trivy gate → ECR → Helm `--atomic` → smoke test → automatic `helm rollback` on failure. Skips deploy when the environment is down |
| **Ops** | manual | `status`, `load-start/stop`, drills 1–4, `errors-on/off`, `rollback` — each run logs timestamps and before/after state as drill evidence |
| **Destroy** | manual (type `destroy`) | app → platform → infra, in the order that lets the ALB and VPC delete cleanly |
| **Terraform fmt** | manual | formats Terraform and commits the change |

## Failure drills (Actions → Ops)

| Drill | Inject | Recover | Evidence to capture |
| --- | --- | --- | --- |
| 1 Pod failure | `drill1-pod-kill` | automatic (Deployment + PDB) | run log, Grafana availability panel |
| 2 Latency | `drill2-seed-1m-tickets` then `drill2-explain` (Seq Scan) — or `drill2-latency-on` | `drill2-fix-index` (prints the new plan) / `drill2-latency-off` | p95 panel before/after, trace with the slow DB span, `OpsDeskDatabaseSlow` ticket (layer database; injected latency instead gives `OpsDeskApiLatencyHigh`, layer unknown → app) |
| 3 Stuck queue | `drill3-stuck-queue-on` · `drill3-poison-message` | `drill3-stuck-queue-off` | **OpsDesk incident ticket opened by `OpsDeskWorkerDown`** (~3 min) with its time to recover, queue-age alarm email, DLQ alarm, delivery-time panel |
| 4 DB connections | `drill4-pool-exhaustion-on` + `load-start` | `drill4-pool-exhaustion-off` | DB pool panel, RDS connections metric, `OpsDeskDatabaseErrors` ticket (`too_many_connections`, layer database) |
| 6 Network | `drill6-network-block-db-on` (egress NetworkPolicy drops port 5432; open DB sessions are ended) | `drill6-network-block-db-off` | `OpsDeskDependencyUnreachable` ticket with `kind=connect_timeout`, **layer network** while RDS stays healthy; Network tile red on *Where is the fault?* |
| 5 Bad deploy | push a commit that breaks `/readyz` | Release rolls back automatically | Release run log, `helm history` |

Every drill that fires an alert leaves an **ALERT** ticket in OpsDesk with the suspected layer and the time to
recover: that ticket is the incident record (assign, triage, add evidence, postmortem). For each drill, screenshot
Grafana → **OpsDesk - Where is the fault?** while it is broken: the red verdict tile should match the drill's layer.
On-call steps per alert: [runbook.md](runbook.md).

| Drill | Layer it proves |
| --- | --- |
| 1 Pod kill | Kubernetes (self-heals: no ticket, availability unchanged) |
| 3 Worker stopped · poison message | Kubernetes → Queue |
| `errors-on` | Application (SLO burn rate, no layer alert) |
| 2 Missing index | Database (slow) |
| 4 Connection limit | Database (rejects work) |
| 6 NetworkPolicy blocks 5432 | Network |

## Troubleshooting

- **Release says "Deploy skipped"** — the environment is down: run Infrastructure (`apply`) first.
- **`Not authorized to perform sts:AssumeRoleWithWebIdentity`** — `GitHubOwner`/`GitHubRepo` in the CloudFormation
  stack must match the repository exactly (case-sensitive), and the job must run on `main` or in the `demo` environment.
- **EKS version not supported** — set the `eks_version` default in `terraform/infra/variables.tf` to a version in
  *standard support* (extended support costs extra).
- **`terraform fmt` warning in CI** — run the *Terraform fmt* workflow; it commits the formatting.
- **ALB not created / page does not load** — `ALLOWED_CIDRS` must be a JSON list of CIDRs and include your *current*
  public IP; after changing it re-run Infrastructure (`apply`) and Release.
- **Pods `CreateContainerConfigError`** — the ExternalSecret has not synced: Ops → `status` shows the ExternalSecret state.
- **No ticket after an alert fires** — Grafana → Alerting → Alert rules shows whether it is firing; Alertmanager logs
  (`kubectl -n observability logs alertmanager-kube-prometheus-stack-alertmanager-0`) show webhook errors: 401 means
  the token in Secrets Manager (`opsdesk-demo/app` → `alert_webhook_token`) and the `alertmanager-opsdesk-webhook`
  Secret differ — re-run Infrastructure (`apply`).
- **Destroy hangs on the VPC** — an ALB or ENI is left over: delete it in EC2 → Load Balancers, then re-run Destroy.

## Fallback: AWS CloudShell

The same scripts the workflows call can run in AWS CloudShell (a browser terminal, nothing local):
`git clone`, `bash scripts/aws/setup-cloudshell.sh`, copy the two `terraform.tfvars.example` files, then
`bash scripts/aws/up.sh` / `down.sh`. Use one path or the other for a given environment (the identity that
creates the cluster becomes its first admin).
