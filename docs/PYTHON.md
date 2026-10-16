# Python Standards

Scope: the FastAPI service under `python/api/` (the hello-world API behind
the login) and any Python tooling under `scripts/`.

Related: [SECURITY.md](SECURITY.md) (scan battery, vulnerability policy),
[CICD.md](CICD.md) (pipeline and deployments),
[OBSERVABILITY.md](OBSERVABILITY.md) (logging, tracing, audit events).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as described
in RFC 2119.

Statements marked **Measured** were verified by running the named tool or
image on the date shown. Re-verify them when a tool version changes.

---

## 1. Baseline

| Item | Standard |
|---|---|
| Interpreter | Python 3.13 |
| Package and environment manager | `uv`, one workspace, one committed `uv.lock` |
| Web framework | FastAPI with Pydantic v2 |
| Type checking | mypy `strict`, run separately per module |
| Tests | pytest, >= 80% line + branch coverage per module |
| Build image | `ghcr.io/aquia-inc/base-docker-images/python-base` |
| Runtime image | `ghcr.io/aquia-inc/base-docker-images/fips-140-3` plus the Wolfi `python-3.13` package |

The project floor is Python 3.12+. The project targets 3.13 because that is
the interpreter the Aquia `python-base` image ships, and testing on a version
that is never deployed proves nothing. Every `pyproject.toml` sets
`requires-python = ">=3.13"` and a root `.python-version` pins `3.13` for `uv`.

---

## 2. Repository layout and the uv workspace

```
pyproject.toml          workspace root: shared tool config, lint tool group
uv.lock                 single lockfile for every member, committed
.python-version         3.13
.bandit                 bandit configuration
.flake8                 flake8 configuration (flake8 does not read pyproject)
python/
  api/                  FastAPI service      dist: ai101-api         import: ai101_api
    pyproject.toml
    openapi.json        committed API contract (section 3.2)
    Dockerfile
    src/ai101_api/
    tests/unit/  tests/integration/  tests/e2e/
```

The template has one Python service, `api`. The workspace layout is kept so a
fork can add members without restructuring.

Root `pyproject.toml`:

```toml
[project]
name = "ai101"
version = "0.0.0"
requires-python = ">=3.13"
dependencies = []

[dependency-groups]
lint = ["black", "isort", "ruff", "flake8", "bandit"]

[tool.uv]
package = false

[tool.uv.workspace]
members = ["python/*"]
```

Rules:

- Distribution names MUST carry the `ai101-` prefix. A short name such as
  `api` can be registered on PyPI by anyone. A prefixed name
  that resolves from the workspace closes off that dependency-confusion path.
- If a fork adds more members, services MUST NOT import each other. Shared
  code goes in a workspace library referenced with
  `[tool.uv.sources] <name> = { workspace = true }`.
- Each member MUST declare its own runtime dependencies AND its own `dev`
  dependency group (pytest, pytest-cov, mypy, pylint and plugins).

**Measured (uv 0.7.8, 2026-09-23):** `uv sync --locked --package ai101-api`
installs only that member and the member's own dependency groups. A `dev`
group declared only at the workspace root was not installed, so `mypy` and
`pytest` were missing. With `dev` declared in the member, the isolated
environment was complete and `mypy` ran. The isolated environment is what
lets mypy and pytest catch a module importing a package it never declared.

### 2.1 Everyday uv commands

| Task | Command |
|---|---|
| Install everything for local work | `uv sync --locked --all-packages` |
| Install one module in isolation (CI) | `uv sync --locked --package ai101-api` |
| Install only the lint tools | `uv sync --locked --only-group lint` |
| Add a runtime dependency | `uv add --package ai101-api "httpx>=0.28"` |
| Add a dev tool to a module | `uv add --package ai101-api --group dev pytest-asyncio` |
| Upgrade one dependency | `uv lock --upgrade-package starlette` |
| Assert the lock is current | `uv lock --check` |
| Run a tool in the synced env | `uv run --no-sync <cmd>` |

Rules:

