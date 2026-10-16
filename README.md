# ai-101

A FedRAMP Moderate golden-path template: a reference monorepo that other
Aquia projects fork to start from a secure, tested, deployable baseline
instead of a blank repository.

---

## North Star

Give every new project a working, FedRAMP Moderate-ready starting point on day
one: the documented stack, a running application, an end-to-end pipeline,
and the security, accessibility, observability and compliance evidence that a
3PAO assessment needs. A fork should change the application, not rebuild the
platform.

## Final goal

A stack template for the languages documented in `docs/`, shipping:

- **A hello-world application with login.** A user signs in with Google SSO
  (OIDC, phishing-resistant MFA enforced by the Workspace) and sees a greeting
  page. They can save a greeting,
  which the API stores in PostgreSQL and returns on their next visit. Sign-out,
  the 15-minute inactivity lock with an accessible warning, and audit events
  for every sign-in, sign-out and change are all included. It is small on
  purpose, but it exercises every standard: the BFF pattern, the OpenAPI
  contract, migrations, IAM database auth, canary-safe schema changes, Section
  508, and FIPS runtime images.
- **End-to-end CI/CD** on GitHub Actions: the full test suites and security
  scan battery on every PR, signed images, Terraform-driven releases, ECS
  blue/green in `stage`, and ECS canary in `prod` behind a human approval
  gate.
- **Deployment to AWS**, with all infrastructure in Terraform.
- **Cost-mindful by default,** for both AWS and GitHub Actions minutes.

## Acceptance criteria

The project is 100% complete, fully tested and audit-ready only when every
item below is true and its evidence is attached to the release.

### 1. All gates green

- [ ] Line and branch coverage >= 80% for `python/api` and `web/` (unit plus
      integration), and >= 80% on the lines changed in each PR.
- [ ] The full scan battery ([docs/SECURITY.md](docs/SECURITY.md) section 5)
      is clean on the release commit: zero findings at MEDIUM or above.
      Anything that cannot be fixed yet carries a POA&M entry with an expiry
      date.
- [ ] Security Hub reports zero active, unsuppressed, fixable findings at
      MEDIUM or above in the `stage` and `prod` accounts.
- [ ] A Shannon run with full source access against `stage` reports zero
      reproduced findings.
- [ ] Playwright and axe pass on every route, and the manual Section 508 pass
      (keyboard, screen readers, zoom, reflow) is complete.

### 2. Production via canary

- [ ] `dev`, `stage` and `prod` are built entirely by Terraform from this
      repository, and the nightly drift check is clean.
- [ ] A release reaches `prod` by the full path: PR merged to `main`, then
      the release tag, then `stage` blue/green, then human approval, then the
      `prod` canary.
- [ ] Automatic rollback has been shown in `stage` with a deliberately failing
      release, and a manual rollback of `prod` to the previous release has
      been performed once.

### 3. Audit package ready

- [ ] SSP control implementation statements for the FedRAMP Moderate baseline
      exist, each linked to the file, pipeline job or log source that
      implements it.
- [ ] The POA&M is current: every open finding and exception has an owner and
      a date.
- [ ] An Accessibility Conformance Report (VPAT, Section 508 edition) is
      published for the release.
- [ ] Every alert has a runbook, the required failure-mode runbooks exist
      ([docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) section 6), and a game
      day has exercised them.
- [ ] The release evidence bundle (SBOMs, scan outputs, signatures, Shannon
      report, load-test report) is attached to the GitHub release.

### 4. SLOs met under load

- [ ] A load test in `stage` sustains **50 requests per second for 30
      minutes** against the signed-in hello-world flow, with **availability
      >= 99.9%** and **p95 latency < 300 ms**, measured from ALB metrics and
      confirmed in Grafana.
- [ ] The SLO burn-rate alerts fire and route correctly (P1 to PagerDuty) in
      a forced-failure test.

---

## Architecture

```
 Browser
   |  HTTPS: TLS 1.3 only, FIPS ciphers, hybrid post-quantum key exchange
   v
 AWS WAF + internet-facing ALB
   |
   v                                   OIDC code flow + PKCE (S256)
 web: Next.js BFF  ----------------------------------------->  Google SSO
                                                                (Workspace domain only,
                                                                 security-key MFA)
 (ECS on Fargate, ARM64, Aquia FIPS 140-3 runtime image)
   |  HTTPS, with a 5-minute ES256 token the BFF signs with KMS
   |  (Google tokens never reach the browser or the API)
   v
 internal ALB
   |
   v
 api: FastAPI + Pydantic
 (ECS on Fargate, ARM64, Aquia FIPS 140-3 runtime image)
   |  TLS 1.3, IAM database authentication
   v
 Amazon RDS for PostgreSQL (Multi-AZ in stage and prod, KMS, pgaudit)

 Telemetry : OTLP -> Grafana Alloy -> Tempo, Mimir;  FireLens -> Loki + CloudWatch Logs
 Detection : Security Hub CSPM (AWS FSBP, NIST SP 800-53 Rev. 5), GuardDuty, Inspector, Config
 Delivery  : GitHub Actions (OIDC) -> ECR (signed digests) -> terraform apply of the app stack
```

### Technology

