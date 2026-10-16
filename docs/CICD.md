# CI/CD Standards

Scope: branching, pull requests, versioning, GitHub Actions workflows, build
and release, environment promotion, and blue/green and canary deployments.

Related: [SECURITY.md](SECURITY.md) (scan battery and release gates),
[TERRAFORM.md](TERRAFORM.md) (plan and apply), [AWS.md](AWS.md) (ECS),
[OBSERVABILITY.md](OBSERVABILITY.md) (analysis metrics and alerts).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as described
in RFC 2119.

---

## 1. Repository layout

```
.github/workflows/     CI/CD workflows
.githooks/             pre-commit and pre-push hooks
scripts/               validate-security.sh and other repo scripts
python/api/            FastAPI service (uv workspace, see PYTHON.md)
web/                   Next.js application (see NEXTJS.md)
infra/terraform/       modules and live stacks, including the ECS services (see TERRAFORM.md)
containers/tls-sidecar/ TLS 1.3 sidecar image used by every ECS task (see AWS.md 4.6)
docs/                  standards, runbooks, compliance evidence pointers
docker-compose.yml     local development stack
```

---

## 2. Branching and protection

- **Trunk-based.** `main` is the primary branch and is always deployable.
  There is no long-lived integration branch. Work happens on short-lived
  `feature/*`, `fix/*` and `chore/*` branches cut from `main`.
- Branches merge into `main` by PR with **squash**, so each change lands as
  one Conventional Commit. Merge commits and rebase merging are disabled.
- Nobody pushes directly to `main`. Force pushes and deletion of `main` are
  blocked.
- Releases are tags on `main` (section 3), so "always deployable" is enforced
  by the gates every PR passes, not by a separate release branch.

Repository ruleset for `main` (targeting the default branch):

| Rule | Setting |
|---|---|
| Require a pull request | yes |
| Required approvals | 1 |
| Require review from CODEOWNERS | yes (`.github/CODEOWNERS`) |
| Dismiss stale approvals on new commits | yes |
| Require conversation resolution | yes |
| Require status checks | the PR battery (section 5), added as each workflow lands |
| Require signed commits | yes |
| Block force pushes and deletion | yes |
| Merge queue | yes, once required status checks exist |
| Allowed merge method | squash |
| Bypass list | repository admins, for merging pull requests only |

- **Who can merge:** every change needs an approving review from a code owner,
  so only code owners can get a PR into `main`. The repository lives in a
  personal account, where GitHub cannot limit the merge button to named users;
  code-owner review is the control.
- **Single-maintainer bypass:** GitHub never lets a PR author approve their
  own PR. While the only code owner is the repository owner, the ruleset lets
  repository admins bypass the review requirement **when merging a pull
  request only**. Direct pushes to `main` stay blocked for everyone. Once a
  second code owner exists, remove the bypass.
- **Signed commits:** every contributor signs commits (SSH or GPG signing key
  registered on GitHub, `git config commit.gpgsign true`). Squash commits
  that GitHub creates on merge are signed by GitHub.
- **Merge queue instead of "require branches to be up to date":** with the
  up-to-date rule, every merge forces every other open PR to rebase and rerun
  the whole battery, which multiplies CI minutes. The merge queue tests each
  PR once against the actual future head of `main`. Workflows that gate
  merges MUST therefore also trigger on `merge_group`.
- **Tag protection:** a ruleset restricts creating, updating and deleting
  `v*` tags to the release automation.

---

## 3. Commits and versioning

- PR titles follow Conventional Commits (`feat:`, `fix:`, `perf:`,
  `refactor:`, `docs:`, `test:`, `build:`, `ci:`, `chore:`, with `!` for
  breaking changes). A PR check enforces it; the squash commit takes the PR
  title.
- Semantic versioning for the product: `feat` bumps minor, `fix` and `perf`
  bump patch, `!` bumps major. A breaking API contract change detected by
  `oasdiff` ([PYTHON.md](PYTHON.md) 3.2) requires `!`.
- **release-please** runs on `main`. It keeps a release PR open that carries
  the next version and changelog. Merging that PR creates the `vX.Y.Z` tag
  and the GitHub release.
