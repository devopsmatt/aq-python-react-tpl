# AWS Platform Standards

Scope: how AWS services are configured for this system: account structure,
networking, Amazon ECS on AWS Fargate, container images, PostgreSQL, WAF,
Security Hub, logging and keys. How the Terraform is written, costed and
applied is in [TERRAFORM.md](TERRAFORM.md).

Related: [TERRAFORM.md](TERRAFORM.md), [SECURITY.md](SECURITY.md),
[OBSERVABILITY.md](OBSERVABILITY.md), [CICD.md](CICD.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as described
in RFC 2119. Every addition described here that costs money goes through the
cost approval protocol in [TERRAFORM.md](TERRAFORM.md) section 6 before it is
built.

---

## 1. Region, partition and service eligibility

- **Default (assumption, confirm with the AO):** AWS commercial partition,
  `us-east-1` primary. The AWS US East and US West regions hold a FedRAMP
  Moderate authorization. GovCloud (US) is used only if the authorizing
  official requires FedRAMP High, ITAR, or GovCloud-only services. It costs
  more, uses the `aws-us-gov` partition in every ARN, and (per AWS's launch
  post, October 2025) does not offer the ECS built-in linear and canary
  deployment strategies this template relies on.
- Before any service is used, confirm it is listed for FedRAMP Moderate in the
  chosen region on AWS "Services in Scope by Compliance Program". A service
  that is not in scope cannot process federal data.
- The AWS FedRAMP package and customer responsibility matrix define which
  controls are inherited. The SSP cites them. Nothing here claims an
  inherited control as our own implementation.

---

## 2. Accounts and identity

- AWS Organizations with separate accounts: `dev`, `stage`, `prod`,
  `shared` (CI roles, ECR), `security` (delegated admin for Security Hub,
  GuardDuty, Inspector, Config), and `log-archive`.
- Service control policies deny: leaving the organization; using
  non-approved regions; disabling or deleting CloudTrail, Config, GuardDuty,
  Security Hub, or Access Analyzer; root user actions; and creating IAM users
  or access keys.
- People sign in through IAM Identity Center federated to the IdP, with MFA
  (phishing-resistant for privileged roles). Permission sets are role-based
  and least privilege. Production write access is just-in-time and time-bound.
- There are no IAM users and no long-lived access keys. CI uses GitHub OIDC
  ([TERRAFORM.md](TERRAFORM.md) section 8). ECS tasks use IAM task roles.
- Root credentials are sealed break-glass. Their use pages the P0 route
  ([OBSERVABILITY.md](OBSERVABILITY.md)).

### 2.1 Application sign-in

The template's login is **Google SSO**: OIDC authorization code with PKCE
against `https://accounts.google.com`, limited to the organization's Google
Workspace domain, with phishing-resistant MFA enforced by Workspace policy
([NEXTJS.md](NEXTJS.md) section 4, [PYTHON.md](PYTHON.md) 3.4). Issuer, client
id and allowed domain are configuration, so a fork can point the same code at
its agency IdP. Google is an external service in the SSP. The Google OAuth
client secret lives in Secrets Manager. The API trusts only the BFF's
short-lived ES256 tokens, signed with the KMS key `api-token-signing`
(section 10).

---

## 3. Networking

- One VPC per environment account. Three AZs in `stage` and `prod`, two in
  `dev`.
- Subnets: public (internet-facing ALB only), private-app (ECS tasks and the
  internal ALB), private-data (RDS, no route to the internet).
- Tasks never get public IPs (`assign_public_ip = false`).
- No SSH, no bastions, no EC2 hosts to log in to. Operator access to a running
  task uses ECS Exec (section 4.3), which is off by default.
- VPC Flow Logs on every VPC, to the log archive.
- **Egress control (SC-7(5), deny by default, allow by exception).** Baseline
  (low cost): one security group per ECS service with explicit egress rules
  (web to the internal ALB, api to RDS, every task to the telemetry collector
  and the VPC endpoints it needs), Route 53 Resolver DNS Firewall with an
  allowlist of required domains, and VPC endpoints for AWS APIs where
  justified. AWS Network Firewall (managed L7 egress filtering) is added only
  if the 3PAO or AO requires it, as a separate cost-approved change.
- Gateway endpoint for S3 in every VPC (free). Interface endpoints (ECR, Logs,
  Secrets Manager, STS, KMS) per the cost rule in
  [TERRAFORM.md](TERRAFORM.md) section 6.2.

---

## 4. Amazon ECS on AWS Fargate

### 4.1 Why Fargate, and what it changes

- All workloads run on Fargate, on ARM64 (Graviton). There are no container
  hosts to patch, harden or log in to, and ECS has no control-plane charge;
  only task vCPU and memory are billed ([TERRAFORM.md](TERRAFORM.md) 6.3).
- The application's cryptographic boundary is the FIPS module inside our
  runtime image (measured, [PYTHON.md](PYTHON.md) 3.7,
  [NEXTJS.md](NEXTJS.md) 7). The Fargate host and kernel are AWS-managed.
  Whether they run in FIPS mode in the chosen region is an inherited item:
  confirm it in the AWS FedRAMP package and record it in the SSP. Do not
  assert it.
- ECS has no admission controller. The controls a Kubernetes policy engine
  would enforce at admission are enforced here by IAM, by Terraform
  validation, by the deploy pipeline, and detectively by Security Hub
  (section 4.5).

### 4.2 Clusters

- One ECS cluster per environment for the application, plus one
  `observability` cluster per boundary ([OBSERVABILITY.md](OBSERVABILITY.md)
  section 8).
- Capacity providers: `FARGATE` everywhere. `FARGATE_SPOT` MAY be used in
  `dev` only.
- Container Insights on. Security Hub's ECS checks look for it, and its
  CloudWatch metric cost goes into the Infracost estimate.
- ECS Exec configuration at the cluster level: session logging to CloudWatch
  Logs and S3, encrypted with the `logs` KMS key.
- Fargate ephemeral storage is encrypted with a customer managed KMS key
  through the cluster's managed storage configuration.

### 4.3 Task definitions

Every task definition:

| Setting | Standard |
|---|---|
| `requiresCompatibilities` / `runtimePlatform` | `FARGATE`, `LINUX` / `ARM64` |
| `networkMode` | `awsvpc` |
| `image` | ECR image by digest (`...@sha256:<64 hex>`), never a tag. A Terraform `validation` block rejects anything else. |
| `containerDefinitions` | The application container (listening on `127.0.0.1:8080` only) plus the `tls-sidecar` container (section 4.6). The sidecar is the only port mapping (8443). |
| `user` | `65532` (the `nonroot` user of the Aquia images) |
| `readonlyRootFilesystem` | `true`. Writable paths (`/tmp`, `/app/.next/cache`) are task volumes mounted at those paths. |
| `privileged` | not set (false) |
| `linuxParameters.capabilities.drop` | `["ALL"]` |
| `linuxParameters.initProcessEnabled` | `true` |
| `secrets` | Secrets Manager or SSM Parameter Store ARNs via `valueFrom`. Secrets never go in `environment`. |
| `logConfiguration` | FireLens (`awsfirelens`) to CloudWatch Logs and Loki ([OBSERVABILITY.md](OBSERVABILITY.md)) |
| `cpu` / `memory` | Set from measured load-test usage, not guessed. Hello-world start point: 0.25 vCPU and 0.5 GB per task. |

- **Two roles, never one.** The execution role pulls the image, reads the
  task's secrets and writes logs. The task role carries only the
  application's own permissions (for example `rds-db:connect` for one
  database user).