- `uv.lock` MUST be committed. CI MUST pass `--locked`, which fails when
  `pyproject.toml` and `uv.lock` disagree instead of silently re-resolving.
- Nobody runs `pip install` into a project environment or hand-edits a
  requirements file. Requirements files are generated exports (section 7).
- A private index, if one is ever added, MUST be declared with
  `explicit = true` under `[[tool.uv.index]]` and bound per package with
  `[tool.uv.sources]`, so a public package of the same name is never resolved.
- A new dependency needs a one-line justification in the PR: what it does,
  that it is maintained, and that its license is compatible.

---

## 3. FastAPI standards

### 3.1 Application structure

- An application factory `create_app(settings: Settings) -> FastAPI` builds
  the app. Tests call it with test settings; nothing reads globals at import.
- `routers/` holds HTTP concerns only. `services/` holds business logic with
  no FastAPI imports, so it is testable without HTTP. `repositories/` holds
  persistence. `schemas/` holds Pydantic API models, kept separate from ORM
  models.
- Cross-cutting needs (auth, DB session, settings) are `Depends` providers and
  are replaced in tests through `app.dependency_overrides`.
- Startup and shutdown use the `lifespan=` handler: connection pools, the FIPS
  self-check (3.7), and telemetry setup. `@app.on_event` is not used.
- No blocking I/O inside `async def`. Blocking libraries run in `def`
  endpoints (FastAPI runs those in a threadpool) or in a worker.

### 3.2 OpenAPI contract

The API is spec driven: `python/api/openapi.json` is the contract and is
committed.

- CI regenerates the spec from the application and fails on any difference.
  A change that alters the API updates the contract in the same PR, where
  reviewers see it.
- CI runs `oasdiff breaking` between the base branch spec and the PR spec. A
  breaking change requires a major version bump (a Conventional Commit with
  `!`, see [CICD.md](CICD.md)).
- Every route declares a response model (`response_model=` or a typed return),
  `status_code`, documented error `responses`, `summary`, `tags` and a stable
  `operation_id`. Generated clients depend on the operation id.
- Frontend TypeScript types are generated from this file
  ([REACT.md](REACT.md)); they are never hand-written.
- Interactive docs MUST be off in `stage` and `prod`:
  `FastAPI(docs_url=None, redoc_url=None, openapi_url=None)`. They MAY be on
  in local and `dev`.

### 3.3 Pydantic models

- Request models use
  `model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, frozen=True)`.
  Unknown fields are rejected, not ignored, which blocks mass assignment.
- Every input is bounded: `Annotated[str, StringConstraints(min_length=1, max_length=256)]`,
  `Annotated[int, Field(ge=1, le=500)]`, lists with `max_length`. Page size is
  capped server-side.
- Response models are separate classes that list exactly the fields to expose.
  Handlers never return ORM objects or free-form dicts.
- Secrets are typed `SecretStr` so they do not render in `repr` or logs.
- Settings use `pydantic-settings`. Secrets have no defaults, and invalid
  configuration fails at startup rather than at first use.
- Externally visible identifiers are UUIDs, not sequential integers. This does
  not replace authorization checks; it removes trivial enumeration.

### 3.4 Authentication and authorization

- Every route requires authentication except a reviewed allowlist (liveness
  and readiness checks used by the ALB). A unit test walks `app.routes` and fails when a
  non-allowlisted route lacks the auth dependency, so an unauthenticated route
  cannot ship by accident.
- The API never sees IdP tokens. Users sign in with Google SSO at the web BFF
  ([NEXTJS.md](NEXTJS.md) section 4). For each API call the BFF presents an
  **internal access token**: a JWT signed `ES256` (ECDSA P-256) with the KMS
  key `api-token-signing`, lifetime 5 minutes, `iss` = `ai101-web`,
  `aud` = `ai101-api`, `sub` = the user's stable IdP subject. This keeps the
  API independent of the IdP (a fork that swaps IdPs changes only the BFF)
  and keeps the API on the approved signature algorithm, even though Google
  signs its own ID tokens with RS256.
