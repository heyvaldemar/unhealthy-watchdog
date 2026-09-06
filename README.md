# Unhealthy watchdog

[![Tests](https://github.com/heyvaldemar/unhealthy-watchdog/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/unhealthy-watchdog/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Restarts a container whose process has died inside it — the one state docker leaves alone.

`restart: unless-stopped` covers a container that **exits**. It does nothing for a container that stays up while the process inside it is gone, and docker will not restart an unhealthy container on its own either. So a crash that leaves the supervising shell standing produces a container that is running, unhealthy, and will stay that way until a person looks at it.

That combination is what this acts on, and nothing else.

## Where this comes from

A game server aborted with a core dump after seventeen hours of uptime, dropping two people mid-round. Everything downstream worked: the monitoring noticed within four checks and said so. Nothing acted on it, because nothing was watching for the one state docker does not resolve by itself, and the server stayed down for the rest of the night.

## What it refuses to touch

The value of a watchdog is almost entirely in this list.

**Healthy containers.** Obviously.

**`starting`.** A long `start_period` usually means a first boot that is still downloading tens of gigabytes. Restarting inside it fights the install it is waiting for, and does so repeatedly.

**Containers with no healthcheck.** There is nothing to judge them by, and restarting on no evidence is churn.

**Stopped containers.** Stopped means somebody stopped it. A watchdog that overrules the operator is a worse problem than the one it was brought in to fix.

**Anything past the ceiling.** A container that crashes on load will crash again on restart. A guard without a limit turns one outage into a restart loop that never lets anyone connect and buries the evidence under fresh logs. Three restarts per six hours by default; past that it says so once and stops, because that one needs a person.

## Install

```bash
sudo install -m 755 unhealthy-watchdog.sh /usr/local/sbin/unhealthy-watchdog.sh
sudo install -m 644 unhealthy-watchdog.service unhealthy-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload

sudo unhealthy-watchdog.sh --dry-run     # see what it would do
sudo systemctl enable --now unhealthy-watchdog.timer
sudo unhealthy-watchdog.sh --status      # the restart history it is keeping
```

## Configuration

| Variable | Default | What it changes |
|---|---|---|
| `WATCHDOG_MAX_RESTARTS` | `3` | restarts allowed per container per window |
| `WATCHDOG_WINDOW_SECONDS` | `21600` | the window, six hours |
| `WATCHDOG_LABEL` | unset | only containers carrying this label |
| `WATCHDOG_STATE_DIR` | `/var/lib/unhealthy-watchdog` | where the history lives |

`WATCHDOG_LABEL` is worth setting on a busy host: it makes the set of guarded containers explicit rather than "everything that happens to have a healthcheck".

## A note on counting unhealthy containers

Not with `docker ps | grep`. The word `unhealthy` contains `healthy`, so a text match on the status column reports every unhealthy container as healthy, and a status line for a running container begins with `Up`. `docker ps --filter health=unhealthy` has neither problem, and it is what this uses.

## What it does not do

It does not tell you anything. A restart is written to the log and that is all; if you want to hear about it, point a dead man's switch at the host — [deadman-switch](https://github.com/heyvaldemar/deadman-switch) has a `container_healthy` check and reports over a channel that survives the machine.

It does not fix the crash. Three restarts in six hours and it stops precisely so that the fourth failure is still there to look at.

## Testing

`tests/e2e-watchdog.sh` builds real containers in one state each and checks the decision: unhealthy is restarted; healthy, starting, unchecked and stopped are not; the ceiling engages and holds; `--dry-run` changes nothing.

Writing it caught three defects before release, all of the same kind — something that silently did nothing while looking correct. The state file was being truncated on every run, so the restart history was always empty and the ceiling never engaged. A missing `flock` was reported as a lock somebody else held, so on a host without it the run announced a reason that was not true and exited successfully having done nothing. And `mapfile` is a bash 4 builtin, which the bash 3.2 macOS ships does not have — CI on Ubuntu would never have found that one.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