- **ECS Exec** (`enableExecuteCommand`) is off for `stage` and `prod`
  services. It is turned on through a Terraform change only for a recorded
  break-glass session, and every session is logged.

### 4.4 Services

- `launch_type` via the `FARGATE` capacity provider, `platform_version =
  "LATEST"`, `assign_public_ip = false`, private-app subnets only.
- One security group per service (section 3). RDS admits only the api
  service's security group.
- `desired_count` of at least 2, spread across AZs, in `stage` and `prod`.
  `dev` runs 1 and scales to 0 outside working hours.
- Service auto scaling on CPU and ALB requests per target, with minimums and
  maximums set from the load test.
- Deployments use the ECS built-in strategies ([CICD.md](CICD.md) section 8):
  rolling in `dev`, blue/green in `stage`, canary in `prod`. All have the
  deployment circuit breaker and CloudWatch alarm rollback enabled. Blue/green
  and canary need two target groups per service and about twice the task
  capacity during a deployment. That temporary cost is part of the estimate.

### 4.5 Enforcing what Kubernetes admission would have enforced

| Control | How it is enforced on ECS |
|---|---|
| Only approved, signed images run | The deploy pipeline runs `cosign verify` on every digest before writing it into the `app` stack. Task definitions accept only ECR digests (Terraform validation). ECR pull is limited to the environment accounts. |
| Only the pipeline changes what runs | Only the Terraform apply role may `ecs:RegisterTaskDefinition`, `ecs:UpdateService` and `iam:PassRole` for task roles. A `prod` SCP denies those actions to everyone else. |
| Hardened container settings | Terraform module defaults (section 4.3), Checkov in CI, and Security Hub's ECS controls in every account. |
| Network isolation between services | Per-service security groups (section 3). |
| Secrets not in plain environment variables | `secrets` with `valueFrom` only, checked by Checkov and Security Hub. |

