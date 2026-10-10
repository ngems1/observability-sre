# OpsDesk on AWS — deployed by GitHub Actions

Nothing runs on your laptop. **GitHub Actions** runs Terraform, builds and scans the image, deploys to EKS,
runs the failure drills and tears everything down. It authenticates to AWS with **GitHub OIDC** (short-lived
credentials, no AWS keys stored anywhere). Everything is Terraform run by GitHub Actions; the only manual AWS step
is creating the OIDC trust and the deploy role once in the IAM console (GitHub cannot log in before they exist).

```mermaid
flowchart LR
  user([Your browser<br/>allowed_cidrs only]) -->|HTTP :80| albp[ALB opsdesk-prod<br/>app + /grafana]
  user --> albd[ALB opsdesk-dev<br/>app + /grafana]
  subgraph vpc[VPC 10.40.0.0/16 · 2 AZs · one shared EKS cluster "opsdesk"]
    subgraph prod[namespace opsdesk-prod · quota · NetworkPolicies]
      apip[ticket-api x2-6] --- workp[ticket-worker]
    end
    subgraph dev[namespace opsdesk-dev · quota · NetworkPolicies]
      apid[ticket-api x1-3] --- workd[ticket-worker]
    end
    subgraph platform[shared platform namespaces]
      prom[Prometheus + Alertmanager] --> graf[Grafana]
      tempo[Tempo / OTel]
      eso[External Secrets]
      fb[Fluent Bit]
    end
    rdsp[(RDS opsdesk-prod)]
    rdsd[(RDS opsdesk-dev)]
  end
  albp --> apip
  albp -->|/grafana| graf
  albd --> apid
  albd -->|/grafana| graf
  apip --> rdsp
  apid --> rdsd
  apip --> sqsp[[SQS opsdesk-prod + DLQ]] --> workp
  apid --> sqsd[[SQS opsdesk-dev + DLQ]] --> workd
  prom -. alerts namespace=opsdesk-prod .-> apip
  prom -. alerts namespace=opsdesk-dev .-> apid
  eso -->|role per namespace| sm[(Secrets Manager<br/>opsdesk-dev/app · opsdesk-prod/app)]
  fb --> cw[(CloudWatch Logs<br/>/opsdesk-dev · /opsdesk-prod)]
```

## Two environments, one cluster

dev and prod share the **platform** (EKS cluster, VPC, KMS key, ECR, Prometheus/Grafana/Tempo) and nothing else:

| Isolation layer | dev | prod | How |
| --- | --- | --- | --- |
| Namespace | `opsdesk-dev` | `opsdesk-prod` | Pod Security `restricted`; ResourceQuota (dev 2 vCPU / 3 GiB, prod 3 vCPU / 4 GiB) + LimitRange |
| Network | | | NetworkPolicies: ingress only from the same namespace, the `observability` namespace and the ALB subnets; egress only DNS, 5432, 443, 4318 — no traffic between environments |
| AWS identity | `opsdesk-dev-api/-worker/-secrets` | `opsdesk-prod-…` | IRSA roles trusted only for service accounts in their own namespace |
| Data | own RDS + SQS/DLQ | own RDS + SQS/DLQ | separate instances and credentials |
| Secrets | `opsdesk-dev/app` | `opsdesk-prod/app` | each SecretStore authenticates with its namespace's service account; the External Secrets controller has no AWS permissions |
| Entry point | own ALB | own ALB (+ Grafana) | ingress groups `opsdesk-dev` / `opsdesk-prod` |
| Logs and alarms | `/opsdesk-dev/application` | `/opsdesk-prod/application` | own log group, Logs Insights queries, CloudWatch alarms; costs tagged `Env=dev` / `Env=prod` |
| Alerts → tickets | dev's OpsDesk | prod's OpsDesk | Alertmanager routes by namespace, each with its own bearer token |
| Delivery | every push to `main` | same image, after approval | GitHub environments `dev` (no reviewer) and `prod` (required reviewer) |

