# Next.js Standards

Scope: the Next.js application under `web/`, covering routing, server and
client boundaries, authentication, security headers, assets, builds and
containers. Component-level TypeScript, accessibility and testing rules are in
[REACT.md](REACT.md) and apply here in full.

Related: [SECURITY.md](SECURITY.md), [CICD.md](CICD.md), [AWS.md](AWS.md),
[OBSERVABILITY.md](OBSERVABILITY.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as described
in RFC 2119.

---

## 1. Baseline

| Item | Standard |
|---|---|
| Framework | Next.js, current stable major, App Router only |
| Runtime | Node.js 24 LTS, matching the Aquia `nodejs-base` image |
| Package manager | npm, `package-lock.json` committed |
| Output | `output: "standalone"` |
| Build image | `ghcr.io/aquia-inc/base-docker-images/nodejs-base` |
| Runtime image | `ghcr.io/aquia-inc/base-docker-images/fips-140-3` plus the Wolfi `nodejs` 24 package |

`web/.nvmrc` pins `24`. **Measured (2026-09-23):** the `nodejs-base` image
ships Node v24.21.0, and at least one development machine had Node 20. Local
builds MUST use Node 24 so local and container builds are identical.

---

## 2. Architecture: Backend-for-Frontend

- The browser talks only to the Next.js server. The Next.js server calls the
  FastAPI service through the internal ALB with the user's access token,
  using TLS.
- Tokens stay on the server. The browser holds an encrypted, `httpOnly`,
  `Secure`, `SameSite=Lax` session cookie, and the server maps it to tokens.
- Because browsers never call the API, the API keeps CORS disabled
  ([PYTHON.md](PYTHON.md) 3.5).
- The API's generated types ([REACT.md](REACT.md) section 1) are used by the
  server-side client, so a contract change fails the web build.

---

## 3. Server and client boundaries

- Server Components are the default. Client Components are small leaves.
- Every module that touches secrets, tokens, the database, or internal
  service URLs imports `server-only` at the top. Importing such a module into
  a Client Component then fails the build instead of leaking the value.
- `NEXT_PUBLIC_*` variables are compiled into the client bundle at build time.
  They MUST NOT hold secrets. They also MUST NOT hold per-environment values:
  the same image is promoted from `dev` to `prod` ([CICD.md](CICD.md)), so
  environment configuration is read on the server at runtime and passed down.
- Props passed from Server to Client Components are serialized into the page.
  Pass only the fields the client needs, never whole records.

---

## 4. Authentication and authorization

- **Sign-in is Google SSO:** OIDC authorization code flow with PKCE (`S256`)
  against `https://accounts.google.com`. The client id is configuration and
  the client secret comes from Secrets Manager, so a fork can point the same
  code at another OIDC IdP.
- **ID token validation (server-side, at sign-in):** `iss` is
  `https://accounts.google.com` (or `accounts.google.com`), `aud` is our client
  id, `exp` and `iat` are valid, the `nonce` matches, `email_verified` is
  `true`, and the **`hd` claim equals the organization's Workspace domain**.
  The `hd` request parameter is only a hint for Google's account chooser; any
  Google account can complete the flow unless the server checks the `hd`
  claim. Without that check, anyone with a personal Gmail account could sign
  in.
- **Measured (2026-10-16):** Google's discovery document lists only `RS256`
  for ID token signatures, and its JWKS holds only RSA keys. RS256 (RSA
  PKCS#1 v1.5) is deprecated under the crypto standard. Accepting it at this
  one point, for this one issuer, is an IdP-imposed exception recorded in the
  SSP. Nothing we sign uses RSA.
- After sign-in the BFF keeps an encrypted session (section 2) and mints the
  short-lived ES256 internal access token that the API accepts
  ([PYTHON.md](PYTHON.md) 3.4). Google tokens never leave the server and never
  reach the API.
- Phishing-resistant MFA is enforced by the Google Workspace organization
  policy ([PYTHON.md](PYTHON.md) 3.4). Google is an external service in the
  SSP: confirm its FedRAMP marketplace status for the identity service in
  use. Profile pictures are not loaded, so no Google asset requests come from
  the browser.
- Authorization is checked where data is read or changed: in every Server
  Component data loader, Route Handler and Server Action. The request proxy
  (`proxy.ts`, called `middleware.ts` before Next.js 16) MAY redirect
  anonymous users for UX, but MUST NOT be the only check. CVE-2025-29927
  showed that a crafted header could skip middleware entirely, and every app
  that authorized only there was exposed.
- Server Actions are public HTTP endpoints. Each one validates its input with
  `zod`, checks authentication and authorization itself, and returns only what
  the caller may see. `serverActions.allowedOrigins` lists only the
  application's own origins.
- Authenticated pages render dynamically and send `Cache-Control: no-store`.
  User-specific data is never cached with `"use cache"`, `unstable_cache` or
  fetch caching unless the cache key includes the user and the data is safe to
  keep.
- The inactivity lock (AC-11, 15 minutes) and its accessible warning are
  implemented in the session layer ([REACT.md](REACT.md) 4.1).

---

## 5. Security headers and asset security

### 5.1 Headers

Content Security Policy uses a per-request nonce, generated in `proxy.ts` and
applied by Next.js to its own scripts:

```
default-src 'self';
script-src 'self' 'nonce-{NONCE}' 'strict-dynamic';
style-src 'self' 'nonce-{NONCE}';
img-src 'self' blob: data:;
font-src 'self';
connect-src 'self';
object-src 'none';
base-uri 'none';
form-action 'self' https://accounts.google.com;
frame-ancestors 'none';
upgrade-insecure-requests
```

`form-action` includes `https://accounts.google.com` because sign-in submits
a form that redirects to Google, and browsers apply `form-action` to the
redirect as well. A nonce-based CSP forces dynamic rendering; that is
acceptable for an authenticated application. `unsafe-inline` and `unsafe-eval` are never
allowed in `script-src`.

Static headers in `next.config.ts`:

| Header | Value |
|---|---|
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=(), payment=(), usb=()` |
| `Cross-Origin-Opener-Policy` | `same-origin` |
| `Cross-Origin-Resource-Policy` | `same-origin` |

Also in `next.config.ts`: `poweredByHeader: false`, and
`productionBrowserSourceMaps: false`. Source maps go to internal error
tooling, never to the public site.

### 5.2 Assets

- All scripts, styles, fonts and images are served from the application's own
  origin. No third-party CDNs, tag managers or analytics beacons. Each would
  be an unreviewed data flow out of the authorization boundary, and the CSP
  above blocks them anyway.
- Fonts use `next/font/local`, or `next/font/google`, which downloads the
  font at build time and serves it from the app. Nothing is fetched from
  Google at runtime.
- `next/image`: `images.remotePatterns` lists only exact hosts the product
  needs (none, by default), and `dangerouslyAllowSVG` stays `false`. The image
  optimizer fetches remote URLs server-side, so a loose pattern is an SSRF and
  DoS surface. Optimizer denial-of-service CVEs have already been published.
- Uploaded files are checked for size and type (by content, not extension),
  stored in a private S3 bucket, scanned for malware before first use, and
  served back with `Content-Disposition: attachment` from a separate path.
- `experimental.sri` (Subresource Integrity) MAY be evaluated. Until it is
  stable, same-origin assets plus the nonce CSP are the control.

---

## 6. Error handling, logging and telemetry

- `error.tsx` and `global-error.tsx` boundaries show a generic message and the
  error digest. Stack traces never reach the client.
- `instrumentation.ts` registers OpenTelemetry for the Node.js runtime.
  Traces and logs carry the trace id and follow the schema in
  [OBSERVABILITY.md](OBSERVABILITY.md). Server logs are JSON on stdout.
- Next.js telemetry is disabled (`NEXT_TELEMETRY_DISABLED=1` in every build
  and runtime environment), so build metadata is not sent to an external
  service.

---

## 7. Build and container

`next.config.ts` sets `output: "standalone"`. Build on `nodejs-base`, run on
`fips-140-3` with Node from Wolfi.

**Measured (2026-09-23):**

| Image | Node | `crypto.getFips()` | MD5 hash |
|---|---|---|---|
| `nodejs-base:latest` | v24.21.0 | 0 | allowed |
| `fips-140-3:latest` + `apk add nodejs~=24` | v24.21.0 | 1 | refused (`digital envelope routines::unsupported`) |

Node on `nodejs-base` is not in FIPS mode. Node installed on `fips-140-3`
picks up the FIPS provider automatically. So the runtime stage MUST be
`fips-140-3`. The build stays on `nodejs-base` because build tooling may use
non-approved hashes internally for content hashing.

```dockerfile
# syntax=docker/dockerfile:1
# checkov:skip=CKV_DOCKER_2: health is checked by ALB target health checks on ECS
FROM ghcr.io/aquia-inc/base-docker-images/nodejs-base:24@sha256:<digest> AS builder
USER root
WORKDIR /src
ENV NEXT_TELEMETRY_DISABLED=1
COPY web/package.json web/package-lock.json web/.npmrc ./
RUN npm ci
COPY web/ ./
RUN npm run build

FROM ghcr.io/aquia-inc/base-docker-images/fips-140-3:<version>@sha256:<digest>
USER root
RUN apk add --no-cache "nodejs~=24"
USER nonroot
WORKDIR /app
# Listen on loopback only; the tls-sidecar container (AWS.md 4.6) is the
# task's only way in.
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=8080 HOSTNAME=127.0.0.1
COPY --from=builder --chown=nonroot:nonroot /src/.next/standalone ./
COPY --from=builder --chown=nonroot:nonroot /src/.next/static ./.next/static
COPY --from=builder --chown=nonroot:nonroot /src/public ./public
ENTRYPOINT ["node", "server.js"]
```

Rules:

- Base images are pinned by digest and built with `--pull`
  ([PYTHON.md](PYTHON.md) section 8 has the same rules).
- ECS tasks run with a read-only root filesystem. Next.js writes its cache to
  `/app/.next/cache`, so that path is a task volume mount ([AWS.md](AWS.md)
  4.3).
- **Measured (2026-10-15):** this template scans with Checkov at 0 failed
  checks and 1 reasoned skip (`CKV_DOCKER_2`), and Trivy config reports 0
  misconfigurations. It has not yet been built, because there is no app yet.
- **Required verification (not yet measured):** the Next.js server itself must
  run correctly in FIPS mode. The Playwright e2e suite MUST pass against the
  `fips-140-3` runtime image before the first release. A framework or library
  path that calls MD5 or SHA-1 at request time fails only there.

---

## 8. Testing

- Unit and component tests: Vitest ([REACT.md](REACT.md) section 5). Vitest
  cannot render async Server Components, so those are covered by e2e tests.
- End-to-end: Playwright against the docker compose stack locally, and against
  the preview (blue/green) or canary stack in the pipeline
  ([CICD.md](CICD.md)). Every route gets an axe scan ([REACT.md](REACT.md)
  4.2).

```bash
npx playwright test                                  # all e2e
npx playwright test tests/e2e/login.spec.ts          # one file
npx playwright test -g "locks after inactivity"      # by test name
npx playwright test --project=chromium --headed      # debug in a browser
```

- Lint uses the ESLint CLI with `eslint-config-next` (`npx eslint .`). The
  `next lint` command was removed in Next.js 16.

---

## 9. Security scanning

The battery in [REACT.md](REACT.md) section 7 (semgrep, bearer, njsscan,
retire, npm audit, osv-scanner) covers `web/`, including Route Handlers,
Server Actions and `proxy.ts`. The built image is scanned by Trivy
([SECURITY.md](SECURITY.md)).

Framework CVEs get special attention because a single release can expose every
application: CVE-2025-29927 (middleware authorization bypass) and
CVE-2025-55182 (remote code execution through React Server Components) are
two recent examples. Critical Next.js and React advisories follow the
emergency patch path in [SECURITY.md](SECURITY.md).