### 4.6 Ingress and TLS

- An internet-facing ALB, with AWS WAF attached (section 7), fronts the web
  service. The api service sits behind an internal ALB, which also lets ECS
  run canary deployments for it.
- TLS policy on every ALB listener: `ELBSecurityPolicy-TLS13-1-3-FIPS-PQ-2025-09`.
  That is TLS 1.3 only, FIPS ciphers, and hybrid post-quantum key exchange
  where the client supports it (policy name confirmed in the AWS ELB
  documentation, 2026-09-23). If a required client cannot do TLS 1.3, the
  fallback is `ELBSecurityPolicy-TLS13-1-2-FIPS-PQ-2025-09`, with the client
  named in an SSP exception.
- Certificates come from ACM using ECDSA P-256 (ACM key algorithm
  `EC_prime256v1`).
- HTTP on port 80 only redirects to HTTPS.
- **Decision (SC-8): every ALB-to-task hop is TLS 1.3, using a per-task
  self-signed certificate.** Each web and api task runs a `tls-sidecar`
  container next to the application. The sidecar generates a throwaway ECDSA
  P-256 certificate at start, then serves TLS 1.3 on port 8443 and proxies to
  the application on `127.0.0.1:8080`. Containers in an `awsvpc` task share
  one network namespace, so the application is unreachable except through
  the sidecar. The ALB does not validate target certificates, so nothing has
  to be issued, stored or rotated, and there is no AWS cost. The sidecar is
  built from `fips-140-3` plus Wolfi's `nginx`, so the TLS runs in the FIPS
  module.
- Per the AWS ELB documentation, the ALB's backend TLS policy follows the
  listener policy, and TLS 1.3 listener policies map to backend policies that
  include TLS 1.3. The first deployment confirms it: target health checks
  over HTTPS must pass against the TLS 1.3-only sidecar.
- **Measured (2026-10-16), the files below, built for ARM64:** run as uid
  65532 with a read-only root filesystem and `/tmp` as the only writable
  path, the sidecar logged nothing, negotiated TLS 1.3 with
  `TLS_AES_256_GCM_SHA384`, refused TLS 1.2, proxied a request with status
  200, and ran with OpenSSL FIPS provider 3.1.2 active. Shellcheck was clean.
  With the base pinned by version and digest, Checkov reported 0 failed checks
  (1 reasoned skip) and Trivy config 0 misconfigurations. Started without
  `-e /dev/stderr`, nginx printed an `[alert]` trying to open its default log
  path, which is why the flag is there.

`containers/tls-sidecar/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
# checkov:skip=CKV_DOCKER_2: health is checked by ALB target health checks on ECS
FROM ghcr.io/aquia-inc/base-docker-images/fips-140-3:<version>@sha256:<digest>
USER root
RUN apk add --no-cache nginx
COPY nginx.conf /etc/nginx/tls-sidecar.conf
COPY --chmod=0755 entrypoint.sh /usr/local/bin/tls-sidecar
USER nonroot
ENTRYPOINT ["/usr/local/bin/tls-sidecar"]
```

`containers/tls-sidecar/entrypoint.sh`:

```sh
#!/bin/sh
# Generate a throwaway ECDSA P-256 certificate for this task, then serve TLS 1.3
# in front of the application on 127.0.0.1:8080. The ALB does not validate
# target certificates; the key never leaves the task's writable /tmp volume.
set -eu
mkdir -p /tmp/tls /tmp/nginx
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj "/CN=${TLS_SIDECAR_CN:-task}" \
  -keyout /tmp/tls/key.pem -out /tmp/tls/cert.pem 2>/dev/null
exec nginx -e /dev/stderr -g 'daemon off;' -c /etc/nginx/tls-sidecar.conf
```

`containers/tls-sidecar/nginx.conf`:

