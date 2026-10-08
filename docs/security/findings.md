# Security findings report

Generated from Checkov scans of `terraform/` and of the Helm chart rendered with the EKS values.
Every exception is suppressed **inline next to the resource** with its justification, so the reason is reviewed
with the code. Trivy image and dependency scans run in CI on every pull request and gate every release (fixable CRITICAL/HIGH fail the build); results go to the GitHub Security tab.

| Scan | Passed | Failed | Accepted exceptions |
| --- | --- | --- | --- |
| Terraform | 183 | 0 | 25 |
| Kubernetes (rendered Helm, EKS values) | 181 | 0 | 8 |

## Accepted exceptions

| Scan | Check | Resource | Justification (owner: platform team) |
| --- | --- | --- | --- |
| Kubernetes | CKV_K8S_11 | `Deployment.opsdesk.opsdesk-api` | No CPU limit on purpose - CPU limits cause throttling; requests + HPA size the workload |
| Kubernetes | CKV_K8S_11 | `Deployment.opsdesk.opsdesk-worker` | No CPU limit on purpose - CPU limits cause throttling; requests + HPA size the workload |
| Kubernetes | CKV_K8S_15 | `Deployment.opsdesk.opsdesk-api` | IfNotPresent is safe with immutable tags and avoids an ECR pull per pod start |
| Kubernetes | CKV_K8S_15 | `Deployment.opsdesk.opsdesk-worker` | IfNotPresent is safe with immutable tags and avoids an ECR pull per pod start |
| Kubernetes | CKV_K8S_35 | `Deployment.opsdesk.opsdesk-api` | 12-factor env config; values come from External Secrets and rotate on pod restart |
| Kubernetes | CKV_K8S_35 | `Deployment.opsdesk.opsdesk-worker` | 12-factor env config; values come from External Secrets and rotate on pod restart |
| Kubernetes | CKV_K8S_43 | `Deployment.opsdesk.opsdesk-api` | ECR tags are immutable (commit SHA), so a tag pins one image like a digest |
| Kubernetes | CKV_K8S_43 | `Deployment.opsdesk.opsdesk-worker` | ECR tags are immutable (commit SHA), so a tag pins one image like a digest |
| Terraform | CKV2_AWS_10 | `aws_cloudtrail.main` | Trail goes to S3 only (CloudWatch delivery doubles log cost); query with Athena if needed |
| Terraform | CKV2_AWS_3 | `aws_guardduty_detector.main` | Single-account demo, no AWS Organization |
| Terraform | CKV2_AWS_57 | `aws_secretsmanager_secret.app` | Demo API keys rotate with `terraform apply -replace=random_password.api_key`; DB credentials are rotated by RDS |
| Terraform | CKV2_AWS_62 | `aws_s3_bucket.state` | No consumers for S3 event notifications on the state bucket |
| Terraform | CKV2_AWS_62 | `aws_s3_bucket.trail` | No event consumers |
| Terraform | CKV_AWS_109 | `aws_iam_policy_document.kms` | Key policy - account root keeps admin so IAM policies can delegate; standard AWS default |
| Terraform | CKV_AWS_111 | `aws_iam_policy_document.kms` | Key policy - "*" resource means "this key"; standard AWS key policy shape |
| Terraform | CKV_AWS_118 | `aws_db_instance.main` | Enhanced monitoring adds cost; CloudWatch RDS metrics + alarms are enough for the demo |
| Terraform | CKV_AWS_144 | `aws_s3_bucket.state` | Cross-region replication of Terraform state is out of scope for a demo; versioning protects against loss |
| Terraform | CKV_AWS_144 | `aws_s3_bucket.trail` | No cross-region replication in the demo |
| Terraform | CKV_AWS_157 | `aws_db_instance.main` | Single-AZ for cost (db_multi_az variable); Multi-AZ in production |
| Terraform | CKV_AWS_18 | `aws_s3_bucket.state` | State bucket access logging needs a second bucket; demo scope (CloudTrail data events cover access if needed) |
| Terraform | CKV_AWS_18 | `aws_s3_bucket.trail` | Access logging for the trail bucket needs another bucket; out of demo scope |
| Terraform | CKV_AWS_293 | `aws_db_instance.main` | Demo environment is destroyed daily; deletion protection on in production |
| Terraform | CKV_AWS_338 | `aws_cloudwatch_log_group.app` | 7-day retention is a deliberate cost decision (cost action #2); raise for compliance workloads |
| Terraform | CKV_AWS_338 | `aws_cloudwatch_log_group.rds` | 7-day retention is a deliberate cost decision (cost action #2) |
| Terraform | CKV_AWS_353 | `aws_db_instance.main` | Performance Insights optional (db_performance_insights); slow-query log covers drill 2 |
| Terraform | CKV_AWS_356 | `aws_iam_policy_document.kms` | Key policy - "*" resource means "this key"; standard AWS key policy shape |
| Terraform | CKV_AWS_394 | `aws_availability_zones.available` | We slice the first two AZs explicitly; the result set growing does not change the VPC |
| Terraform | CKV_TF_1 | `eks` | Registry module pinned with a version constraint; .terraform.lock.hcl pins providers |
| Terraform | CKV_TF_1 | `irsa_cluster_autoscaler` | Registry module pinned with a version constraint |
| Terraform | CKV_TF_1 | `irsa_ebs_csi` | Registry module pinned with a version constraint |
| Terraform | CKV_TF_1 | `irsa_lb_controller` | Registry module pinned with a version constraint |
| Terraform | CKV_TF_1 | `vpc` | Registry module pinned with a version constraint; .terraform.lock.hcl pins providers |

## Fixed during the scan

- S3 state bucket: abort incomplete multipart uploads (CKV_AWS_300)
- CloudTrail bucket: versioning + noncurrent-version expiry (CKV_AWS_21)
- RDS: IAM database authentication enabled (CKV_AWS_161)
- Kubernetes: explicit namespaces on every object (CKV_K8S_21), readiness probe on ticket-worker (CKV_K8S_9)

## Alertmanager webhook (`POST /integrations/alertmanager`)

- Separate credential from user API keys: a bearer token (`OPSDESK_ALERT_WEBHOOK_TOKEN`) compared in constant time;
  a user `X-API-Key` is rejected (401), and the endpoint answers 503 when no token is configured (fail closed).
- On EKS the token is generated by Terraform, stored KMS-encrypted in Secrets Manager, synced to the app by External
  Secrets and to Alertmanager as a mounted Kubernetes Secret (`credentials_file`) — never in Git or Helm values.
- Payload is schema-validated (max 500 alerts per call, fingerprint length capped); alert text is rendered as text in
  the UI and only `http(s)` runbook/source links become links.
- Alert tickets are owned by a system user whose key hash can never match a real key; the endpoint is idempotent
  per fingerprint, so replayed deliveries cannot create ticket floods.
- Residual risk: in-cluster traffic from Alertmanager to the API is plain HTTP (the token is visible on the pod
  network); a service mesh with mTLS or an HTTPS listener on the API would close this.

## Known gaps (tracked, not hidden)

| Gap | Risk | Remediation | Target |
| --- | --- | --- | --- |
| App connects to RDS with the master user | Over-privileged DB access from the app | Create a least-privilege `opsdesk_app` role in a migration; keep master for migrations only | Stage 3 |
| ALB serves HTTP only (no domain/ACM certificate) | Traffic in clear text between browser and ALB | Inbound restricted to `allowed_cidrs`; add Route 53 + ACM + HTTPS listener with a real domain | Next steps |
| EKS API endpoint public (CloudShell IPs vary) | Larger attack surface on the control plane | Narrow `eks_public_access_cidrs`, or run Terraform from CI runners with fixed egress | Stage 3 |
| GitHub deploy role has AdministratorAccess | A compromised workflow on `main`/`demo` could change anything in the lab account | Trust limited to this repo's `main`, PRs and the approved `demo` environment; split into a read-only plan role and an apply role with a permissions boundary | Next steps |
| Demo API keys instead of SSO | Shared static credentials | Keys live in Secrets Manager and rotate with `terraform apply -replace`; SSO/OIDC is a next step | Next steps |