Known gap: both environments' pods share the node security group, so at the network level a dev pod could open a
TCP connection to the prod database endpoint; it has no credentials for it (separate secret, separate IAM role).
Closing it needs security groups for pods or a node group per environment ([findings](security/findings.md)).


| Layer | Terraform root | What it creates |
| --- | --- | --- |
| Bootstrap (once) | `terraform/bootstrap` → `terraform/modules/github_oidc` | S3 state bucket (versioned, encrypted, TLS-only, native S3 locking); optionally the GitHub OIDC provider + deploy role |
| Infrastructure | `terraform/infra` → shared modules (network, kms, eks, ecr, observability, irsa, security) + `modules/environment` × dev, prod (sqs, rds, secrets, IAM, log group, alarms) | VPC (1 NAT, flow logs), EKS + managed node group, ECR, KMS key, SNS, AWS Budget, Day-4 security toggles; per environment: RDS, SQS + DLQ, secret, IRSA roles, log group, alarms |
| Platform | `terraform/platform` | gp3 StorageClass, namespaces `opsdesk-dev` / `opsdesk-prod` with Pod Security, ResourceQuota and LimitRange, AWS Load Balancer Controller, External Secrets Operator, metrics-server, Cluster Autoscaler, Fluent Bit → CloudWatch (log group per namespace), kube-prometheus-stack (Alertmanager routes per environment, Grafana at `/grafana` on both environments' ALBs), Tempo, OpenTelemetry Collector, both dashboards |
| App | Helm (`helm/opsdesk` + `values-eks.yaml` + `values-dev.yaml` / `values-prod.yaml`) | one release per namespace: ticket-api, ticket-worker, Ingress (ALB), ExternalSecret + SecretStore, IRSA service accounts, NetworkPolicies, ServiceMonitors, PrometheusRule, HPA, PDB |

## Cost while it runs (approximate, us-east-1 on-demand)

About **$13–15 per day** for both environments: EKS control plane ~$2.40, 3× m5.large ~$6.90, NAT ~$1.10 + data,
2 ALBs ~$1.20, 2 RDS db.t3.micro ~$0.80, EBS volumes ~$0.40, public IPv4 addresses ~$0.60, small amounts for KMS,
Secrets Manager and CloudWatch. The second environment adds only ~$1.50/day because the cluster is shared. **Run the Destroy workflow whenever you stop working**; Infrastructure + Release
rebuild everything in about 40 minutes. Breakdown and savings recommendations: [cost.md](cost.md).

## One-time setup

**1. GitHub** — push the repo (`ngems1/observability-sre`). CI runs right away; the AWS workflows skip themselves
until step 3 is done.

**2. Bootstrap (once)** — GitHub cannot log in to AWS until a role trusts it, so the trust is created once by hand
in the IAM console (region **us-east-1**); everything after that is Terraform run by GitHub Actions.

*2a. OIDC provider* — IAM → **Identity providers**. If `token.actions.githubusercontent.com` is already listed
(e.g. from an earlier project), skip this. Otherwise **Add provider** → *OpenID Connect* → Provider URL
`https://token.actions.githubusercontent.com` → Audience `sts.amazonaws.com` → **Add provider**.

*2b. Deploy role* — IAM → **Roles** → **Create role** → *Web identity* → Identity provider
`token.actions.githubusercontent.com`, Audience `sts.amazonaws.com`, GitHub organization `ngems1`, GitHub repository
`observability-sre`, branch `main` → Next → permissions **AdministratorAccess** → Next → Role name
**`opsdesk-github-deploy`** → **Create role**. Then open the role:

- **Trust relationships** → *Edit trust policy* → replace everything with the policy below (put your 12-digit account
  ID, top right of the console, in place of `ACCOUNT_ID`) → *Update policy*. It also allows pull requests and the
  `dev` and `prod` GitHub environments, which the workflows use.
- **Summary** → *Edit* → **Maximum session duration: 2 hours** → *Save* (creating EKS takes longer than 1 hour).
- Copy the role **ARN** (`arn:aws:iam::ACCOUNT_ID:role/opsdesk-github-deploy`).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:ngems1@330211773/observability-sre@1410480281:ref:refs/heads/main",
            "repo:ngems1@330211773/observability-sre@1410480281:pull_request",
            "repo:ngems1@330211773/observability-sre@1410480281:environment:dev",
            "repo:ngems1@330211773/observability-sre@1410480281:environment:prod"
          ]
        }
      }
    }
  ]
}
```

*2c. State bucket* — after step 3 below: GitHub → **Actions → Bootstrap → Run workflow** → approve. It runs
`terraform/bootstrap` (bucket `opsdesk-tfstate-<account>-us-east-1`, versioned, encrypted, TLS-only) and stores that
root's own state in the bucket, so it can be re-run safely.

The same role and provider are also written as Terraform (`terraform/modules/github_oidc`): with AWS CloudShell
available, `terraform -chdir=terraform/bootstrap apply` creates the whole bootstrap, role included, instead of 2a–2c.

**3. GitHub → repository Settings**

- *Environments* → **New environment** `dev` (no protection rules: every push to `main` deploys there), then
  **New environment** `prod` → *Required reviewers*: add yourself. Promotion to prod, prod drills, Infrastructure
  apply, Bootstrap and Destroy then wait for your approval (they change prod or the shared platform).
- *Secrets and variables → Actions → Variables* → add:

| Variable | Example | Purpose |
| --- | --- | --- |
| `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/opsdesk-github-deploy` | role GitHub Actions assumes (ARN from step 2b) |
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

**5. Optional: HTTPS on a custom domain.** Register a domain and create its **public hosted zone in Route 53 by
hand** — the zone is deliberately *not* managed by Terraform, because recreating it changes the NS records and
breaks the registrar's delegation. Then set the repository variable `DOMAIN_NAME` to the apex (e.g.
`example.click`) and run **Bootstrap** again: it issues one ACM certificate for `<domain>` and `*.<domain>` and
validates it by DNS. Bootstrap must succeed before Infrastructure, which looks the certificate up by domain.

With `DOMAIN_NAME` set, each environment gets a stable HTTPS URL and plain HTTP is redirected to it:

| | URL | Grafana |
| --- | --- | --- |
| dev | `https://dev.<domain>` | `https://dev.<domain>/grafana` |
| prod | `https://opsdesk.<domain>` | `https://opsdesk.<domain>/grafana` |