```nginx
worker_processes 1;
pid /tmp/nginx/nginx.pid;
error_log /dev/stderr warn;
events {}
http {
  access_log off;
  server_tokens off;
  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path /tmp/nginx/proxy;
  fastcgi_temp_path /tmp/nginx/fastcgi;
  uwsgi_temp_path /tmp/nginx/uwsgi;
  scgi_temp_path /tmp/nginx/scgi;
  client_max_body_size 1m;
  server {
    listen 8443 ssl;
    ssl_protocols TLSv1.3;
    ssl_certificate /tmp/tls/cert.pem;
    ssl_certificate_key /tmp/tls/key.pem;
    location / {
      proxy_pass http://127.0.0.1:8080;
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
    }
  }
}
```

ALB access logs record every request, so the sidecar's own access log is off.
The application container sets `dependsOn` the sidecar being started, and the
target group health check uses HTTPS on port 8443.

---

## 5. Container images and ECR

- Every image this project builds starts from an Aquia base image
  (`ghcr.io/aquia-inc/base-docker-images/...`), pinned by digest
  ([PYTHON.md](PYTHON.md) section 8, [NEXTJS.md](NEXTJS.md) section 7).
- Built images are pushed only to private ECR repositories in the `shared`
  account: tag immutability on, KMS encryption, a lifecycle policy that keeps
  release images and expires untagged ones, and a repository policy granting
  pull only to the environment accounts.
- Amazon Inspector enhanced scanning (continuous) on ECR. Findings flow to
  Security Hub and count toward the zero-fixable-CVE gate
  ([SECURITY.md](SECURITY.md) section 4).
- Images are deployed by digest, never by tag.
- Third-party images that run as tasks (the LGTM stack, Grafana Alloy,
  Fluent Bit for FireLens) are mirrored into ECR by digest and pass the same
  Trivy gate before use. Task definitions reference only ECR. An upstream
  image with fixable MEDIUM or higher findings is rebuilt on an Aquia base or
  tracked per [SECURITY.md](SECURITY.md) section 4.4.

---

## 6. PostgreSQL (Amazon RDS)

| Setting | dev | stage / prod |
|---|---|---|
| Engine | RDS for PostgreSQL, current major version | same |
| Instance class | Graviton burstable, smallest that passes tests | Graviton, sized from the load test |
| Availability | Single-AZ | Multi-AZ |
| Storage | gp3, encrypted with a CMK | same, with storage autoscaling and a maximum |
| Backups | 7-day retention | 35-day retention, plus cross-region copies through AWS Backup (cost approval) |
| Deletion protection | off | on, with a final snapshot required |

Everywhere:

- `publicly_accessible = false`, in private-data subnets. The security group
  admits only the api service.
- TLS required: parameter `rds.force_ssl = 1`, `ssl_min_protocol_version = TLSv1.3`.
  Clients verify the server certificate and hostname against the RDS CA
  bundle.
- Authentication: the master password is managed by RDS in Secrets Manager
  (`manage_master_user_password = true`) and used only for break-glass.
  The application uses IAM database authentication, with separate migration
  and runtime roles ([PYTHON.md](PYTHON.md) 3.6).
- Auditing: `pgaudit` in `shared_preload_libraries`, configured for DDL, role
  changes, and access to sensitive tables. `log_connections` and
  `log_disconnections` on. Logs exported to CloudWatch Logs
  (`enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]`) and on to the
  log archive.
- Monitoring: Enhanced Monitoring and Database Insights or Performance
  Insights, encrypted with the CMK.
- `auto_minor_version_upgrade` on, inside a defined maintenance window.
  Major upgrades are rehearsed on a `stage` snapshot first.

---

## 7. AWS WAF

- One web ACL per internet-facing ALB.
- Rules, in priority order:
  1. Allow or block lists maintained as IP sets, if the product needs them.
  2. `AWSManagedRulesAmazonIpReputationList`
  3. `AWSManagedRulesAnonymousIpList`
  4. `AWSManagedRulesKnownBadInputsRuleSet`
  5. `AWSManagedRulesCommonRuleSet`
  6. `AWSManagedRulesSQLiRuleSet`
  7. `AWSManagedRulesLinuxRuleSet`
  8. A rate-based rule per source IP. The limit is set from measured traffic,
     not guessed.
  9. Geographic restriction, only if the AO requires US-only access.