| Area | Choice |
|---|---|
| Backend | Python 3.13, FastAPI, Pydantic v2, `uv`, OpenAPI contract committed |
| Frontend | React, Next.js (App Router), TypeScript (strict), Node.js 24 |
| Containers | Aquia base images only: build on `python-base` and `nodejs-base`, run on `fips-140-3` |
| Compute | Amazon ECS on AWS Fargate, ARM64 (Graviton) |
| Data | Amazon RDS for PostgreSQL |
| Edge | ALB with TLS policy `ELBSecurityPolicy-TLS13-1-3-FIPS-PQ-2025-09`, AWS WAF |
| Infrastructure | Terraform, S3 state with native locking, one AWS account per environment |
| CI/CD | GitHub Actions, release-please, ECS built-in blue/green and canary |
| Observability | Loki, Grafana, Tempo, Mimir on ECS; AWS-native logs; PagerDuty for P0 and P1 |
| Login | Google SSO (OIDC), restricted to the Workspace domain; the API trusts only BFF-minted ES256 tokens |
| In-VPC TLS | TLS 1.3 from every ALB to every task through a FIPS nginx sidecar with a per-task self-signed certificate |
| Region | AWS commercial `us-east-1` (assumption, to be confirmed with the AO) |

### Environments

| Environment | Runs on | Deployed | Strategy | Gate |
|---|---|---|---|---|
| local | docker compose | `docker compose up --build` | n/a | none |
| `dev` | AWS `dev` account | every merge to `main` | rolling | automatic |
| `stage` | AWS `stage` account | every release tag `vX.Y.Z` | blue/green | release gates (scans, Shannon, load test) |
| `prod` | AWS `prod` account | the same image digests after `stage` passes | canary | **human approval** (required reviewer, no self-approval) |

---

## Non-negotiable rules

The full standards are in `docs/`. These are the ones every change meets:

- **FedRAMP Moderate (NIST SP 800-53 Rev. 5).** Every control statement points
  to the code, configuration or log source that implements it.
- **Zero fixable vulnerabilities at MEDIUM or above** in dependencies, images,
  infrastructure as code, first-party code, and Security Hub. Every scanner
  runs at a MEDIUM floor, and a misconfigured scanner fails closed (the
  Checkov canary gate).
- **Clean Shannon run before every release.**
- **FIPS 140-3 runtime images, TLS 1.3 only,** KMS customer managed keys, and
  no hardcoded secrets.
- **Section 508 / WCAG 2.1 AA** for every UI change.
- **>= 80% test coverage** per component.
- **Trunk-based, protected `main`:** `main` is always deployable. Changes
  arrive by PR only, with code-owner approval. Commits are signed, force
  pushes are blocked, and hooks are never bypassed.
- **Infrastructure changes go through Terraform only.** Releases are
  Terraform applies too.
- **Cost approval before building.** Every billable addition comes with a
  measured estimate and an explicit approval
  ([docs/TERRAFORM.md](docs/TERRAFORM.md) section 6).
- **ASCII only** in every file.

## Documentation

| Document | Covers |
|---|---|
| [docs/SECURITY.md](docs/SECURITY.md) | FedRAMP guardrails, scan battery, vulnerability policy, supply chain, Shannon, incident response |
| [docs/PYTHON.md](docs/PYTHON.md) | uv workspace, FastAPI and Pydantic, mypy, pytest and coverage, Python scanners, containers |
| [docs/REACT.md](docs/REACT.md) | TypeScript, components, Section 508, Vitest, frontend scanners |
| [docs/NEXTJS.md](docs/NEXTJS.md) | BFF architecture, login, headers and CSP, assets, FIPS runtime, Playwright |
| [docs/TERRAFORM.md](docs/TERRAFORM.md) | Layout, state, scanning, Checkov canary gate, cost approval, measured prices |
| [docs/AWS.md](docs/AWS.md) | Accounts, networking, ECS on Fargate, ECR, RDS, WAF, Security Hub, logging, keys |
| [docs/CICD.md](docs/CICD.md) | Branching, releases, workflows, Actions hardening and cost, deployments, rollback |
| [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) | LGTM on ECS, log and audit schema, SLOs, PagerDuty, runbooks, retention |

## Contributing

1. Activate the hooks once per clone: `git config --local core.hooksPath .githooks`.
2. Branch from `main` (`feature/*`, `fix/*`, `chore/*`) and open a PR back
   to `main`. PR titles follow Conventional Commits, and the squash commit
   takes the PR title. Code owners (`.github/CODEOWNERS`) approve and merge.
3. Sign every commit.
4. The PR template's security impact analysis and, for infrastructure, the
   Infracost estimate are required.

## Status

Standards are in `docs/`. The pull request gate is live: `.github/workflows/pr.yml`
runs the security battery (TruffleHog and Gitleaks, Trivy, canary-gated
Checkov, actionlint, zizmor, ShellCheck, ASCII), with every tool pinned in
`ci/tools/` and run as a binary rather than a container, plus the PR title
check, on arm64 runners. Dependabot proposes minor and patch updates. No application code or infrastructure exists yet. Decisions
still open before they are built:

- Confirmation of the AWS commercial `us-east-1` assumption with the AO.
- Semgrep `--config auto` (sends metrics to Semgrep) or pinned rule packs with
  metrics off ([docs/PYTHON.md](docs/PYTHON.md) section 7).
- ISSO acceptance of the third-party data flows: Google as the IdP, the
  Safety platform, Infracost pricing API, and the LLM API that Shannon uses.
- First-deploy confirmation that ALB health checks pass against the TLS
  1.3-only sidecar ([docs/AWS.md](docs/AWS.md) 4.6).
- Confirmation that the pinned Terraform AWS provider supports the ECS
  canary strategy fields.
