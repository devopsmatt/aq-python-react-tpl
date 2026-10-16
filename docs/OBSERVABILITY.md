# Observability Standards

Scope: logs, metrics, traces, audit events, alerting, paging and runbooks for
every environment, covering the LGTM stack (Loki, Grafana, Tempo, Mimir)
running as ECS services on Fargate, and the AWS-native logging underneath it.

Related: [AWS.md](AWS.md) (AWS-native log sources), [SECURITY.md](SECURITY.md)
(incident response), [CICD.md](CICD.md) (canary rollback alarms),
[PYTHON.md](PYTHON.md) and [NEXTJS.md](NEXTJS.md) (instrumentation).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as described
in RFC 2119.

---

## 1. Architecture

```
 ECS tasks (web, api)
   |  OTLP: traces, metrics                 stdout: JSON logs
   |                                          |  FireLens (Fluent Bit sidecar)
   v                                          v                 \
 Grafana Alloy  (ECS service: OTLP receiver, redaction)     CloudWatch Logs
   |                  |                       |                 (AU archive path)
   v                  v                       v
 Tempo (traces)    Mimir (metrics)    Loki (logs)      object storage: S3 + CMK,
   \                  |                  /             access through task roles
    \                 |                 /
     +------------ Grafana ------------+------ CloudWatch data source
                      |                        (AWS-native logs and metrics)
          Grafana Alerting / Mimir Alertmanager
                      |
        P0, P1 -> PagerDuty (Events API v2)
        P2, P3 -> ticket queue

 AWS-native (see AWS.md section 9):
   CloudTrail, VPC Flow Logs, ECS task logs and Exec sessions, ALB, WAF, RDS,
   Route 53 Resolver
     -> CloudWatch Logs and the log-archive S3 bucket (Object Lock)
   Security Hub, GuardDuty, Inspector findings, CloudWatch alarms
     -> EventBridge -> SNS -> PagerDuty (P0, P1) or ticket queue
```

Placement:

- `prod` runs its own observability stack in an `observability` ECS cluster
  inside the `prod` account. Production telemetry stays inside the
  authorization boundary.
- `dev` and `stage` MAY share one non-production stack to save cost.
- Locally, docker compose runs a single-container LGTM image for development
  only ([CICD.md](CICD.md) 4.1).

---

## 2. Instrumentation

- Every service uses the OpenTelemetry SDK and exports traces and metrics
  over OTLP to the Alloy service. Logs go to stdout and FireLens ships them to
  both Loki and CloudWatch Logs. Python uses the FastAPI, SQLAlchemy, httpx and logging
  instrumentations ([PYTHON.md](PYTHON.md) 3.8). Next.js registers
  OpenTelemetry in `instrumentation.ts` ([NEXTJS.md](NEXTJS.md) section 6).
- Resource attributes on every signal: `service.name`, `service.version` (the
  release version), `deployment.environment`, plus the ECS attributes from the
  OpenTelemetry ECS resource detector (cluster, task ARN, task family and
  revision).
- W3C trace context propagates across every hop (browser to web, web to api,
  api to the database spans). A log line written inside a span
  carries its `trace_id` and `span_id`.
- Grafana links the signals: Loki derived fields jump to the Tempo trace,
  Tempo jumps to the logs for the span, and metrics carry exemplars that open
  the example trace.
- Alloy runs a redaction step (attribute deletion and hashing) before export,
  as a second line of defense behind the application's own rules. It removes
  authorization headers, cookies, tokens, and known personal data fields.

---

## 3. Logs and audit events

### 3.1 Log record schema

JSON, one object per line on stdout:

| Field | Required | Notes |
|---|---|---|
| `timestamp` | yes | RFC 3339, UTC, millisecond precision. Clocks sync to the Amazon Time Sync Service (AU-8). |
| `level` | yes | `debug`, `info`, `warn`, `error`, `critical` |
| `service`, `version`, `environment` | yes | Match the OTel resource attributes. |
| `event` | yes | Stable snake_case name, for example `db_pool_exhausted`. Dashboards and alerts key on it, not on message text. |
| `message` | yes | Human-readable. |
| `trace_id`, `span_id` | when in a span | |
| `request_id` | for request-scoped logs | Also returned to the client in error responses. |
| `tenant_id`, `tenant_name` | when the event concerns one tenant | `platform-wide` when it does not. |

Never logged: passwords, tokens, API keys, session cookies, full request or
response bodies, federal data, or personal data. `debug` is off in `stage` and
`prod`.

### 3.2 Audit events (AU-2, AU-3, AU-12)

Audit events use the same schema with `event` prefixed `audit.` and these
extra fields: `actor.id`, `actor.type` (`user`, `service`), `action`,
`resource.type`, `resource.id`, `outcome` (`success`, `failure`), `reason`
(on failure), `source_ip`, `user_agent`.

Required audit events:

- authentication success, failure and logout; MFA challenges (at the IdP)
- session lock and session termination (AC-11, AC-12)
- authorization denials
- creation, change and deletion of accounts, roles and permissions
- privileged and administrative actions
- data exports and bulk reads
- changes to security-relevant configuration
- starting or stopping audit logging itself

Audit events go to Loki for search AND to the log-archive bucket through
CloudWatch Logs, so the Object Lock copy exists even if Loki is unavailable.

---

## 4. Metrics and SLOs

- Services expose RED metrics (request rate, errors, duration histograms) per
  route and per dependency. Infrastructure uses USE metrics (utilization,
  saturation, errors). ECS service and task CPU and memory come from
  CloudWatch (Container Insights), and ALB target metrics cover the edge.
- **Cardinality:** labels never contain user ids, request ids, raw URLs, or
  anything unbounded. Routes are labeled by template (`/items/{id}`), not by
  path.
- **SLOs:** each user-facing service defines availability and latency SLOs.
  Their targets come from the project's acceptance criteria and live in the
  repository next to the alert rules.
- **Burn-rate alerts** use multiple windows:

| Budget burn | Long window | Short window | Severity |
|---|---|---|---|
| 14.4x | 1 h | 5 min | P1 |
| 6x | 6 h | 30 min | P1 |
| 1x | 3 d | 6 h | P2 |

The ECS canary rollback alarms in [CICD.md](CICD.md) 8.1 use the ALB's own
CloudWatch metrics with thresholds taken from these same SLOs, so "healthy"
means the same thing during a canary and
after it.

---

## 5. Alerting and PagerDuty

### 5.1 Severity matrix

| Severity | Meaning | Examples | Route | Default targets |
|---|---|---|---|---|
| **P0** | Production is down, or a security incident is confirmed or likely | user-facing outage; suspected federal data exposure; root account sign-in; KMS key deletion scheduled; CloudTrail or GuardDuty disabled in `prod` | PagerDuty high urgency; the on-call engineer and the incident commander are paged | acknowledge 5 min, IC engaged 15 min |
| **P1** | Major degradation or a serious security finding in `prod` | SLO fast burn; canary or blue/green rolled back; RDS failover or storage below 10%; certificate expiring within 7 days; GuardDuty HIGH; new CRITICAL or HIGH Security Hub finding; telemetry pipeline down (watchdog) | PagerDuty high urgency, on-call engineer | acknowledge 15 min |
| **P2** | Partial or slow-burning problems; any non-production outage | SLO slow burn; MEDIUM Security Hub finding; Terraform drift; backup job failure in non-prod | ticket queue, business hours | triage next business day |
| **P3** | Informational | cost anomaly; an expiring accepted-risk entry | ticket queue | weekly review |

Only P0 and P1 reach PagerDuty. P2 and P3 open tickets so on-call is paged only
for things that need a person now.

### 5.2 Integration