The certificate lives in the **bootstrap** root on purpose: ACM certificates are free, DNS validation takes a few
minutes, and bootstrap survives `Destroy` — so the certificate is issued once instead of being re-validated on
every rebuild. The records are kept by **external-dns** running in the cluster, which watches each Ingress and
repoints the alias at whatever ALB the load balancer controller created. That matters because the environment is
torn down nightly: every rebuild produces a new ALB hostname, and without external-dns the records would have to
be repointed by hand each morning. While the environment is down the records point at a load balancer that no
longer exists, and the name starts resolving again a few minutes after the next deploy.

Note that an Ingress with a hostname only answers to that hostname: once `DOMAIN_NAME` is set, the raw
`k8s-...elb.amazonaws.com` address returns 404. Use the domain. Leave `DOMAIN_NAME` unset and everything stays on
HTTP at the raw load-balancer hostname, exactly as before.

`ALLOWED_CIDRS` is unchanged by any of this and still decides who may reach the load balancer: your own
`x.x.x.x/32` keeps the demo private, `0.0.0.0/0` opens it to anyone with the URL, leaving the app's own sign-in as
the only control.

## Bring it up

| Step | GitHub → Actions | Time |
| --- | --- | --- |
| 0 | **Bootstrap** → Run workflow → approve (first time only) | ~1 min (state bucket) |
| 1 | **Infrastructure** → Run workflow → `apply` → approve | ~30 min (EKS ~15, RDS ~8, platform ~10) |
| 2 | **Release** → Run workflow → dev deploys by itself → approve **Promote to prod** | ~8 min dev + ~5 min prod (same image) |
| 3 | **Ops** → environment `dev` → `load-start`, then `prod` → `load-start` | 1 min each (k6 at 5 req/s inside each namespace) |