- Why release-please rather than semantic-release: semantic-release pushes a
  release commit straight to the branch, which would need a bypass of the
  "PR required" and "signed commits" rules on `main`. release-please makes the
  same change through a reviewed PR.
- One product version covers every component. Change management (CM-3) and
  the SSP then track one system version, and every image in a release carries
  that version plus its git SHA.

---

## 4. Environments and promotion

| Environment | Deployed from | Strategy | Approval | Data |
|---|---|---|---|---|
| local | `docker compose up --build` | n/a | n/a | synthetic |
| `dev` | every merge to `main` | rolling | none | synthetic |
| `stage` | release tag `vX.Y.Z` | blue/green | none; the release gates run here | synthetic, prod-like config |
| `prod` | the same digests after the `stage` gates pass | canary | human approval gate (section 4.2) | production |

- **Build once, promote the digest.** Release images are built once from the
  release tag, and the same digests go to `stage` and then `prod`. Nothing is
  rebuilt between environments. Environment configuration comes from the
  environment at runtime ([NEXTJS.md](NEXTJS.md) section 3).
- `dev` runs images built from each `main` commit. The full e2e, accessibility
  and DAST suites run there after each deploy.
- The pre-release gates in [SECURITY.md](SECURITY.md) section 7 (including
  Shannon) run against `stage` before `prod` promotion is offered.

### 4.1 Local development

```bash
docker compose up --build               # full stack: web, api, postgres, telemetry
docker compose up -d postgres           # just the database, for integration tests
docker compose logs -f api
docker compose down -v                  # stop and delete local volumes
```

Workload images in compose use the same Dockerfiles as production. Third-party
supporting images used only locally (PostgreSQL, a local LGTM telemetry
image) are pinned by digest and never deployed.

### 4.2 Production approval gate

`prod` never deploys without a person approving it:

- The `prod` GitHub environment has required reviewers (at least one), with
  "prevent self-review" on, so the person who started the release cannot
  approve it. Administrator bypass of environment protection rules is off.
- Deployment to the `prod` environment is allowed only from `v*` release
  tags.
- The approval request appears only after the `stage` gates pass. It links
  the release notes, the evidence bundle (scans, SBOMs, Shannon report) and
  the canary plan.
- The same gate covers `terraform apply` for `prod` stacks.
- GitHub records who approved and when. That record is part of the change
  evidence (section 9).
- `dev` and `stage` deploy automatically. `stage` is guarded by its release
  gates, not by a person.

---

## 5. Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `pr.yml` | `pull_request`, `merge_group` | The full battery, filtered by changed paths |
| `build.yml` | push to `main`, `v*` tags | Build, scan, SBOM, sign, push images to ECR, then call `deploy.yml` for `dev` (main) or `stage` (tags) |
| `release.yml` | push to `main` | release-please (maintains the release PR) |
| `deploy.yml` | `workflow_call`, `workflow_dispatch` | Reusable deploy: verify signatures, run migrations, then `terraform apply` of the environment's `app` stack with the release digests (section 8) |
| `terraform.yml` | push to `main` (applies `dev`), `v*` tags (applies `stage`, then `prod` behind the human gate) | Apply the reviewed platform stacks per environment. PR-time checks, plans and Infracost run in `pr.yml` |
| `drift.yml` | nightly schedule | `terraform plan -detailed-exitcode` on every stack |
| `nightly-scan.yml` | nightly schedule | Rescan deployed digests and SBOMs; full-history secret scans |
| `shannon.yml` | `workflow_dispatch` | Pre-release Shannon run against `stage` |

`pr.yml` jobs (each one a required status check, and skipped when its paths
did not change):

- **python** (`python/api`): lint group,
  per-module mypy, pytest with the coverage gate, diff coverage, bandit,
  semgrep, pylint, pip-audit, osv-scanner, OpenAPI drift and `oasdiff`.
- **web:** eslint, prettier, tsc, vitest with coverage, Playwright with axe,
  semgrep, bearer, njsscan, retire, npm audit, generated-types drift.
- **terraform:** see [TERRAFORM.md](TERRAFORM.md) section 7.
- **workflows:** actionlint, zizmor.
- **repo:** trufflehog, gitleaks, trivy fs, checkov (Dockerfiles, Actions),
  shellcheck, non-ASCII.
