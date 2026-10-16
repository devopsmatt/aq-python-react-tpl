# Security and Compliance Standards

Scope: the whole repository and every environment. This document sets the
FedRAMP Moderate guardrails, the scan battery and how it runs, the
vulnerability policy, supply chain controls, and the pre-release gates.
Language- and platform-specific details are in [PYTHON.md](PYTHON.md),
[REACT.md](REACT.md), [NEXTJS.md](NEXTJS.md), [TERRAFORM.md](TERRAFORM.md),
[AWS.md](AWS.md), [CICD.md](CICD.md) and [OBSERVABILITY.md](OBSERVABILITY.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as described
in RFC 2119.

---

## 1. Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub private
vulnerability reporting on this repository (Security tab, "Report a
vulnerability"). Do not open a public issue. Reports are acknowledged within
two business days. If a report may involve federal data, the incident process
in section 8 starts immediately.

---

## 2. Compliance model

- **Baseline:** FedRAMP Moderate, NIST SP 800-53 Rev. 5.
- **Authorization boundary:** the `prod` AWS account and the services it
  uses, the CI/CD path that deploys to it, and the external services that
  receive system data (Google as the IdP, PagerDuty, GitHub). Each external service is
  listed in the SSP with its FedRAMP status and the data it receives.
- **Inherited controls:** physical, environmental and many infrastructure
  controls come from the AWS FedRAMP package. The SSP cites the AWS customer
  responsibility matrix for every inherited or shared control.
- **Evidence as code:** every control implementation statement in the SSP
  points to the file, configuration, pipeline job or log source that
  implements it. If a statement cannot point to one, the control is not
  implemented.
- **Continuous monitoring (ConMon):** monthly vulnerability scan deliverables,
  POA&M updates, and annual assessment evidence come from the pipelines and
  services described here, not from manual screenshots.

### 2.1 Control families mapped to this repository

| Family | Key controls | Where it is implemented |
|---|---|---|
| AC Access Control | AC-2, AC-3, AC-6, AC-11, AC-12, AC-17 | IdP + MFA, object-level authz ([PYTHON.md](PYTHON.md) 3.4), 15-min lock, least-privilege IAM and ECS task roles ([AWS.md](AWS.md) 2, 4) |
| AU Audit and Accountability | AU-2, AU-3, AU-6, AU-8, AU-9, AU-11, AU-12 | App audit events, AWS-native logs, Object Lock archive, M-21-31 retention ([OBSERVABILITY.md](OBSERVABILITY.md), [AWS.md](AWS.md) 9) |
| CA Assessment | CA-2, CA-7, CA-8 | Scan battery, Security Hub, pre-release Shannon run (section 7) |
| CM Configuration Management | CM-2, CM-3, CM-4, CM-6, CM-7, CM-8 | Terraform only, PR review, drift detection ([TERRAFORM.md](TERRAFORM.md) 7), security impact analysis in the PR template, SBOM inventory |
| CP Contingency Planning | CP-9, CP-10 | RDS backups and AWS Backup copies, IaC rebuild, rollback ([CICD.md](CICD.md)) |
| IA Identification and Authentication | IA-2(1), IA-2(2), IA-5, IA-8 | Phishing-resistant MFA at the IdP, OIDC token validation, no static credentials |
| IR Incident Response | IR-4, IR-5, IR-6, IR-8 | PagerDuty P0/P1, runbooks, 1-hour reporting (section 8) |
| RA Risk Assessment | RA-3, RA-5 | Threat modeling per feature, the scan battery, ConMon scans |
| SA System and Services Acquisition | SA-10, SA-11, SA-15 | This document, protected branches, SAST, SCA, DAST |
| SC System and Communications Protection | SC-7, SC-7(5), SC-8, SC-12, SC-13, SC-28 | Private networking, deny-by-default egress, TLS 1.3, KMS, FIPS runtime images |
| SI System and Information Integrity | SI-2, SI-3, SI-4, SI-7, SI-10 | Patch SLAs (section 4), GuardDuty, input validation, image signing |
| SR Supply Chain Risk Management | SR-3, SR-4, SR-11 | Pinned dependencies, SBOMs, provenance, signed images (section 6) |

### 2.2 Data handling

- Federal data exists only in `prod`. `dev`, `stage` and local
  environments use synthetic data only.
- Federal data, personal data, tokens and secrets never appear in logs,
  traces, metric labels, alert payloads, error messages, tickets or PR
  comments.
- Every AWS resource carries the `DataClassification` tag
  ([TERRAFORM.md](TERRAFORM.md) section 4).

---

## 3. Cryptography

- **FIPS 140-3:** services run on the Aquia `fips-140-3` runtime image (OpenSSL
  FIPS Provider 3.1.2, CMVP certificate #4985, sunset 2030-03-10). It is built
  from validated source and user-affirmed on Wolfi, so it is described that
  way and never as "FIPS 140-3 validated on Wolfi". Enforcement was measured
  for Python and Node.js ([PYTHON.md](PYTHON.md) 3.7,
  [NEXTJS.md](NEXTJS.md) 7).
- **In transit:** TLS 1.3 only, at the ALB (`ELBSecurityPolicy-TLS13-1-3-FIPS-PQ-2025-09`),
  to RDS, and between services. The post-quantum target is hybrid key
  exchange (`X25519MLKEM768` preferred, `SecP256r1MLKEM768` where only NIST
  curves are allowed). ML-KEM-512 and draft Kyber groups are not used. Any
  TLS 1.2 peer is a named SSP exception.
- **At rest:** AES-256 through KMS customer managed keys everywhere
  ([AWS.md](AWS.md) section 10).
- **Signatures:** ECDSA P-256 for image signing, the API's internal access
  tokens, and mTLS until hardware-backed ML-DSA is available. The one
  exception is Google's ID tokens, which Google signs only with RS256; they
  are verified at sign-in in the BFF and nowhere else
  ([NEXTJS.md](NEXTJS.md) section 4).
- **Banned:** MD2, MD4, MD5, SHA-0, RC2, RC4, Blowfish, DES, 3DES, static
  RSA key exchange, anonymous Diffie-Hellman.
- **Deprecated (no new use, migrate existing):** SHA-1, AES-CBC, AES-ECB,
  RSA PKCS#1 v1.5 signatures, DHE with weak or common primes.
- Keys come from KMS or HSM and a CSPRNG. No key, secret or experimental OID
  is ever hardcoded.

---

## 4. Vulnerability management

### 4.1 Policy: zero fixable findings at MEDIUM or above

No release ships with a **fixable** vulnerability or misconfiguration of
severity **MEDIUM or higher** in any of:

- application dependencies (Python, npm),
- container images (OS packages and language packages),
- infrastructure as code,
- first-party code (SAST),
- the target AWS account, as reported by Security Hub (including Inspector
  and GuardDuty findings).

**Fixable** means a fixed version is published AND installable in our build
(for example, the distribution has actually shipped the fixed package). This
matches the Aquia base-image hardening rule, which gates Trivy at MEDIUM with
`ignore-unfixed`.

### 4.2 Where the gate runs

| Stage | What runs | Effect |
|---|---|---|
| pre-commit | fast checks on staged files (section 5.2) | commit blocked |
| pre-push | full local battery (section 5.3) | push blocked |
| Pull request CI | full battery plus image builds and scans | merge blocked |
| Image build | Trivy image scan, SBOM, signing | image not pushed |
| Nightly | rescan of every deployed digest and SBOM against new advisories | finding opened, routed by severity |
| Pre-release | Security Hub gate, Shannon run, clean battery on the release commit | release blocked |
| Runtime | Security Hub, Inspector, GuardDuty continuously | routed per [OBSERVABILITY.md](OBSERVABILITY.md) |

### 4.3 Remediation in production

A finding that appears in production after release (a new CVE in a deployed
image, for example) is remediated through the normal pipeline. Remediation
deadlines follow the current FedRAMP ConMon guidance, and the item is tracked
in the POA&M until closed. This repository's goal is tighter: fixable
MEDIUM-or-higher findings are fixed in the next patch release. CRITICAL
findings, and actively exploited ones (CISA KEV), take the emergency path: fix,
full battery, canary, prod, the same day where possible.

### 4.4 Findings that cannot be fixed yet

- **Fixable means fix now; no fix means record and keep going.** A finding
  with an installable fix is fixed in the same change. A finding with no fix
  does not block work: it is recorded with its evidence (what is affected,
  and whether the vulnerable code is reachable here), and for the production
  system it is tracked in the POA&M.
- When a tool would fail the gate on a no-fix finding that `--ignore-unfixed`
  does not already skip, the finding is ignored with a mandatory expiry. For
  Trivy that is an entry in `.trivyignore.yaml` with `expired_at` (the Aquia
  base-image pattern: the finding fails builds again once the date passes, so
  an ignore cannot become permanent quietly).
- Every ignore, skip or suppression, in any tool, links to a POA&M item or a
  risk acceptance approved by the ISSO. FedRAMP deviation requests (false
  positive, risk adjustment, operational requirement) go to the AO with
  evidence.
- A pre-existing finding is still a finding. It is listed with an effort
  estimate and gets an explicit decision: fix now, track separately, or
  accept the risk. It is never waved through as "not ours".
- An ignore is removed as soon as a fixed package can be installed.

---

## 5. The scan battery

### 5.1 Hooks

Hooks live in `.githooks/` and are activated once per clone:

```bash
git config --local core.hooksPath .githooks
```

Bypassing hooks (`--no-verify`, `-n`, unsetting `core.hooksPath`) is
forbidden. If a hook fails, fix the finding. `scripts/validate-security.sh`
runs the full battery; the hooks and CI call it, so every place runs the same
commands.

### 5.2 pre-commit (fast, staged files)

1. Non-ASCII scan of staged files.
2. gitleaks on staged changes; trufflehog on the working tree.
3. Formatters and linters for the staged languages (black, isort, ruff,
   flake8; eslint, prettier; `terraform fmt`; shellcheck; actionlint).
4. Lockfile-level dependency checks when `uv.lock`, `pyproject.toml` or
   `package-lock.json` changed (osv-scanner, pip-audit, npm audit).

### 5.3 pre-push and CI (full battery)

Repository-wide. No scanner runs from a container image. Locally the
scanners are the installed binaries. In CI the same tools run as binaries
built or installed from the pins in `ci/tools/` (TruffleHog runs through its
official action):

| Tool | Command | Blocks on |
|---|---|---|
| TruffleHog (history), CI | `trufflesecurity/trufflehog` action, SHA-pinned, image pinned by digest, `head` = PR head and no `base` (full history up to the head), `--only-verified` | verified secret anywhere in history |
| TruffleHog (history), local | `trufflehog git file://. --only-verified --no-update --fail` | verified secret anywhere in history |
| TruffleHog (working tree), local | `trufflehog filesystem . --only-verified --no-update --fail` | verified secret in the tree |
| Gitleaks (history) | `gitleaks git --redact --no-banner .` | any match |
| Gitleaks (working tree) | `gitleaks dir --redact --no-banner .` | any match |
| Trivy filesystem | `trivy fs --scanners vuln,secret,misconfig --skip-version-check --severity MEDIUM,HIGH,CRITICAL --ignore-unfixed --exit-code 1 .` | MEDIUM and above, fixable |
| Trivy image (application images) | `trivy image --image-src docker --severity MEDIUM,HIGH,CRITICAL --ignore-unfixed --exit-code 1 <image>` | MEDIUM and above, fixable |
| Checkov | `scripts/checkov-gate.sh .` | canary not caught, or any failed check |
| ShellCheck | `shellcheck <every tracked *.sh>` | any finding |
| actionlint | `actionlint` | any finding |
| zizmor | `zizmor --min-severity medium --config .github/zizmor.yml .github/workflows` | MEDIUM and above, including any action not pinned to a full SHA |
| ASCII only | `scripts/check-ascii.sh` | any byte outside printable ASCII |

Image scans set `--image-src docker`, so Docker is the only image source:
Trivy never falls back to containerd, Podman or a remote registry.

Plus the Python battery ([PYTHON.md](PYTHON.md) section 7), the frontend
battery ([REACT.md](REACT.md) section 7) and the Terraform checks
([TERRAFORM.md](TERRAFORM.md) section 7).

Notes (**Measured** entries were run on 2026-09-23 unless dated otherwise):

- **TruffleHog** `--only-verified` reports only credentials it confirmed live,
  and it confirms them by calling the issuing service. Gitleaks runs alongside
  it because it reports pattern matches whether or not they are live.
- **Gitleaks, measured (8.30.0):** `gitleaks detect` still works but is
  hidden from help as a deprecated alias. The standard uses `gitleaks git`
  (history) and `gitleaks dir` (working tree).
- **Checkov, measured (3.2.510):** severity filters run zero checks without a
  Prisma Cloud API key and exit 0. Checkov runs unfiltered, every failed check
  blocks, and exceptions are reasoned skips. `scripts/checkov-gate.sh` first
  requires a planted canary to fail, so a scan that evaluates nothing fails
  closed instead of reporting clean ([TERRAFORM.md](TERRAFORM.md) section 7).
- **Bearer and njsscan, measured:** the MEDIUM floor is
  `bearer --severity critical,high,medium` and `njsscan -w`
  ([REACT.md](REACT.md) section 7).
- **Semgrep, measured:** `--config auto` requires metrics to be sent to
  Semgrep ([PYTHON.md](PYTHON.md) section 7).
- **Non-ASCII, measured (2026-10-15 and 2026-10-16):** a PCRE pattern of
  `[\x80-\xFF]` finds nothing under a UTF-8 locale (PCRE reads it as code
  points U+0080 to U+00FF), and the earlier
  `! git ls-files -z | xargs -0 grep ...` form turned a grep error into a pass
  (xargs exits 123, and `!` flips it to success). `scripts/check-ascii.sh`
  replaces both. It runs `git grep -I` in the C locale with the bracket
  expression `[^[:print:][:space:]]`, so no PCRE is needed, and it treats
  exit 0 (found), 1 (clean) and anything else (error) separately. On planted
  files it flagged an em-dash, an arrow, a box-drawing character and an
  escape control character, skipped a binary, passed a file with tabs and
  CRLF line endings, and returned 2 when git grep failed.
- **CI tool pins, measured (2026-10-16, linux/arm64):** the upstream scanner
  container images carried fixable MEDIUM+ vulnerabilities (actionlint
  2 CRITICAL / 86 HIGH, gitleaks 2 CRITICAL / 57 HIGH including
  CVE-2026-31789 in OpenSSL, checkov 26 HIGH from bundled kustomize and helm,
  trivy 4 HIGH in the Go standard library, zizmor 21 MEDIUM OS packages,
  trufflehog 1 MEDIUM), so scanner containers are not used. The upstream
  release binaries of gitleaks (Go 1.24.13), trivy (Go 1.27.1) and actionlint
  (Go 1.26.1) also carry Go standard-library findings, so CI builds those
  three with `setup-go` from `ci/tools/<tool>/go.mod` using the current Go,
  with `golang.org/x/*`, `rardecode`, `xz`, `klauspost/compress` and
  `mholt/archives` raised past their fixed versions. checkov and zizmor
  install from hash-pinned locks; checkov's lock leaves out `asteval`, and
  `overrides.txt` supplies 1.0.10, because checkov pins the vulnerable 1.0.6.
  Trivy and osv-scanner report no fixable findings in those pins.
- **Installed local binaries** are the developer's responsibility to keep
  current (for example `brew upgrade`). CI's pinned builds are the
  authoritative gate.
- **TruffleHog exception (code-owner decision, 2026-10-16):** a trufflehog
  built from source still carried CVE-2026-33997 (MEDIUM) in
  `github.com/docker/docker` v28.5.2. The flaw is in the Docker daemon's
  plugin-install privilege check; trufflehog links only the client library,
  for a docker-image source this CI never uses. Moby 29 moved to a new module
  path, so no bump can fix it. TruffleHog therefore runs from its official
  action in CI and from the installed binary locally, until trufflehog moves
  to Moby 29.
- **No-fix findings in the CI tool pins (2026-10-16).** These have no fixed
  version, so they are tracked here and do not block (section 4.4):
  - `ecdsa` 0.19.2 (CVE-2024-23342, PYSEC-2026-1325), required by checkov: a
    timing side channel in signing, key generation and ECDH that upstream
    will not fix. checkov in CI holds no private keys and signs nothing.
  - GO-2026-5932, the deprecated `golang.org/x/crypto/openpgp` package: it
    matches every `x/crypto` version, but `go list -deps` shows neither
    gitleaks nor trivy imports `openpgp`.
  - GO-2026-4919, the March 2026 Trivy supply-chain compromise: GitHub's
    advisory limits it to v0.69.4 (OSV's range is open-ended); the pin is
    v0.75.0, verified against sum.golang.org.
- Every CI tool version is pinned (Go `go.sum`, pip locks with hashes, the
  TruffleHog action SHA and image digest), and Dependabot raises minor and
  patch updates as PRs, so a scanner upgrade that changes results shows up as
  its own reviewable change.

### 5.4 Sensitive files

Every sensitive file pattern (`.env*`, `*.tfvars` other than examples,
`*.pem`, `*.key`, `*.crt`, `credentials*`, `secrets*`, cloud credential JSON,
SSH and GPG keyrings) is listed explicitly in `.gitignore`. Before a new
sensitive path is used, `git check-ignore -v <path>` must confirm it is
ignored.

---

## 6. Supply chain (SR family)

- **Pinning:** dependency lockfiles are committed (`uv.lock`,
  `package-lock.json`, `.terraform.lock.hcl`). GitHub Actions are pinned by
  full commit SHA. Base images are pinned by tag and digest. Dependabot
  (`.github/dependabot.yml`) proposes minor and patch updates as grouped PRs,
  after a 7-day cooldown for third-party releases. Aquia base images are
  first-party, rebuilt daily for CVE fixes, and checked daily without a
  cooldown. Major versions are upgraded by hand.
- **SBOM:** every image gets an SPDX or CycloneDX SBOM from `syft`, stored
  with the release and scanned nightly with `grype` against new advisories.
- **Signing:** images are signed with cosign using the KMS `signing` key
  (ECDSA P-256):
  `cosign sign --key awskms:///alias/ai101-signing --tlog-upload=false <image@digest>`.
  Transparency log upload is off so image names and digests are not published
  to a public log. ECS has no admission control, so `deploy.yml` runs
  `cosign verify` on every digest before it goes into a task definition, and
  only the pipeline's role can register task definitions
  ([AWS.md](AWS.md) 4.5).
- **Provenance:** build provenance attestations are generated in the build
  workflow and stored with the image.
- **Install scripts:** npm lifecycle scripts are off by default
  ([REACT.md](REACT.md) section 8).

---

## 7. Pre-release gates

A release candidate (a release-please release PR on `main`, see
[CICD.md](CICD.md)) is promoted to `prod` only when all of these hold for the
exact commit and image digests being released:

1. The full battery in section 5.3 is clean on the release commit.
2. Test coverage is >= 80% for every component, and all e2e and accessibility
   suites pass.
3. The Security Hub gate returns zero active, unsuppressed, fixable findings
   of MEDIUM or above for the `stage` account running those digests
   ([AWS.md](AWS.md) section 8).
4. **Shannon:** a clean result from a Shannon run with full source access
   against `stage`.
5. Any change that is significant under FedRAMP change management has been
   notified to or approved by the AO before deployment.

### 7.1 Shannon

Shannon (`KeygraphHQ/shannon`, AGPL-3.0) is an autonomous white-box
penetration tester for web applications and APIs. It reads the source code
to map attack surface and data flows, then executes real exploits against the
running application, and reports only findings it reproduced with a proof of
concept.

- It runs against `stage`, never `prod`, because it executes real exploits.
  `stage` holds synthetic data only.
- It sends source code and application responses to the third-party LLM API
  it is configured with. That data flow needs ISSO approval before the first
  run, and the provider and account used are recorded in the SSP.
- **Clean bill of health** means zero reproduced findings. Any finding is
  fixed, the battery rerun, and Shannon rerun on the new release candidate.
- The Shannon report is kept as release evidence (CA-8) with the release's
  SBOMs and scan outputs.

---

## 8. Incident response

- P0 and P1 page through PagerDuty ([OBSERVABILITY.md](OBSERVABILITY.md)).
- A suspected security incident affecting federal data or the boundary is
  reported per the FedRAMP Incident Communications Procedures: to CISA within
  one hour of identification, and to the agency and the FedRAMP PMO as those
  procedures require.
- Evidence is preserved before remediation: snapshots, logs from the Object
  Lock archive, and the relevant image digests.
- Every P0 and P1 gets a blameless post-incident review. Its action items are
  tracked to closure, and the runbook is updated.

---

## 9. Secure development practice

- Every feature starts with a short threat model (STRIDE over the data flow
  it adds), recorded in the PR or linked design doc.
- The PR template includes a security impact analysis (CM-4): new data flows,
  new external services, authn and authz changes, crypto changes, new
  infrastructure (with its cost estimate).
- CODEOWNERS requires a security reviewer for `infra/`, `.github/`,
  `.githooks/`, `scripts/`, auth code, and crypto code.
- The GitHub organization requires 2FA. Branch and tag protection is defined
  in [CICD.md](CICD.md).