The Release summary shows each environment's **Web UI** and **Grafana** URLs (`http://<alb>/grafana`: one shared Grafana on both load balancers; pick the environment with the dashboards' *Environment* dropdown).
Logins live in **AWS console → Secrets Manager**: `opsdesk-dev/app` and `opsdesk-prod/app` (`bootstrap_users` =
`name:role:api_key` entries; paste a key on the sign-in page) and `opsdesk/grafana`.

After that, every push to `main` runs CI → build → Trivy gate → **dev** (deploy, smoke test, automatic rollback) →
**approval** → **prod** (the same image, smoke test, automatic rollback).

## Workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| **CI** | pull requests; called by Release | pytest + ruff, Docker build, Trivy (deps + image, SARIF to the Security tab), terraform validate, Checkov (Terraform, rendered Helm), helm lint, kubeconform |
| **Bootstrap** | manual, once | Terraform `bootstrap`: the state bucket (state of the bootstrap root kept in the bucket) |
| **Infrastructure** | PR / push: plan · manual: apply | Terraform `infra` + `platform` (apply needs `prod` approval: it changes the shared platform) |
| **Release** | push to `main`, manual | CI → image tagged with the commit SHA → Trivy gate → ECR → **dev** (Helm `--atomic`, smoke test, rollback on failure) → approval → **prod** with the same image. Skips deploy when the environment is down |
| **Ops** | manual, input `environment` (default `dev`) | `status`, `load-start/stop`, drills 1–7, `errors-on/off`, `rollback` in one environment; prod needs approval. Each run logs timestamps and before/after state as drill evidence |
| **Destroy** | manual (type `destroy`) | both apps → platform → infra, in the order that lets the ALBs and VPC delete cleanly |
| **Terraform fmt** | manual | formats Terraform and commits the change |

## Failure drills (Actions → Ops → environment `dev`)

Run drills in **dev**: everything they break is dev's own (namespace, database, queue, network rules). Keep
Grafana → *Where is the fault?* open and switch the **Environment** dropdown between `opsdesk-dev` (red tile) and
`opsdesk-prod` (all green): that is the isolation evidence.

| Drill | Inject | Recover | Evidence to capture |
| --- | --- | --- | --- |
| 1 Pod failure | `drill1-pod-kill` | automatic (Deployment + PDB) | run log, Grafana availability panel |
| 2 Latency | `drill2-seed-1m-tickets` then `drill2-explain` (Seq Scan) — or `drill2-latency-on` | `drill2-fix-index` (prints the new plan) / `drill2-latency-off` | p95 panel before/after, trace with the slow DB span, `OpsDeskDatabaseSlow` ticket (layer database; injected latency instead gives `OpsDeskApiLatencyHigh`, layer unknown → app) |
| 3 Stuck queue | `drill3-stuck-queue-on` · `drill3-poison-message` | `drill3-stuck-queue-off` | **OpsDesk incident ticket opened by `OpsDeskWorkerDown`** (~3 min) with its time to recover, queue-age alarm email, DLQ alarm, delivery-time panel |
| 4 DB connections | `drill4-pool-exhaustion-on` + `load-start` | `drill4-pool-exhaustion-off` | DB pool panel, RDS connections metric, `OpsDeskDatabaseErrors` ticket (`too_many_connections`, layer database) |
| 6 Network | `drill6-network-block-db-on` (egress NetworkPolicy drops port 5432; open DB sessions are ended) | `drill6-network-block-db-off` | `OpsDeskDependencyUnreachable` ticket with `kind=connect_timeout`, **layer network** while RDS stays healthy; Network tile red on *Where is the fault?* |
| 5 Bad deploy | push a commit that breaks `/readyz` | Release rolls back dev automatically and never promotes to prod | Release run log (prod job not reached), `helm history` |
| 7 Noisy neighbour | `drill7-noisy-neighbour-on` (30 pods × 200m CPU in dev) | `drill7-noisy-neighbour-off` | `exceeded quota` events and the quota usage in the run log; prod pods and latency unchanged |

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
| 7 Noisy neighbour | Kubernetes (quota keeps environments apart) |