- Grafana Alerting and Mimir Alertmanager send to PagerDuty through the
  Events API v2 with one integration (routing) key per service. Keys are
  stored in Secrets Manager and mounted at runtime.
- AWS-native alarms and security findings go EventBridge -> SNS -> PagerDuty,
  so they still page when the in-cluster stack is down.
- **Watchdog (dead man's switch):** the in-cluster stack cannot report its own
  death. Alloy publishes a heartbeat metric to CloudWatch, and a CloudWatch
  alarm that treats missing data as breaching pages P1 through SNS. This
  path does not depend on anything in the cluster.
- Alerts carry a stable `dedup_key` and resolve automatically when the
  condition clears.
- PagerDuty is outside the AWS boundary. Confirm its current FedRAMP
  marketplace status and list it in the SSP as an external service.

### 5.3 Alert payload standard

Every alert, whatever its source, carries:

| Field | Content |
|---|---|
| `summary` | what is wrong, in one line |
| `severity` | P0 to P3 |
| `environment`, `service`, `component` | where |
| `tenant` | the tenant or customer id AND name, or explicitly `platform-wide` |
| `runbook_url` | link to `docs/runbooks/<alert-name>.md` |
| `dashboard_url` | the Grafana panel that shows the condition |
| `query` | the expression that fired, with the observed value and threshold |

Payloads never contain federal data, personal data, secrets or raw log lines.

### 5.4 Rules as code

- Alert and recording rules live in `deploy/observability/rules/` in Prometheus
  rule format. They are unit tested with `promtool test rules` and loaded with
  `mimirtool rules sync`.
- Dashboards are JSON in `deploy/observability/dashboards/`, provisioned into
  Grafana. Changes made in the UI are not saved; the repository is the source.
- A CI check fails when an alert rule has no `runbook_url` annotation, or when
  it points to a runbook file that does not exist.

---

## 6. Runbooks

Every alert has a runbook at `docs/runbooks/<alert-name>.md`, written from
this template:

```markdown
# <Alert name>

- Severity: P0 | P1 | P2 | P3
- Owner: <team>
- Last tested: <YYYY-MM-DD> (game day or real incident)

## What fired
The condition, the query, and the threshold, in plain words.

## Impact
Who and what is affected, and whether federal data could be involved.
If federal data could be involved, start the incident process in
SECURITY.md section 8 now (1-hour reporting clock).

## Diagnose
Numbered steps, each with the exact command, query or dashboard link and
what a good and a bad result look like.

## Mitigate
The fastest safe action to restore service (rollback, scale, fail over,
block), with exact commands.

## Resolve
The lasting fix, and how to confirm the alert has cleared.

## Escalate
Who to page next and when. Vendor or AWS support paths.

## Communicate
Status updates: who, where, how often. Regulatory notifications if a
security incident.

## After
Post-incident review link. Runbook updates this incident showed were needed.
```

Failure modes that MUST have runbooks before the first `prod` release:

| Area | Failure modes |
|---|---|
| Application | 5xx error spike; latency SLO burn; tasks stopping repeatedly; login failures spike or IdP unreachable; failed database migration |
| Deployment | canary or blue/green rolled back by alarm or circuit breaker; lifecycle hook failure; service not reaching steady state; manual rollback procedure |
| Data | RDS high CPU or connection exhaustion; storage low; Multi-AZ failover; replication lag; backup failure; restore from snapshot (practiced) |
| ECS | tasks failing to start (image pull, secrets, IAM); Fargate capacity or placement failures; task CPU or memory saturation; ECS Exec break-glass session |
| Edge | ALB unhealthy targets; WAF block spike or false positives; certificate expiry or renewal failure; DNS failure |
| Security | new CRITICAL or HIGH Security Hub finding; GuardDuty finding; root sign-in; CloudTrail, Config or GuardDuty disabled; KMS key disabled or scheduled for deletion; leaked secret detected |
| Secrets | rotation failure; External Secrets sync failure |
| Observability | watchdog heartbeat missing; Loki, Mimir or Tempo ingestion errors; PagerDuty delivery failure |
| Cost | cost anomaly or budget threshold crossed |

Runbooks are exercised in a game day at least once a quarter. The
`Last tested` date is updated each time.

---

## 7. Retention

Retention follows OMB M-21-31, which the FedRAMP AU-11 parameter references:
12 months in active, searchable storage plus 18 months in cold storage. A log
category is excluded only when the ISSO confirms in writing that it is out of
scope.

| Data | Searchable (active) | Cold | Where |
|---|---|---|---|
| Audit and security logs (application audit, CloudTrail, ECS Exec sessions, WAF, VPC Flow, Resolver, RDS audit) | 12 months: S3 Standard in the log archive, queryable with Athena; the most recent 30 days also in Loki | 18 months, S3 archive storage class | log-archive bucket, Object Lock |
| Application operational logs | 30 days in Loki, and 12 months in the log archive | 18 months | as above |
| Traces | 14 days in Tempo | none | Tempo S3 bucket |
| Metrics | 13 months in Mimir | none | Mimir S3 bucket |

Keeping long-term searchable logs in S3 queried by Athena, rather than
holding 12 months in Loki, is the cost-conscious choice. Loki stays small and
fast for incident work. The volumes behind this trade-off are measured in
`dev` and `stage` and put through the cost approval protocol
([TERRAFORM.md](TERRAFORM.md) section 6) before `prod` sizing.

---

## 8. Running the LGTM stack on ECS

- Each component runs as an ECS service on Fargate in the boundary's
  `observability` cluster: Loki, Tempo and Mimir in their single-binary
  (monolithic) modes to start, plus Grafana and the Alloy collector. Services
  find each other through ECS Service Connect.
- Images are mirrored into ECR by digest and pass the same Trivy gate as our
  own images ([AWS.md](AWS.md) section 5). An upstream image with fixable
  MEDIUM or higher findings is rebuilt on an Aquia base or tracked per
  [SECURITY.md](SECURITY.md) 4.4. Task definitions follow
  [AWS.md](AWS.md) 4.3.
- Security groups allow only Alloy and FireLens to write to the stores and
  only Grafana to query them.
- Storage: one S3 bucket per store, encrypted with the `logs` CMK, TLS only,
  with lifecycle rules matching section 7. Each task role can reach only its
  own bucket.
- **Write-ahead logs:** Fargate task storage is ephemeral. If a single-binary
  Loki or Mimir task restarts, data it has not yet flushed to S3 is lost.
  That is acceptable in `dev`. In `stage` and `prod` the stores run at least
  two replicas with replication, or keep their WAL on EFS. Either way the
  choice goes through cost approval with measured ingestion volumes.
- Multi-tenancy headers (`X-Scope-OrgID`) are on in Loki, Tempo and Mimir.
  `prod` and non-prod never share a tenant.
- Sizing: start small and scale from measured ingestion rates, with each
  sizing change going through cost approval.
- Grafana sits behind an internal ALB. Sign-in only through OIDC SSO with
  MFA; anonymous access and basic auth are off. The admin password is in
  Secrets Manager. Roles are mapped from IdP groups, with Viewer as the
  default. Grafana OSS does not include full user audit logging (an
  Enterprise feature). If the 3PAO requires Grafana-level audit trails, the
  licensing goes through cost approval. Until then, access is controlled
  through SSO roles and Grafana server logs record sign-ins.
- The stack monitors itself (ingestion rate, dropped samples, compactor lag,
  query errors), and the watchdog in 5.2 covers total failure.
- **Managed alternative, if the numbers favor it:** Amazon Managed Service
  for Prometheus and Amazon Managed Grafana could replace Mimir and Grafana.
  That departs from the LGTM standard, so it needs explicit approval backed by
  a measured cost comparison.
