# OpsDesk cost analysis

**Bottom line:** the demo environment costs about **$12 a day** while it runs, and **compute nodes are 57 % of
that**. Three changes cut the monthly bill from about **$370** (left on 24/7) to about **$55** for the same hours of
real use: run it only while working, put the nodes on Spot, and drop to two nodes once the CPU data shows the third
is idle.

Prices: AWS us-east-1 on-demand, checked October 2026 (sources at the end). Replace the "measured" column with your
own Cost Explorer numbers after the first full day (Billing → Cost Explorer → *Group by* tag `Project` = `opsdesk`,
daily granularity).

## Where the money goes (baseline, per day)

| Item | Unit price | Baseline | Estimate / day | Measured / day |
| --- | --- | --- | --- | --- |
| EC2 nodes (EKS managed node group) | $0.096 / h per m5.large | 3 × m5.large, on-demand | $6.91 | |
| EKS control plane | $0.10 / h (standard support) | 1 cluster | $2.40 | |
| NAT gateway | $0.045 / h + $0.045 / GB | 1 gateway, < 1 GB/day | $1.10 | |
| Application Load Balancer | ~$0.0225 / h + LCUs | 1 ALB (app + Grafana) | ~$0.60 | |
| Public IPv4 addresses | $0.005 / h each | NAT + ALB (2 AZs) = 3 | $0.36 | |
| RDS PostgreSQL | ~$0.016 / h | db.t4g.micro, single-AZ, 20 GB gp3 | ~$0.45 | |
| EBS volumes | $0.08 / GB-month (gp3) | node disks + Prometheus 20 GiB + Tempo 10 GiB | ~$0.25 | |
| KMS, Secrets Manager, CloudWatch Logs, SQS | small | 1 key, 2 secrets, 7-day logs, < 1M requests | ~$0.20 | |
| **Total** | | | **≈ $12.30** | |

The EKS control plane, NAT gateway and public IPs are fixed costs: they are charged the same at zero traffic. That is
why switching the environment off matters more than any tuning.

## Recommendations

### 1. Run it only while you work (−75 %)

The environment is fully rebuilt from code: **Infrastructure → apply** and **Release** bring it back in about
40 minutes, and **Destroy** removes everything (the Terraform state bucket stays).

| Usage pattern | Hours / month | Cost / month |
| --- | --- | --- |
| Left on 24/7 | 720 | ≈ $370 |
| 8 h a day, 5 days a week | ~175 | ≈ $90 |

**Evidence to capture:** Cost Explorer daily bars (gaps on the days it was destroyed), the Destroy workflow runs,
and the AWS Budget (`opsdesk-demo-monthly`, $150) never reaching its alert threshold.
**Trade-off:** 40 minutes to come back; no data survives (fine for a demo, not for production).

### 2. Spot capacity for the worker nodes (−57 % on the biggest line)

m5.large on Spot was about **$0.0415 / h** versus **$0.096 / h** on-demand (−57 %). On three nodes that is about
**$3.90 less per day**. Turn it on without code changes: repository variables `NODE_CAPACITY_TYPE` = `SPOT` and
`NODE_INSTANCE_TYPES` = `["m5.large","m5a.large","m6i.large"]` (several types = fewer interruptions), then run
Infrastructure → apply.

**Why it is safe here:** ticket-api runs 2+ replicas with a PodDisruptionBudget, the worker is stateless and SQS keeps
messages while a node is replaced, and RDS holds all data outside the cluster.
**Trade-off:** Spot interruption rates for m5.large run above 20 % at times. Prometheus loses up to a few minutes of
data when its node is reclaimed. In production, keep stateful or critical add-ons on a small on-demand node group.
**Evidence:** EC2 console → instance lifecycle `spot`, and the EC2 line in Cost Explorer before and after.

### 3. Right-size the node group from measured usage (−33 % of compute)

Three m5.large give 6 vCPU and 24 GiB. Use the **CPU used vs requested** panel (dashboard *Where is the fault?*,
Kubernetes row) and `kubectl top nodes` under the k6 load. If total requests fit comfortably on two nodes (under about
70 % of their allocatable CPU and memory), set `NODE_DESIRED_SIZE` = `2`: about **$2.30 less per day** on-demand,
$1.00 on Spot. The Cluster Autoscaler still adds a node (up to 4) when pods do not fit.

**Evidence:** a screenshot of the panel and of `kubectl top nodes` before the change, the node count after, and pods
staying `Running` during a load test.

### Also decided with numbers

- **Keep the NAT gateway, skip interface endpoints at this scale.** Six interface endpoints (ECR ×2, SQS, Secrets
  Manager, Logs, STS) in 2 AZs cost 12 × $0.01 / h = **$2.88 / day** whatever the traffic. They save
  $0.035 per GB against NAT processing, so they pay off only above about **80 GB a day**; the demo moves under 1 GB.
  The free S3 gateway endpoint is on (ECR image layers come from S3). Flip `enable_interface_endpoints` in
  production, where image pulls and log traffic are much larger.
- **7-day log retention** on every CloudWatch log group (app logs, VPC flow logs, EKS control plane, RDS) keeps log
  storage near zero; long-term retention belongs in S3 with lifecycle rules.
- **Graviton next:** m7g.large is $0.0816 / h (−15 % against m5.large, with better performance per vCPU). It needs
  arm64 images: build the app image with `docker buildx --platform linux/amd64,linux/arm64`.

## Combined effect

| Scenario | Nodes | Hours / month | Cost / month |
| --- | --- | --- | --- |
| Baseline, left on | 3 × m5.large on-demand | 720 | ≈ $370 |
| 1. Work hours only | 3 × on-demand | 175 | ≈ $90 |
| 1 + 2. Spot | 3 × Spot | 175 | ≈ $60 |
| 1 + 2 + 3. Two nodes | 2 × Spot | 175 | ≈ $55 |

Cost controls already in the code: tags `Project`, `Env`, `Owner` on every resource (Terraform `default_tags`), an
AWS Budget with email alerts, single NAT gateway, single-AZ `db.t4g.micro`, no interface endpoints by default, and
EKS on a version in standard support (extended support costs $0.60 / h per cluster, six times more).

## Sources

- [AWS m5.large price, us-east-1 (on-demand, Spot, Savings Plans)](https://calculator.holori.com/aws/ec2/m5.large/us-east-1)
- [AWS m7g.large price, us-east-1](https://www.doit.com/compute/spot/us-east-1/m7g.large)
- [EKS control plane pricing, standard vs extended support](https://cloudburn.io/blog/amazon-eks-pricing)
- [NAT gateway and VPC endpoint pricing](https://spendark.com/blog/aws-nat-gateway-pricing/)
- Confirm every figure in the [AWS Pricing Calculator](https://calculator.aws/) before presenting; ALB, RDS and EBS
  lines above are approximate.