## Troubleshooting

- **Release says "Deploy skipped"** — the environment is down: run Infrastructure (`apply`) first.
- **`Not authorized to perform sts:AssumeRoleWithWebIdentity`** — the `sub` patterns in the role's trust policy must
  match the token exactly (case-sensitive). GitHub writes this repository's subject with immutable owner and
  repository IDs: `repo:ngems1@330211773/observability-sre@1410480281:environment:prod`, so a pattern like
  `repo:ngems1/observability-sre:*` never matches. Find the real value in CloudTrail → Event history →
  `AssumeRoleWithWebIdentity` (the failed event). Also check that `AWS_ROLE_ARN` names the role you edited and that the
  account ID in the `Federated` ARN is yours.
- **RDS `InsufficientDBInstanceCapacity`** — AWS has no capacity for that DB class in the VPC's two AZs right now.
  Set the repository variable `DB_INSTANCE_CLASS` to another class (default `db.t3.micro`; e.g. `db.t3.small`,
  `db.t4g.micro`) and re-run Infrastructure → apply: everything already created is kept.
- **`The requested DurationSeconds exceeds the MaxSessionDuration`** — set the role's maximum session duration to 2 hours.
- **Bootstrap fails with `EntityAlreadyExists` on the OIDC provider** — the account already has one: re-run the
  apply with `-var create_oidc_provider=false`.
- **EKS version not supported** — set the `eks_version` default in `terraform/infra/variables.tf` to a version in
  *standard support* (extended support costs extra).
- **`terraform fmt` warning in CI** — run the *Terraform fmt* workflow; it commits the formatting.
- **ALB not created / page does not load** — `ALLOWED_CIDRS` must be a JSON list of CIDRs and include your *current*
  public IP; after changing it re-run Infrastructure (`apply`) and Release.
- **Pods `CreateContainerConfigError`** — the ExternalSecret has not synced: Ops → `status` shows the ExternalSecret state.
- **No ticket after an alert fires** — Grafana → Alerting → Alert rules shows whether it is firing; Alertmanager logs
  (`kubectl -n observability logs alertmanager-kube-prometheus-stack-alertmanager-0`) show webhook errors: 401 means
  the token in Secrets Manager (`opsdesk-<env>/app` → `alert_webhook_token`) and the `alertmanager-opsdesk-webhook`
  Secret (key `token-<env>`) differ — re-run Infrastructure (`apply`).
- **API pods never ready right after the first deploy (readiness probe timeouts)** — the NetworkPolicy may be blocking
  the kubelet probes on your VPC CNI version: re-run Release with `networkPolicy.extraIngressCidrs` set to the private
  subnets (`10.40.16.0/20`, `10.40.32.0/20`) in `values-eks.yaml` (weakens isolation; note it in the findings).
- **`exceeded quota` outside a drill** — the namespace quota is too small for the HPA maximum: raise
  `namespace_quotas` in `terraform/platform/variables.tf`.
- **Destroy hangs on the VPC** — an ALB or ENI is left over: delete it in EC2 → Load Balancers, then re-run Destroy.

## Fallback: AWS CloudShell

The same scripts the workflows call can run in AWS CloudShell (after the bootstrap): copy the two
`terraform.tfvars.example` files, then `bash scripts/aws/up.sh` / `down.sh`. Use one path or the other for a given environment (the identity that
creates the cluster becomes its first admin).
