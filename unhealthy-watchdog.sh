#!/bin/bash
# unhealthy-watchdog.sh — restart a container whose process has died inside it.
#
# THE GAP THIS FILLS. `restart: unless-stopped` covers a container that EXITS.
# It does nothing for a container that stays up while the process inside it is
# gone, and docker does not restart an unhealthy container on its own either.
# So a crash that leaves the supervising shell standing produces a container
# that is running, unhealthy, and will stay that way until a person looks.
#
# That is not hypothetical. A game server aborted with a core dump after
# seventeen hours and stayed down for the rest of the night: the monitoring
# noticed and said so, and nothing acted on it, because nothing was watching
# for the one state docker will not resolve by itself.
#
# WHAT IT ACTS ON: running AND unhealthy. That pair means the process the
# healthcheck looks for is gone while the container around it lives.
#
# WHAT IT DELIBERATELY LEAVES ALONE:
#   * health `starting` — a start_period is long where a first boot downloads
#     tens of gigabytes, and restarting inside it fights the install it is
#     waiting for.
#   * a container that is not running. Stopped means somebody stopped it, and a
#     watchdog that overrules the operator is a worse problem than the one it
#     was brought in to fix.
#   * containers with no healthcheck. There is nothing to judge them by, and
#     restarting on no evidence is just churn.
#
# THE RATE LIMIT IS THE POINT, not a detail. A server that crashes on load will
# crash again on restart, and a guard with no ceiling turns one outage into a
# restart loop that never lets anyone connect and buries the evidence under
# fresh logs. Past the ceiling it says so once and stops.
#
#   unhealthy-watchdog.sh            act
#   unhealthy-watchdog.sh --dry-run  report what it would do, touch nothing
#   unhealthy-watchdog.sh --status   show the restart history it is keeping
set -uo pipefail

MODE="${1:-}"
STATE_DIR="${WATCHDOG_STATE_DIR:-/var/lib/unhealthy-watchdog}"
STATE="$STATE_DIR/history"
LOCK="$STATE_DIR/lock"
MAX_RESTARTS="${WATCHDOG_MAX_RESTARTS:-3}"
WINDOW_SECONDS="${WATCHDOG_WINDOW_SECONDS:-21600}"   # six hours
LABEL="${WATCHDOG_LABEL:-}"                          # optional: only containers with this label

mkdir -p "$STATE_DIR" 2>/dev/null || { echo "cannot write to $STATE_DIR" >&2; exit 1; }
# CREATE IF MISSING, never truncate. The first version of this line was
# `: > "$STATE"`, which empties the file on every run - so the restart history
# was always empty, the ceiling never engaged, and the one safeguard against
# turning a crash into a restart loop silently did nothing. Nothing about the
# output looked wrong.
[ -f "$STATE" ] || : > "$STATE" 2>/dev/null || { echo "cannot create $STATE" >&2; exit 1; }

now="$(date +%s)"
say() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }

if [ "$MODE" = "--status" ]; then
  say "restart history in the last $((WINDOW_SECONDS / 3600))h (ceiling ${MAX_RESTARTS} per container):"
  awk -v cutoff="$((now - WINDOW_SECONDS))" -F'\t' '$1 >= cutoff {c[$2]++} END {for (k in c) printf "  %-40s %d\n", k, c[k]}' "$STATE"
  exit 0
fi

# ONE AT A TIME. A hand run alongside the timer's would have both rewriting the
# history file, and the ceiling that stops one crash becoming a restart loop
# lives in that file. The lock is its own path, so editing this script cannot
# disturb a run already holding it.
# flock where there is one, mkdir where there is not. mkdir is atomic on every
# filesystem worth running this on, which macOS and the minimal images matter
# here because they ship no flock at all.
#
# THE TWO CASES MUST NOT LOOK THE SAME. The first version ran `flock -n 9 ||
# say "another run holds the lock"`, so on a host without flock it announced a
# lock nobody held and exited successfully, having done nothing — a false
# statement and a silent no-op in one line.
LOCKED=false
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK" || { say "cannot open $LOCK"; exit 1; }
  if flock -n 9; then LOCKED=true; fi
