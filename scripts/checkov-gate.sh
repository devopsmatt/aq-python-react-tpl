#!/usr/bin/env bash
# Checkov gate: prove Checkov evaluates checks before trusting a clean result.
#
# Without a Prisma Cloud API key, a severity filter such as
# --check MEDIUM,HIGH,CRITICAL makes Checkov run zero checks and exit 0. To
# catch that and any similar misconfiguration, this script first scans a canary
# (one known failure per framework) with the same flags as the real scan. Each
# canary check MUST fail; otherwise the gate fails before the real scan runs.
# See docs/TERRAFORM.md section 7.
#
# Usage: scripts/checkov-gate.sh [dir]   (uses the checkov on PATH: the installed
#        binary locally, the ci/tools/checkov pin in CI)
set -euo pipefail

target="${1:-.}"
flags=(--framework 'terraform,dockerfile,github_actions' --quiet --compact)
expected=(CKV_AWS_24 CKV_DOCKER_3 CKV_GHA_2)

canary="$(mktemp -d)"
trap 'rm -rf "$canary"' EXIT
mkdir -p "$canary/.github/workflows"

# CKV_AWS_24: SSH open to the world.
cat > "$canary/main.tf" <<'TF'
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
cat > "$canary/Dockerfile" <<'DOCKERFILE'
FROM scratch
COPY canary /canary
DOCKERFILE

# CKV_GHA_2: untrusted input interpolated into a run step.
cat > "$canary/.github/workflows/canary.yml" <<'YAML'
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

if canary_out="$(checkov -d "$canary" "${flags[@]}" 2>&1)"; then
  echo "checkov-gate: canary PASSED - checkov is not evaluating checks" >&2
  printf '%s\n' "$canary_out" >&2
  exit 1
fi
for id in "${expected[@]}"; do
  if ! grep -q "$id" <<<"$canary_out"; then
    echo "checkov-gate: canary did not report $id - checks are not all running" >&2
    printf '%s\n' "$canary_out" >&2
    exit 1
  fi
done
echo "checkov-gate: canary failed as expected (${expected[*]})"

checkov -d "$target" "${flags[@]}"