- Rollout: new rules start in `COUNT` in `dev`, are tuned against
  real test traffic, then run in `BLOCK`. `prod` runs `BLOCK`. Exclusions are
  scoped to a single rule and URI, never a whole rule group.
- The request body is inspected only up to the size limit for ALB.
  Oversize handling is set explicitly on every body-inspecting rule, not left
  to the default.
- Logging: every request to a log group or bucket whose name starts with
  `aws-waf-logs-`. The `authorization` and `cookie` headers are redacted.
- Cost: $5 per web ACL per month, $1 per rule or managed rule group per
  month, $0.60 per million requests (measured, [TERRAFORM.md](TERRAFORM.md)
  6.3). Paid rule groups such as Bot Control and Account Takeover Prevention
  go through cost approval first.

---

## 8. Security Hub and the detection services

AWS split the original Security Hub into "Security Hub CSPM" (posture
checks against standards) and a newer Security Hub that correlates findings
across services; the Price List carries both. The standards below run in
Security Hub CSPM.

- Enabled in every account and every used region, with the `security`
  account as delegated administrator and central configuration through
  Organizations. Cross-region aggregation goes to `us-east-1`.
- Standards enabled:
  - AWS Foundational Security Best Practices
    (`arn:aws:securityhub:<region>::standards/aws-foundational-security-best-practices/v/1.0.0`)
  - NIST SP 800-53 Rev. 5
    (`arn:aws:securityhub:<region>::standards/nist-800-53/v/5.0.0`)
- AWS Config records all supported resource types in every account (the
  CSPM controls depend on it).
- Integrated producers: GuardDuty (with Runtime Monitoring for ECS on
  Fargate, where GuardDuty manages its own agent in each task), Inspector
  (ECR), IAM Access Analyzer, and Macie for S3 buckets that hold federal data.
  Each paid producer goes through cost approval.
- Routing: an EventBridge rule on imported findings sends CRITICAL and HIGH
  from `prod` to the P1 route and MEDIUM to the ticket route
  ([OBSERVABILITY.md](OBSERVABILITY.md) section 5).
- Suppression is not a fix. A suppressed finding needs a linked risk
  acceptance or POA&M item ([SECURITY.md](SECURITY.md) section 4.4).
- Pre-release gate: a read-only query of active, unsuppressed findings with
  severity MEDIUM or above, filtered to those with a fix available, must
  return zero for the target account ([SECURITY.md](SECURITY.md) section 4).

---

## 9. Audit logging (AWS-native)

| Source | Destination | Notes |
|---|---|---|
| CloudTrail (organization trail) | log-archive S3 | Management events in all regions, log file validation on, KMS. S3 data events for buckets holding federal data. Records every ECS API call, including deployments. |
| VPC Flow Logs | log-archive S3 | All VPCs. |
| ECS task logs | CloudWatch Logs via FireLens, exported to log-archive | Every container ([OBSERVABILITY.md](OBSERVABILITY.md)). |
| ECS Exec sessions | CloudWatch Logs and S3 | Every operator session (section 4.2). |
| ALB access logs | log-archive S3 | Every ALB. |
| WAF logs | `aws-waf-logs-*` | Section 7. |
| RDS logs | CloudWatch Logs | Section 6. |
| Route 53 Resolver query logs | log-archive S3 | Needed for egress investigations. |

The log archive buckets use S3 Object Lock (compliance mode) and a CMK, and
deny deletes (AU-9). Retention follows OMB M-21-31, which the FedRAMP AU-11
parameter references: 12 months active plus 18 months cold
([OBSERVABILITY.md](OBSERVABILITY.md) section 7).

---

## 10. Keys and secrets

- Customer managed KMS keys per purpose: `data` (RDS, S3 with federal data),
  `logs`, `secrets` (Secrets Manager), `fargate-storage`, `tfstate`, `signing`
  (ECC_NIST_P256, sign and verify only, used by cosign), and
  `api-token-signing` (ECC_NIST_P256, used by the web BFF to sign the API's
  internal access tokens; only the web task role may sign, and only the api
  task role may read the public key). Encryption keys and signing keys are
  never shared.
- Automatic rotation on for symmetric keys. Key policies grant use to named
  roles only. `kms:ScheduleKeyDeletion` is limited to break-glass, and a
  deletion attempt pages P0.
- Secrets Manager holds every application secret, with rotation where the
  service supports it. ECS injects them at task start (`secrets` with
  `valueFrom`). They are never baked into images or task definition
  environment variables.
