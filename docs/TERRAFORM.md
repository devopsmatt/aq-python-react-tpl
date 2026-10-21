# Terraform Standards

Scope: all infrastructure as code under `infra/terraform/`. AWS service
configuration standards (ECS, RDS, WAF, Security Hub) are in [AWS.md](AWS.md);
this document covers how the Terraform is written, reviewed, scanned, costed
and applied.

Related: [AWS.md](AWS.md), [SECURITY.md](SECURITY.md), [CICD.md](CICD.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as described
in RFC 2119.

---

## 1. Principles

1. **Terraform is the only way infrastructure changes.** No console or CLI
   mutations in any environment. Read-only CLI (`describe`, `list`, `get`,
   `logs`) is fine. Drift is a finding (section 7).
2. **Every billable addition is costed and approved before it is applied**
   (section 6).
3. **Secure by default.** Encryption, logging, private networking and least
   privilege are module defaults, so a caller has to opt out explicitly and
   visibly, not opt in.
4. **Small blast radius.** State is split by environment and by lifecycle, so
   a plan never touches more than it must.
5. **Releases are applies too.** The ECS task definitions and services live in
   the `app` stack. A release is a Terraform apply of that stack with the
   release image digests as inputs ([CICD.md](CICD.md) section 8), so what
   runs always matches the code and there is no drift from CLI deploys.

---

## 2. Versions

| Component | Standard |
|---|---|
| Terraform CLI | `required_version = "~> 1.14"` (1.14.3 in use at the time of writing) |
| AWS provider | pinned with `~>` to a minor version in every root module |
| Lock file | `.terraform.lock.hcl` committed, with hashes for every CI and developer platform |

```bash
terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64
```

S3 native state locking (`use_lockfile`) needs Terraform 1.10 or later.
DynamoDB-based locking is deprecated and is not used.

---

## 3. Layout

```
infra/terraform/
  modules/                      reusable modules: no backend, no provider config
    network/  ecs-cluster/  ecs-service/  rds-postgres/  edge/  security-baseline/  observability/
  live/
    dev/  stage/  prod/  shared/
      network/                  one root module ("stack") per lifecycle
      data/                     RDS
      edge/                     ALBs, WAF, certificates, DNS
      security/                 Security Hub, GuardDuty, Config, KMS
      observability/            the LGTM services on ECS
      app/                      ECS cluster, task definitions, services (applied on every release)
```

- Each environment is a separate AWS account (dev, stage, prod), plus a
  `shared` account for CI roles, ECR, and the log archive. Accounts cost
  nothing and give the strongest isolation. Only `prod` holds federal data,
  and the prod account is the core of the authorization boundary.
- Stacks split by lifecycle and blast radius. Networking changes rarely and is
  dangerous; application-facing edge config changes often. Cross-stack values
  pass through `terraform_remote_state` outputs or SSM parameters, never
  copy-pasted IDs.
- Modules declare `required_providers` but never configure a provider or a
  backend.
- Third-party registry modules (for example `terraform-aws-modules`) are
  pinned to an exact version, and each upgrade is reviewed as a diff.

---

## 4. State and providers

```hcl
terraform {
  backend "s3" {
    bucket       = "ai101-tfstate-<account-id>-us-east-1"
    key          = "prod/app/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:us-east-1:<account-id>:key/<key-id>"
    use_lockfile = true
    use_fips_endpoint = true
  }
}

provider "aws" {
  region            = "us-east-1"
  use_fips_endpoint = true

  default_tags {
    tags = {
      Project            = "ai101"
      Environment        = "prod"
      Stack              = "app"
      Owner              = "<team>"
      CostCenter         = "<cost-center>"
      DataClassification = "federal-moderate"
      ManagedBy          = "terraform"
      Repository         = "ai-101"
    }
  }
}
```

State bucket requirements: versioning on, SSE-KMS with a customer managed key,
Block Public Access on, a bucket policy that denies non-TLS requests and
principals other than the CI roles and break-glass role, and access logging to
the log archive. State holds sensitive values, so read access to state is
treated as read access to secrets.

The tags double as cost allocation tags; they are activated in Billing so cost
reports split by `Environment` and `Stack`.

Some services have no FIPS endpoint in every region. When `use_fips_endpoint`
fails for a service, override that one endpoint in the provider `endpoints`
block and record the exception. Do not turn the flag off globally.

---

## 5. Writing Terraform

- **No secrets in code, tfvars or state.** RDS master passwords use
  `manage_master_user_password = true` (Secrets Manager owns and rotates
  them). Other secrets use write-only arguments or ephemeral resources where
  the provider supports them, or are created outside Terraform and only
  referenced by ARN. `*.tfvars` files that are not examples are listed
  explicitly in `.gitignore`.
- **Encryption:** every storage resource sets a customer managed KMS key
  (S3, RDS, Secrets Manager, Fargate ephemeral storage, CloudWatch Logs, SNS, ECR). Keys have rotation
  enabled and least-privilege key policies.
- **Logging:** every resource that can log does, into the log archive (see
  [AWS.md](AWS.md) and [OBSERVABILITY.md](OBSERVABILITY.md)).
- **Network:** nothing gets a public IP except load balancers. Security group
  rules name a source security group or a specific CIDR, never `0.0.0.0/0` on
  anything but the public ALB listener.
- **IAM:** no `*` actions on `*` resources. Policies are written with
  `aws_iam_policy_document`, and conditions (source VPC, `aws:PrincipalOrgID`,
  OIDC `sub`) narrow them further.
- **Protection:** stateful resources in `stage` and `prod` set
  `deletion_protection` (or `prevent_destroy`), and a destroy in a plan for
  those stacks needs a second approver.
- **Variables:** typed, described, and validated (`validation` blocks) where a
  wrong value is dangerous (CIDRs, instance classes, retention periods).
- **Formatting:** `terraform fmt` is canonical.

---

## 6. Cost-conscious IaC and the cost approval protocol

### 6.1 Protocol

Any PR that adds or changes a billable resource MUST, before merge:

1. Include an Infracost diff for every affected stack. CI posts it; the author
   adds usage assumptions in `infracost-usage.yml` where usage drives cost
   (requests, GB, log volume).
2. State in the PR body: the monthly delta per environment, the assumptions,
   at least one cheaper alternative and why it was rejected, and whether the
   cost scales with load.
3. Receive explicit approval from the designated cost approver, recorded as a
   PR review plus the `cost-approved` label. The cost check blocks merge when
   the delta is above zero and the label is missing.
4. For changes above the monthly threshold set by the approver, get approval
   before any Terraform is written. The design is what gets approved, not
   code already written.

```bash
infracost breakdown --path infra/terraform/live/prod/app --usage-file infracost-usage.yml
infracost diff --path infra/terraform/live/prod/app --compare-to infracost-base.json
```

Infracost needs an API key and sends resource types, regions and usage
figures (not state values) to its pricing API. The ISSO accepts that flow
once, and it is recorded in the SSP.

### 6.2 Cost guidelines

- **Fargate on Graviton first.** ECS tasks run on Fargate with the `ARM64`
  runtime platform, about 20% cheaper per vCPU-hour than x86 (table below).
  RDS uses Graviton instance classes. Every Aquia base image publishes a
  `linux/arm64` build.
- **No control plane to pay for.** ECS has no per-cluster charge (the AWS
  Price List has no cluster-hour SKU for it). Only task vCPU, memory and
  extra ephemeral storage are billed.
- **Right-size non-production:** single-AZ RDS and one NAT gateway in `dev`.
  Multi-AZ only in `stage` and `prod`.
- **Schedule non-production:** `dev` services scale their desired count to
  zero outside working hours (Fargate bills per second, with a one-minute
  minimum per task), and the `dev` RDS instance stops. A stopped RDS instance restarts by itself
  after seven days, so the schedule has to stop it again.
- **Endpoints versus NAT:** the S3 gateway endpoint is free and is always
  created. Interface endpoints cost per hour per AZ plus per GB, so add one
  only when the NAT data processing it saves, or its compliance value, is
  larger than its cost. Show the arithmetic in the PR.
- **Logs have tiers:** hot storage for the searchable window, then S3
  lifecycle to cheaper classes for the rest of the retention period
  ([OBSERVABILITY.md](OBSERVABILITY.md) section 7).
- **Guardrails:** each account has an AWS Budget with alerts at 50%, 80% and
  100% of forecast, plus Cost Anomaly Detection feeding the non-paging alert
  route.

### 6.3 Reference prices (us-east-1)

**Measured (2026-09-23, Fargate rows 2026-10-16)** from the public AWS Price
List API
(`pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<service>/current/us-east-1/index.json`;
the price files were published between 2026-09-11 and 2026-09-18). Monthly
figures use 730 hours.

| Item | List price | Monthly (fixed part) |
|---|---|---|
| Fargate ARM64 vCPU | $0.03238 per vCPU-hour | usage |
| Fargate ARM64 memory | $0.00356 per GB-hour | usage |
| Fargate x86 vCPU (for comparison) | $0.04048 per vCPU-hour | usage |
| Fargate x86 memory (for comparison) | $0.004445 per GB-hour | usage |
| Fargate ephemeral storage above the included 20 GB | $0.000111 per GB-hour | usage |
| ECS control plane | no charge | $0.00 |
| Application Load Balancer | $0.0225 per hour + $0.008 per LCU-hour | $16.43 per ALB before LCUs |
| AWS WAF web ACL | $5.00 per month | $5.00 |
| AWS WAF rule or managed rule group | $1.00 per month each | $1.00 each |
| AWS WAF requests | $0.60 per million | usage |
| VPC interface endpoint | $0.01 per hour per AZ + $0.01 per GB | $7.30 per endpoint per AZ |
| Security Hub CSPM checks | $0.001 each (first 100k), $0.0008 (next 400k), $0.0005 after | usage |
| Security Hub finding ingestion | free for the first 10,000 per account per region per month, then $0.00003 each | usage |

Not measured here, and to be taken from Infracost when a PR proposes them:
NAT gateway, RDS instances and storage, GuardDuty, Inspector, AWS Config,
CloudWatch Logs and Container Insights, S3, Lambda.

Worked example for the hello-world app, from the measured prices: one task at
0.25 vCPU and 0.5 GB on ARM64 costs $0.009875 per hour, which is $7.21 per
month. `stage` and `prod` each run 2 web and 2 api tasks ($28.84 per month
each). `dev` runs 1 of each ($14.42 per month around the clock, less when
scaled to zero at night). Blue/green and canary deployments double the task
count only while a deployment runs. Each environment's public and internal
ALBs add $32.85 per month before LCUs. Compared with EKS, ECS also avoids
$73 per month per cluster in control plane fees.

---

## 7. Validation, scanning and drift

Run from the repository root. The same commands run in the hooks and in CI.

```bash
terraform fmt -check -recursive infra/terraform
for d in infra/terraform/live/*/*/; do terraform -chdir="$d" init -backend=false -input=false && terraform -chdir="$d" validate; done
tflint --recursive --chdir=infra/terraform
scripts/checkov-gate.sh .
trivy config --severity MEDIUM,HIGH,CRITICAL --exit-code 1 infra/terraform
```

**Checkov severity filtering, measured (checkov 3.2.510, 2026-09-23):** on a
probe module with two known failures (an unencrypted bucket and SSH open to
the world), a plain run reported "Passed checks: 5, Failed checks: 2".
`--check MEDIUM,HIGH,CRITICAL` ran zero checks, printed nothing, and exited 0.
Checkov gets severities only from the Prisma Cloud platform (an API key), so
without a key a severity filter turns the scan into a silent pass. The
standard is therefore:

- Checkov runs with **no severity filter**. Every failed check blocks,
  which is stricter than a MEDIUM floor. Lists of specific check IDs
  (`--check CKV_AWS_24,...`) are still fine; severity names are not.
- An accepted exception is a reasoned skip: an inline
  `#checkov:skip=CKV_AWS_XXX:<why this is safe here>` at the finding, or a
  `skip-check` entry in the repository Checkov config with a reason comment.
  Both are reviewed like code.
- **The gate proves Checkov evaluated checks.** `scripts/checkov-gate.sh`
  first scans a canary it writes to a temporary directory at run time, using
  the same flags and config as the real scan. The canary MUST report every
  expected failure (listed below). If it passes, or misses one, the gate exits
  non-zero before the real scan runs. The canary is never committed, so no
  other scanner sees it.

**Canary gate, measured (2026-10-15):** with the standard flags the canary
failed on `CKV_AWS_24` and the real probe tree then passed
("Passed checks: 3, Failed checks: 0"). With `--check MEDIUM` added to the
same script, the canary passed and the gate exited 1 with
"canary PASSED - checkov is not evaluating checks". A misconfigured scan now
fails closed instead of reporting clean.

The gate lives in `scripts/checkov-gate.sh`. One run covers Terraform,
Dockerfiles and GitHub Actions together: the canary holds one known failure
per framework (`CKV_AWS_24` for an open SSH ingress, `CKV_DOCKER_3` for a
Dockerfile without `USER`, `CKV_GHA_2` for an untrusted expression in a
`run:` step), and all three must be reported before the real scan runs. Both
runs read `.checkov.yml`, so local and CI scans use the same frameworks and
options. Locally the gate uses the installed `checkov`:

```bash
scripts/checkov-gate.sh .
```

In CI, `bridgecrewio/checkov-action` does the scanning. The workflow writes
the canary (`scripts/checkov-gate.sh --write-canary`), runs the action on it
with `soft_fail` and JSON output, fails the job unless
`scripts/checkov-gate.sh --assert-canary` finds every canary check among the
failed checks, and only then runs the action on the repository.

**Measured (2026-10-15 and 2026-10-16):** a workflow with
`permissions: write-all` failed nothing and is not a usable canary. With the
three-framework canary, a run on this repository reported the canary
failures as expected, then "Passed checks: 219, Failed checks: 0, Skipped
checks: 6" (the six reasoned `CKV_DOCKER_2` skips) for Terraform and
Dockerfiles, and 60 passed for GitHub Actions.

Plan and apply:

- Every PR that touches a stack runs `terraform plan` for that stack with a
  read-only plan role, and the plan summary is attached to the PR. Full plan
  output can contain sensitive values, so it is kept as a CI artifact with
  restricted access, not posted as a comment.
- Apply runs only from CI, after merge, in a GitHub environment with required
  reviewers for `stage` and `prod`, using the same saved plan that was
  reviewed. Nobody applies to `stage` or `prod` from a workstation.
- A nightly job runs `terraform plan -detailed-exitcode` on every stack. Exit
  code 2 (drift) opens a finding for CM-3 and CM-6 follow-up.

---

## 8. CI identities

- GitHub Actions authenticates to AWS with OIDC. There are no long-lived
  access keys.
- Per account, a plan role (read-only plus state read) and an apply role.
  Trust policies pin `token.actions.githubusercontent.com:aud` to
  `sts.amazonaws.com`, and pin `sub` to this repository and, for apply, to the
  matching GitHub environment (for example
  `repo:<org>/ai-101:environment:prod`).
- Apply roles are scoped to the services this project manages and cannot
  change their own trust policy or the organization guardrails.