- The API validates that token on every request: `ES256` only, signature
  against the KMS public key (fetched at startup and cached), and required
  `iss`, `aud`, `exp`, `nbf`, `iat` with clock skew of 60 seconds or less.
  `none`, HMAC and RSA algorithms are rejected.
- MFA (IA-2(1), IA-2(2)) is enforced by the IdP: the Google Workspace
  organization requires 2-Step Verification with security keys or passkeys
  only (phishing-resistant, per OMB M-22-09). Google ID tokens carry no claim
  that proves which factor was used, so this is an IdP configuration control,
  documented in the SSP with the Workspace policy as evidence.
- Authorization is deny-by-default and object-level: every query is scoped to
  the caller's tenant and ownership in the service layer. Broken object-level
  authorization is the top OWASP API risk, and route-level role checks do not
  prevent it.
- Session lock after 15 minutes of inactivity (AC-11, FedRAMP parameter).
  Short-lived access tokens plus server-side refresh implement it.

### 3.5 Input and output safety

- SQL uses SQLAlchemy 2.x with bound parameters only. `text()` is allowed only
  with bind parameters. SQL is never assembled with f-strings or `%`.
- Forbidden: `pickle`, `marshal`, `shelve` on untrusted data; `yaml.load`
  (use `yaml.safe_load`); `eval`; `exec`; `subprocess` with `shell=True`.
- Outbound HTTP to a user-influenced destination goes through an allowlist of
  hosts and rejects private, loopback and link-local addresses
  (including `169.254.169.254`). This is the SSRF control.
- File paths built from input are resolved and checked to stay inside the
  intended directory.
- Errors return RFC 9457 problem details with a correlation id. Stack traces
  and exception text never reach the client.
- Authenticated responses carry `Cache-Control: no-store`.
- CORS is an explicit origin list per environment, never `*` with
  credentials. Under the BFF pattern in [NEXTJS.md](NEXTJS.md) browsers never
  call the API directly and CORS stays disabled.

### 3.6 Database access

- Async SQLAlchemy with `asyncpg` or `psycopg` 3. Connections use TLS 1.3 with
  certificate and hostname verification against the RDS CA bundle.
- Credentials are IAM database auth tokens or a Secrets Manager secret with
  rotation, never a committed value.
- Two database roles: a migration role (DDL) used only by the migration Job,
  and a runtime role limited to DML on the application schema.
- Migrations use Alembic, are reviewed like code, and follow expand/contract
  so old and new application versions run against the same schema during a
  canary ([CICD.md](CICD.md)). `alembic check` runs in CI to catch model and
  migration drift.
- Integration tests use real PostgreSQL of the same major version as RDS,
  never SQLite. Dialect differences hide bugs.

### 3.7 Cryptography (SC-13)

