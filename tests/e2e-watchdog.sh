#!/bin/bash
# Does it restart the one state docker will not, and leave every other alone?
#
# The value of a watchdog is entirely in what it refuses to touch. One that
# restarts a container somebody stopped on purpose, or one still inside its
# start_period, or one that has already crashed three times, is worse than no
# watchdog: it hides the problem and fights the operator.
#
# So each scenario below builds a container in exactly one state and checks the
# decision. Needs docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/unhealthy-watchdog.sh"
RUN="wd-$$"
WORK="$(mktemp -d)"
PASSED=0; FAILED=0

cleanup() { docker rm -f "$RUN-sick" "$RUN-well" "$RUN-starting" "$RUN-none" "$RUN-stopped" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

wd() { WATCHDOG_STATE_DIR="$WORK/state" bash "$SCRIPT" "${1:-}" 2>&1; }
started_at() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null; }
health_is() {  # wait for a container to reach a health state
  local c="$1" want="$2"
  for _ in $(seq 1 40); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = "$want" ] && return 0
    sleep 1
  done
  return 1
}

echo "=== unhealthy watchdog ==="
echo

# A container that is RUNNING and UNHEALTHY — the one case docker leaves alone.
docker rm -f "$RUN-sick" >/dev/null 2>&1
docker run -d --name "$RUN-sick" --health-cmd 'exit 1' --health-interval 2s --health-retries 1 \
  alpine sh -c 'sleep 3600' >/dev/null 2>&1
# Healthy, so the watchdog must ignore it.
docker rm -f "$RUN-well" >/dev/null 2>&1
docker run -d --name "$RUN-well" --health-cmd 'exit 0' --health-interval 2s \
  alpine sh -c 'sleep 3600' >/dev/null 2>&1
# No healthcheck at all.
docker rm -f "$RUN-none" >/dev/null 2>&1
docker run -d --name "$RUN-none" alpine sh -c 'sleep 3600' >/dev/null 2>&1
# Still inside its start_period, and failing: health reads `starting`.
docker rm -f "$RUN-starting" >/dev/null 2>&1
docker run -d --name "$RUN-starting" --health-cmd 'exit 1' --health-interval 2s \
  --health-start-period 300s alpine sh -c 'sleep 3600' >/dev/null 2>&1

if ! health_is "$RUN-sick" unhealthy; then
  fail "the fixture never became unhealthy — nothing below would mean anything"
  echo; echo "passed: $PASSED   failed: $FAILED"; exit 1
fi

before_sick="$(started_at "$RUN-sick")"
before_well="$(started_at "$RUN-well")"
before_none="$(started_at "$RUN-none")"
before_start="$(started_at "$RUN-starting")"

out="$(wd)"

if [ "$(started_at "$RUN-sick")" != "$before_sick" ]; then
  pass "a running, unhealthy container is restarted"
else
  fail "the unhealthy container was not restarted"; printf '%s\n' "$out" | sed 's/^/        /'
fi
if [ "$(started_at "$RUN-well")" = "$before_well" ]; then
  pass "a healthy container is left alone"
else
  fail "a healthy container was restarted"
fi
if [ "$(started_at "$RUN-none")" = "$before_none" ]; then
  pass "a container with no healthcheck is left alone — nothing to judge it by"
else
  fail "a container with no healthcheck was restarted"
fi
if [ "$(started_at "$RUN-starting")" = "$before_start" ]; then
  pass "a container still inside its start period is left alone"
else
  fail "a starting container was restarted, which fights the install it is waiting for"
fi

# Stopped means somebody stopped it.
docker rm -f "$RUN-stopped" >/dev/null 2>&1
docker run -d --name "$RUN-stopped" --health-cmd 'exit 1' --health-interval 2s --health-retries 1 \
  alpine sh -c 'sleep 3600' >/dev/null 2>&1
health_is "$RUN-stopped" unhealthy || true
docker stop "$RUN-stopped" >/dev/null 2>&1
wd >/dev/null 2>&1
if [ "$(docker inspect -f '{{.State.Status}}' "$RUN-stopped" 2>/dev/null)" != "running" ]; then
  pass "a stopped container stays stopped — a watchdog must not overrule the operator"
else
  fail "a container somebody stopped was started again"
fi

# THE CEILING. A server that crashes on load crashes again on restart, and a
# guard without a limit turns one outage into a loop that buries the evidence.
health_is "$RUN-sick" unhealthy || true
for _ in 1 2 3; do wd >/dev/null 2>&1; health_is "$RUN-sick" unhealthy || true; done
at_ceiling="$(started_at "$RUN-sick")"
out="$(wd)"
if printf '%s' "$out" | grep -q 'at the ceiling'; then
  pass "past the ceiling it stops restarting and says why"
else
  fail "the ceiling did not engage"; printf '%s\n' "$out" | sed 's/^/        /'
fi
if [ "$(started_at "$RUN-sick")" = "$at_ceiling" ]; then
  pass "and the container is genuinely left alone once it is there"
else
  fail "it restarted the container after announcing the ceiling"
fi

# --dry-run must change nothing at all.
rm -rf "$WORK/state"
docker rm -f "$RUN-sick" >/dev/null 2>&1
docker run -d --name "$RUN-sick" --health-cmd 'exit 1' --health-interval 2s --health-retries 1 \
  alpine sh -c 'sleep 3600' >/dev/null 2>&1
health_is "$RUN-sick" unhealthy || true
before="$(started_at "$RUN-sick")"
out="$(wd --dry-run)"
if [ "$(started_at "$RUN-sick")" = "$before" ] && printf '%s' "$out" | grep -q 'would restart'; then
  pass "--dry-run reports what it would do and touches nothing"
else
  fail "--dry-run acted"; printf '%s\n' "$out" | sed 's/^/        /'
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