- **images:** build every changed image (no push) and run Trivy on it, plus
  the unit suite inside the FIPS runtime image.
- **conventional-title:** PR title check.

Path filtering happens per job, never with workflow-level `paths:`. A first
`changes` job works out which areas the PR touches, and later jobs run with
`if:` on its outputs. A skipped job satisfies a required check. A workflow
that never starts because of `paths:` leaves its required checks pending
forever and blocks the PR.

### 5.1 Cost controls

Actions minutes are a cost like any other, and the pipeline is designed to
spend them only where a change can affect the result:

- **Run only what a change can affect:** path-filtered jobs as above.
  Playwright, image builds, and the FIPS-image test run only when `web/`,
  `python/` or a Dockerfile changes. Terraform plans run only for stacks
  under changed paths.
- **Merge queue instead of up-to-date branches** (section 2): each PR is
  tested once against its future base, rather than once per merge of another
  PR.
- **Cancel superseded runs:** `concurrency` with `cancel-in-progress: true` on
  PR workflows.
- **Smallest standard GitHub-hosted runner** by default. A larger runner needs
  a measured reason in the PR (a job that is actually CPU-bound).
- **Dependency caches** keyed on lockfile hashes in PR workflows (never in
  release workflows, see section 6).
- **No CI infrastructure at all.** Deploys call the public (FIPS) AWS APIs for
  ECS, ECR and Terraform state from GitHub-hosted runners through OIDC, so
  no self-hosted runners exist and nothing runs between deploys.
- **Scheduled jobs run once,** on the default branch, at off-peak times.
- **Short artifact retention** (`retention-days: 7`) for PR artifacts.
  Release evidence is attached to the GitHub release, not kept as workflow
  artifacts.
- **Measure:** the Actions usage report is reviewed monthly, and any workflow
  whose minutes grow without a matching change gets a ticket.

---

## 6. GitHub Actions hardening

Every workflow MUST pass actionlint and `zizmor --min-severity medium`, and
follows these rules:

- **Pin actions by full commit SHA**, with the version in a trailing comment
  (`uses: actions/checkout@<sha> # v5.x.y`). Renovate updates them.
- **Least-privilege token:** top-level `permissions: {}`. Each job grants only
  what it needs (`contents: read`, `id-token: write` only on jobs that assume
  an AWS role, and so on).
- `actions/checkout` always sets `persist-credentials: false`.
- **No template injection:** `${{ github.event.* }}` and other untrusted
  expressions never appear inside `run:`. They go through `env:` and are
  quoted as shell variables.
- No `pull_request_target` or `workflow_run` workflow checks out or runs PR
  code.
- **AWS access through OIDC only** ([TERRAFORM.md](TERRAFORM.md) section 8).
  No AWS keys in GitHub secrets.
- **Secrets are scoped to environments.** Workflows triggered by forks
  receive none.
- No caches in workflows that build or publish release artifacts
  (cache poisoning). PR workflows may cache dependency downloads keyed on
  lockfile hashes.
- Every job sets `timeout-minutes`.
- PR workflows use `concurrency` with `cancel-in-progress: true`, so a new
  push cancels the outdated run. Deploy and apply workflows use a
  per-environment concurrency group with `cancel-in-progress: false`.
- Runners: GitHub-hosted for everything, including deploys. ECS is driven
  through AWS APIs, so no runner needs network access into a VPC
  (section 5.1).

---

## 7. Build and publish

For each image, in `build.yml`:

1. `docker buildx build --pull` from the Dockerfile, with base images pinned
   by digest.
2. `trivy image` gate ([SECURITY.md](SECURITY.md) 5.3). A failure stops the
   pipeline before push.
3. `syft` SBOM.
4. Push to ECR with an immutable tag of the git SHA (plus the version on
   release tags).
5. `cosign sign` with the KMS signing key, and a build provenance attestation.
6. Record the digests, SBOMs and scan outputs as workflow artifacts. For
   releases they are attached to the GitHub release as evidence.

---

## 8. Deployment strategies

### 8.0 How a deploy works

