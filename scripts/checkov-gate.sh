#!/usr/bin/env bash
# Checkov gate: prove Checkov evaluates checks before trusting a clean result.
#
# Without a Prisma Cloud API key, a severity filter such as
# --check MEDIUM,HIGH,CRITICAL makes Checkov run zero checks and exit 0. To
# catch that and any similar misconfiguration, a canary with one known failure
# per framework is scanned with the same configuration (.checkov.yml) as the
# real scan, and every canary check MUST be reported as failed.
# See docs/TERRAFORM.md section 7.
#
# Usage:
#   scripts/checkov-gate.sh [dir]                      full gate with the checkov on PATH
#   scripts/checkov-gate.sh --write-canary <dir>       write the canary files only (CI)
#   scripts/checkov-gate.sh --assert-canary <json>     check a JSON report of the canary (CI)
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
config="$root/.checkov.yml"
expected=(CKV_AWS_24 CKV_DOCKER_3 CKV_GHA_2)

write_canary() {
  local dir="$1"
  mkdir -p "$dir/.github/workflows"

  # CKV_AWS_24: SSH open to the world.
  cat > "$dir/main.tf" <<'TF'
resource "aws_security_group" "checkov_canary" {
  name = "checkov-canary"
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
TF

  # CKV_DOCKER_3: no USER instruction.
  cat > "$dir/Dockerfile" <<'DOCKERFILE'
FROM scratch
COPY canary /canary
DOCKERFILE

  # CKV_GHA_2: untrusted input interpolated into a run step.
  cat > "$dir/.github/workflows/canary.yml" <<'YAML'
name: canary
on:
  issues:
    types: [opened]
jobs:
  canary:
    runs-on: ubuntu-24.04
    steps:
      - run: echo "${{ github.event.issue.title }}"
YAML
}

# Fails unless every expected check ID appears as a failed check in the text.
assert_reported() {
  local report="$1" id
  for id in "${expected[@]}"; do
    if ! grep -q "$id" <<<"$report"; then
      echo "checkov-gate: canary did not report $id - checks are not all running" >&2
      return 1
    fi
  done
  echo "checkov-gate: canary failed as expected (${expected[*]})"
}

case "${1:-}" in
  --write-canary)
    write_canary "${2:?usage: checkov-gate.sh --write-canary <dir>}"
    ;;
  --assert-canary)
    json="${2:?usage: checkov-gate.sh --assert-canary <results.json>}"
    # Failed check IDs only, from one report object or a list of them.
    failed="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
reports = data if isinstance(data, list) else [data]
for report in reports:
    for check in report.get("results", {}).get("failed_checks", []):
        print(check.get("check_id", ""))
' "$json")"
    assert_reported "$failed"
    ;;
  *)
    target="${1:-.}"
    canary="$(mktemp -d)"
    trap 'rm -rf "$canary"' EXIT
    write_canary "$canary"
    if canary_out="$(checkov --config-file "$config" -d "$canary" 2>&1)"; then
      echo "checkov-gate: canary PASSED - checkov is not evaluating checks" >&2
      printf '%s\n' "$canary_out" >&2
      exit 1
    fi
    assert_reported "$canary_out" || { printf '%s\n' "$canary_out" >&2; exit 1; }
    checkov --config-file "$config" -d "$target"
    ;;
esac
