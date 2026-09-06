# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-09-06

### Added

- **Restarts the one state docker will not.** `restart: unless-stopped` covers
  a container that exits and does nothing for one that stays up while the
  process inside it is gone, and docker does not restart an unhealthy container
  by itself either.
- **Four states it deliberately leaves alone**: healthy, `starting` (a long
  start period usually means a first boot that is still downloading, and
  restarting fights it), no healthcheck at all, and stopped — because a
  watchdog that overrules the operator is a worse problem than the one it was
  brought in for.
- **A ceiling, which is the point rather than a detail.** A container that
  crashes on load crashes again on restart, and a guard without a limit turns
  one outage into a loop that never lets anyone connect and buries the evidence
  under fresh logs. Past the ceiling it says so once and stops.
- **A lock that works where there is no `flock`**, using `mkdir`, with a stale
  lock older than an hour cleared rather than left to silence the watchdog
  forever.
- **Eight end-to-end scenarios against real containers**, most of them about
  what it refuses to touch.

### Notes on what the tests caught before release

- **The state file was being truncated on every run.** The line meant to create
  it if missing emptied it instead, so the restart history was always empty and
  the ceiling never engaged — the one safeguard, silently absent, with nothing
  in the output to suggest it.
- **A missing `flock` was reported as a held lock.** On a host without it the
  run announced that another run held the lock and exited successfully, having
  done nothing. The two cases now read differently.
- **`mapfile` is a bash 4 builtin** and this has to run under the 3.2 that
  macOS ships. CI on Ubuntu would never have found it.

[Unreleased]: https://github.com/heyvaldemar/unhealthy-watchdog/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/unhealthy-watchdog/releases/tag/v1.0.0