- Runtime images run in FIPS approved mode on the Aquia `fips-140-3` image
  (OpenSSL FIPS Provider 3.1.2, CMVP certificate #4985, sunset 2030-03-10).
  That module is built from validated source and is user-affirmed on Wolfi. It
  MUST NOT be described as "FIPS 140-3 validated on Wolfi"; no such validation
  entry exists (see the base-image repository's `FIPS.md`).
- **Measured (2026-09-23)**, a probe image built from `python-base` (builder)
  and `fips-140-3` + `python-3.13` (runtime): `openssl list -providers` showed
  the FIPS provider 3.1.2 active over OpenSSL 3.6.4; `hashlib.sha256` worked;
  `hashlib.md5()` raised `UnsupportedDigestmodError`;
  `hashlib.md5(..., usedforsecurity=False)` succeeded.
- The application checks at startup that approved mode is enforced (a default
  `hashlib.md5()` call must raise) and refuses to start in `dev` and above if
  it is not.
- Use the `cryptography` package: `AESGCM` with 256-bit keys, HMAC-SHA-256
  verified with `HMAC.verify()` (constant time), SHA-256 or stronger.
- Forbidden: MD5 or SHA-1 for any security purpose; DES, 3DES, RC4, Blowfish;
  AES-CBC and AES-ECB; `pycrypto` (`Crypto.*`); comparing digests with `==`;
  `random` for anything security relevant (use `secrets`).
- A non-security digest (cache key, ETag) declares it at the call site with
  `usedforsecurity=False`, so both the FIPS module and the scanners treat it
  correctly.
- TLS clients use `ssl.create_default_context()` with
  `minimum_version = ssl.TLSVersion.TLSv1_3` and verification on.
  `verify=False` is forbidden. A peer that cannot do TLS 1.3 is a documented
  exception naming that peer.
- AWS SDK calls use FIPS endpoints (`AWS_USE_FIPS_ENDPOINT=true`).
- Keys come from KMS or Secrets Manager. Application-level encryption uses KMS
  data keys (envelope encryption). No key, secret or OID is hardcoded.

### 3.8 Logging and audit events

Logs are JSON on stdout with the field set defined in
[OBSERVABILITY.md](OBSERVABILITY.md). Audit events (AU-2, AU-3, AU-12) are
emitted for authentication success and failure, authorization denial,
privileged actions, data export, and configuration change. Tokens, passwords,
secrets, request bodies and personal data are never logged. FastAPI, SQLAlchemy
and httpx are instrumented with the OpenTelemetry instrumentation packages so
trace ids appear in every log line.

---

## 4. Type checking (mypy, per module)

Root `pyproject.toml`:

```toml
[tool.mypy]
python_version = "3.13"
strict = true
warn_unreachable = true
enable_error_code = ["ignore-without-code", "redundant-expr", "truthy-bool"]
plugins = ["pydantic.mypy"]

[tool.pydantic-mypy]
init_forbid_extra = true
init_typed = true
warn_required_dynamic_aliases = true
```

Each module is checked in its own isolated environment:

```bash
uv sync --locked --package ai101-api && uv run --no-sync mypy python/api/src python/api/tests
```

Rules:

- `# type: ignore` MUST carry an error code and a reason comment
  (`ignore-without-code` enforces the code).
- No module-level `ignore_errors` overrides. A third-party package without
  types gets a stub dependency or a narrow `[[tool.mypy.overrides]]` entry with
  `ignore_missing_imports = true` for that package only.
- Tests are type checked too.

---

## 5. Testing

### 5.1 Layout and configuration

```
python/<module>/tests/unit/          no network, no database, milliseconds each
python/<module>/tests/integration/   real PostgreSQL and service containers
python/<module>/tests/e2e/           the running local stack (docker compose)
```

Root `pyproject.toml`:

```toml
[tool.pytest.ini_options]
addopts = "-ra --strict-markers --strict-config"
asyncio_mode = "auto"
markers = [
  "integration: needs docker compose services",
  "e2e: runs against the full local stack",
]

[tool.coverage.run]
branch = true
parallel = true

[tool.coverage.report]
fail_under = 80
show_missing = true
skip_covered = true
exclude_also = ["if TYPE_CHECKING:", "raise NotImplementedError", "@overload"]
```

### 5.2 Coverage gate

- Each module MUST reach >= 80% combined line and branch coverage over its
  unit and integration suites. The gate is per module, so a well-covered
  module cannot hide an untested one.
- Changed lines in a PR MUST reach >= 80% (`diff-cover --fail-under=80`), so
  coverage cannot erode while the total stays above the line.
- End-to-end suites are pass/fail gates. They MAY add coverage when the
  containers run under `coverage` with `COVERAGE_PROCESS_START`.
- `# pragma: no cover` needs a reason comment and is reviewed like an ignore.

```bash
uv sync --locked --package ai101-api
docker compose up -d postgres
uv run --no-sync pytest python/api/tests -m "not e2e" \
  --cov=ai101_api --cov-branch --cov-report=term-missing --cov-report=xml \
  --cov-fail-under=80
```

### 5.3 Running a single test

```bash
uv run --no-sync pytest python/api/tests/unit/test_health.py::test_liveness -q
uv run --no-sync pytest python/api/tests -k "auth and not slow"
uv run --no-sync pytest python/api/tests -m integration
uv run --no-sync pytest python/api/tests --lf        # last failed only
```

### 5.4 Test content rules

- Test data is synthetic (polyfactory or factory-boy). Production or federal
  data never appears in fixtures or in any non-production environment.
- Time and randomness are controlled (time-machine, fixed seeds).
- API tests use `httpx.AsyncClient` with `ASGITransport` in-process for
  unit and integration, and real HTTP against the stack for e2e.
- Contract fuzzing: `schemathesis` runs against the committed `openapi.json`
  and the local stack in the e2e stage.
- CI runs the unit suite once inside the FIPS runtime image. A dependency that
  calls MD5 without `usedforsecurity=False` passes on a laptop and fails in
  production; this job catches it first.

---

## 6. Formatting and linting

The standard requires black, isort, ruff and flake8. They overlap, so they
are configured to agree and never fight:

```toml
[tool.black]
line-length = 100
target-version = ["py313"]

[tool.isort]
profile = "black"
line_length = 100

[tool.ruff]
line-length = 100
target-version = "py313"

[tool.ruff.lint]
# "I" (import sorting) is left to isort so there is one import sorter.
select = ["E", "F", "W", "B", "UP", "SIM", "S", "N", "C4", "PT", "RUF", "ASYNC", "DTZ"]

[tool.ruff.lint.per-file-ignores]
"python/*/tests/**" = ["S101"]
```

`.flake8`:

```ini
[flake8]
max-line-length = 100
extend-ignore = E203, E701, E704
exclude = .venv, .git, __pycache__
```

```bash
uv sync --locked --only-group lint
uv run --no-sync black --check python/
uv run --no-sync isort --check-only python/
uv run --no-sync ruff check python/
uv run --no-sync flake8 python/
```

Formatters and linters that do not import project code (black, isort, ruff,
flake8, bandit) live in the root `lint` group. Tools that must import the
project (mypy, pytest, pylint) live in each member's `dev` group.

---

## 7. Python security battery

Every command below runs in the pre-commit or pre-push hook and in CI
([SECURITY.md](SECURITY.md) defines order and gating). The severity floor is
MEDIUM: anything above LOW is reported and blocks.

| Tool | Command | Blocks on |
|---|---|---|
| bandit | `uv run --no-sync bandit -r python/ --ini .bandit --severity-level medium --confidence-level medium` | any finding |
| semgrep | `semgrep scan --config auto --severity WARNING --severity ERROR --error python/` | any finding |
| pylint | `uv run --no-sync pylint --errors-only --disable=import-error,no-name-in-module,no-member --recursive=y python/<module>/src` | any error |
| mypy | section 4, per module | any error |
| pip-audit | see below | any known vulnerability |
| osv-scanner | `osv-scanner scan source -L uv.lock` | any known vulnerability |
| safety | `safety scan --target .` | any unignored vulnerability |

`.bandit`:

```ini
[bandit]
exclude = */tests/*
```

**Measured (bandit 1.9.4, 2026-09-23):** with `-r python/`, an exclude
written as `./python/api/tests` did not match, and the test file was still
scanned. `python/api/tests` and `*/tests/*` both excluded it. Do not write
exclude paths with a leading `./`.

Tests are excluded from bandit only. ruff's `S` rules still cover them (except
`S101`), and the secret scanners cover the whole tree.

pip-audit against the lockfile, with hashes:

```bash
uv export --frozen --all-packages --no-emit-workspace --format requirements-txt > "$TMPDIR/req.txt"
uvx pip-audit -r "$TMPDIR/req.txt" --require-hashes --disable-pip
```

Tool notes:

- **semgrep, measured (1.157.0, 2026-09-23):** `--config auto` fails with
  `--metrics off` ("Cannot create auto config when metrics are off"). `auto`
  therefore sends project metadata to Semgrep. If the ISSO does not accept
  that, use the pinned registry packs with metrics off; these loaded and ran:
  `--config p/python --config p/security-audit --config p/owasp-top-ten --config p/secrets --metrics off`.
- **osv-scanner, measured (2.6.0):** reads `uv.lock` directly and flagged a
  deliberately old `starlette` in a probe project. This is the lockfile-level
  ("constraint level") check that runs in pre-commit whenever `uv.lock` or a
  `pyproject.toml` changes.
- **pip-audit, measured:** the export pipeline above found the same
  `starlette` advisories. `--no-emit-workspace` drops the local `ai101-*`
  packages, which are not on PyPI.
- **safety, measured (3.7.0):** `safety scan` needs a Safety account (use
  `SAFETY_API_KEY` in CI) and applies a policy fetched from the Safety
  platform. In the probe that policy ignored 13 of 16 findings, and the run
  registered the project on the Safety platform dashboard. Safety is
  therefore advisory. pip-audit and osv-scanner are the blocking dependency
  gates. The platform policy MUST be reviewed before its ignores are trusted,
  and sending dependency inventories to the Safety platform needs ISSO
  acceptance.

---

## 8. Container images

Build on `python-base`, run on `fips-140-3`. **Measured (2026-10-15):** this
template scans with Checkov at 0 failed checks and 1 reasoned skip
(`CKV_DOCKER_2`, because ALB target health checks replace `HEALTHCHECK`), and Trivy
config reports 0 misconfigurations. An earlier draft took the base images
from `ARG` values. Checkov cannot resolve those and reported `CKV_DOCKER_7`
(untagged base), so `FROM` lines name the image in full. **Measured
(2026-09-23):** this
exact pattern built and ran a workspace member as `nonroot` (uid 65532) with
FIPS enforcement reaching `hashlib`.

```dockerfile
# syntax=docker/dockerfile:1
# checkov:skip=CKV_DOCKER_2: health is checked by ALB target health checks on ECS
# Both bases are written out in full and pinned by digest, so scanners and
# Renovate can read them (an ARG-indirected FROM is reported as untagged).
FROM ghcr.io/aquia-inc/base-docker-images/python-base:3.13@sha256:<digest> AS builder
USER root
WORKDIR /src
RUN chown nonroot:nonroot /src
USER nonroot
ENV UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy UV_COMPILE_BYTECODE=1
# uv pinned by version and hash (file generated with --generate-hashes)
COPY --chown=nonroot:nonroot python/requirements-build.txt ./
RUN python3 -m pip install --user --no-cache-dir --require-hashes -r requirements-build.txt
COPY --chown=nonroot:nonroot pyproject.toml uv.lock .python-version ./
COPY --chown=nonroot:nonroot python/ python/
RUN uv sync --locked --no-dev --no-editable --package ai101-api

FROM ghcr.io/aquia-inc/base-docker-images/fips-140-3:<version>@sha256:<digest>
USER root
RUN apk add --no-cache python-3.13
USER nonroot
WORKDIR /app
COPY --from=builder --chown=nonroot:nonroot /src/.venv /app/.venv
ENV PATH=/app/.venv/bin:$PATH PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["python3", "-m", "ai101_api"]
```

Rules:

- Every base reference is pinned by digest. Builds use `docker build --pull`
  (the base images are rebuilt daily for CVE fixes), and Renovate raises the
  digest bumps as PRs.
- The runtime image contains no compiler, no package manager cache, no `uv`,
  no tests, and no dev dependencies.
- The API listens on `127.0.0.1:8080` only. TLS from the ALB terminates in
  the task's `tls-sidecar` container ([AWS.md](AWS.md) 4.6), which enforces
  TLS 1.3. Uvicorn has no setting for a TLS 1.3 minimum, so it does not serve
  TLS itself.
- ECS tasks run with a read-only root filesystem, as non-root, with all
  capabilities dropped ([AWS.md](AWS.md) 4.3). Anything that must write gets
  a task volume mounted at that path.
- Images are scanned, get an SBOM, and are signed before push
  ([SECURITY.md](SECURITY.md)).