else
  if mkdir "$LOCK.d" 2>/dev/null; then
    LOCKED=true
    trap 'rmdir "$LOCK.d" 2>/dev/null' EXIT
  elif [ -d "$LOCK.d" ]; then
    # A lock older than an hour is a crashed run, not a running one. Left
    # forever it would silence this watchdog permanently, which is the failure
    # it exists to prevent, committed by its own safety mechanism.
    if [ -z "$(find "$LOCK.d" -maxdepth 0 -mmin -60 2>/dev/null)" ]; then
      say "clearing a lock older than an hour — a previous run did not finish"
      rmdir "$LOCK.d" 2>/dev/null
      mkdir "$LOCK.d" 2>/dev/null && { LOCKED=true; trap 'rmdir "$LOCK.d" 2>/dev/null' EXIT; }
    fi
  fi
fi
if [ "$LOCKED" != true ]; then
  say "another run holds the lock — skipping"
  exit 0
fi

command -v docker >/dev/null 2>&1 || { say "docker not found"; exit 1; }

# Ask docker for the state rather than parsing `docker ps` output: the word
# "unhealthy" contains "healthy", so a text match on the status column reports
# every unhealthy container as healthy. The filter does not have that problem.
filter=(--filter health=unhealthy --filter status=running)
[ -n "$LABEL" ] && filter+=(--filter "label=$LABEL")

# A while-read loop, not `mapfile`: that is a bash 4 builtin and this has to
# run under the bash 3.2 macOS still ships. Caught locally, and CI on Ubuntu
# would never have found it.
targets=()
while IFS= read -r _id; do
  [ -n "$_id" ] && targets+=("$_id")
done < <(docker ps -q "${filter[@]}" 2>/dev/null)

if [ "${#targets[@]}" -eq 0 ]; then
  say "nothing running and unhealthy"
  exit 0
fi

restarted=0; skipped=0
for id in "${targets[@]}"; do
  name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')"
  [ -n "$name" ] || continue

  # Re-read the state immediately before acting. Between the listing above and
  # this line a container can have been stopped by a person, and restarting it
  # then would be exactly the overruling this refuses to do.
  st="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null)"
  case "$st" in
    running/unhealthy) : ;;
    *) say "$name is now $st — leaving it alone"; skipped=$((skipped+1)); continue ;;
  esac

  recent="$(awk -v cutoff="$((now - WINDOW_SECONDS))" -v n="$name" -F'\t' \
            '$1 >= cutoff && $2 == n {c++} END {print c+0}' "$STATE")"
  if [ "$recent" -ge "$MAX_RESTARTS" ]; then
    say "$name has been restarted $recent times in $((WINDOW_SECONDS / 3600))h — at the ceiling, not restarting"
    say "  this one needs a person: something is making it crash, and restarting it again only hides the logs"
    skipped=$((skipped+1))
    continue
  fi

  if [ "$MODE" = "--dry-run" ]; then
    say "would restart $name (unhealthy; $recent restart(s) in the window)"
    restarted=$((restarted+1))
    continue
  fi

  say "restarting $name (unhealthy; $recent restart(s) in the window)"
  if docker restart "$id" >/dev/null 2>&1; then
    printf '%s\t%s\n' "$now" "$name" >> "$STATE"
    restarted=$((restarted+1))
  else
    say "  restart of $name FAILED"
  fi
done

# Keep the history from growing without bound, but keep more than the window so
# --status can still show what happened just outside it.
if [ -s "$STATE" ]; then
  tmp="$STATE.partial"
  awk -v cutoff="$((now - WINDOW_SECONDS * 4))" -F'\t' '$1 >= cutoff' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
fi

say "done: $restarted restarted, $skipped left alone"