Releases are Terraform applies. `deploy.yml` passes the release's image
digests as input variables to the environment's `app` stack
([TERRAFORM.md](TERRAFORM.md) section 3). Terraform registers new task
definition revisions and updates the services, and ECS then runs the
deployment with the strategy configured on each service. `wait_for_steady_state`
keeps the apply open until the deployment completes or rolls back, so a
rollback fails the workflow. Nothing changes ECS outside Terraform, so there
is no drift between what runs and what the code says.

Before the apply, `deploy.yml`:

1. runs `cosign verify` against every digest with the KMS signing key, and
   stops if any check fails;
2. runs the database migration (section 8.3) and waits for it to succeed.

ECS built-in strategies are used ([AWS.md](AWS.md) 4.4). AWS added blue/green
in July 2025 and linear and canary in October 2025, for services behind an
ALB or NLB with two target groups, on Fargate or EC2. Confirm that the pinned
AWS Terraform provider supports the strategy fields used before relying on
them.

| Environment | Strategy | Rollback triggers |
|---|---|---|
| `dev` | rolling | deployment circuit breaker |
| `stage` | blue/green | circuit breaker, CloudWatch alarms, smoke-test lifecycle hook |
| `prod` | canary | circuit breaker, CloudWatch alarms |

### 8.1 Canary (`prod`)

- `canaryConfiguration`: `canaryPercent` 10 and `canaryBakeTimeInMinutes` 15
  as the default, tuned per service. ECS shifts 10% of production traffic to
  the new revision, holds it there, then shifts the rest.
- Rollback alarms (`alarms` with `enable` and `rollback` set) watch the
  service's target groups in CloudWatch: the target 5xx ratio, and p95
  `TargetResponseTime` above the 300 ms SLO for 5 minutes. They use the same
  SLO thresholds as the burn-rate alerts ([OBSERVABILITY.md](OBSERVABILITY.md)
  section 4). An alarm during the deployment shifts traffic back to the
  stable revision and marks the deployment failed.
- A rollback pages P1 and links the rollback runbook.
- The prod apply waits behind the human approval gate (section 4.2).

### 8.2 Blue/green (`stage`)

- The new revision starts alongside the old one behind the second target
  group. A lifecycle hook (a small Lambda function packaged on the Aquia
  Python base image) runs HTTP smoke tests against the test listener before
  production traffic moves. A failed hook rolls the deployment back.
- After the switch, the old revision is kept for the bake time (at least 30
  minutes) so a rollback is a traffic switch, not a redeploy.
- The full Playwright and axe suites and the load test then run against
  `stage`. Their results are release gates for `prod`, not for `stage`.
- Blue/green and canary need about twice the task capacity during a
  deployment. That temporary cost is in the estimate.

### 8.3 Database migrations

- Migrations follow **expand/contract**. A release only adds (columns, tables,
  nullable fields, new indexes built concurrently). Code stops using old
  structures in a later release, and a third release removes them. The old
  and new versions of the application must both work against the schema
  during a canary or blue/green window.
- Migrations run as a one-off ECS task (a separate Terraform-managed migration
  task definition, using the migration database role,
  [PYTHON.md](PYTHON.md) 3.6), started by `deploy.yml` before the apply. A
  failed migration stops the deploy before any traffic moves.
- Destructive migrations need a verified backup or snapshot from the same day
  and a second approver.

### 8.4 Rollback

- Automatic: the circuit breaker and the rollback alarms return traffic to the
  previous revision during a deployment.
- Manual: re-run `deploy.yml` with the previous release's digests. Nothing is
  rebuilt. In `prod` this passes the human gate too, so on-call rotations
  always include a second person who can approve.
- Rolling back application code never rolls back the schema. Expand/contract
  is what makes this safe.

---

## 9. Change management (CM-3, CM-4)

- The PR is the change record: description, security impact analysis,
  linked issue, reviewers, checks, and the deployment it produced.
- Changes that are significant under FedRAMP's significant change policy
  (new external services, new data types, new components in the boundary,
  cryptographic changes) are identified in the PR and notified to or approved
  by the AO before the `prod` deployment.
- Release notes (the release-please changelog) are the release's change list,
  and the release's evidence bundle (SBOMs, scans, Shannon report) is attached
  to it.
