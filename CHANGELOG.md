# Changelog

All notable changes to this repository are documented here.

## 1.1.0 - 2026-09-17

- Added a shared `flock` lock file (`$BASE_DIR/borgmatic.lock`) between the
  installer and the cron-triggered backup run, so the two can never execute
  concurrently, and overlapping backup runs can't stack. Requires updating
  the TrueNAS Cron Job command to the flock-wrapped form -- see README.
- Added `--check`: read-only verification of an existing install (Borg
  binary, wrapper, borgmatic, and config validation) with no downloads and
  no mutation. Safe to run at any time, including during a live backup.
- Added `--simulate-failure`: deliberately fails a real install partway
  through, immediately after the current venv/Borg binary are moved aside,
  to prove the automatic rollback mechanism actually restores them rather
  than relying on it having been reasoned about but never triggered.
- Added `--version` handling alongside the two new flags via a single
  argument-parsing pass.
- Refactored the post-install sanity checks into a shared `run_verification`
  function used by both a normal install and standalone `--check`.
- Documented in the script header why the interactive `borgmatic`/`borg`
  aliases are deliberately not flock-wrapped (a left-open `mount` session
  would otherwise silently block every subsequent cron run).
- `config.yaml.example`: added a commented-out optional block for
  `retries`/`retry_wait` and `checks`/`check_last`, matching settings used
  in the validated production configuration this installer is based on.

## 1.0.4 - 2026-09-18

- Validate an existing live `config.yaml` before committing a replacement
  installation.
- Automatically restore the previous venv and Borg binary when the live
  configuration is incompatible with the replacement borgmatic version.
- Document the credentials and configuration that must be kept off-host for
  disaster recovery.

## 1.0.3 - 2026-09-18

- Set generated `aliases.sh` to mode 0644 so `truenas_admin` can source it
  after a fresh root-run installation with the private umask.
- Set `borg-wrapper.sh` explicitly to mode 0755.

## 1.0.2 - 2026-09-18

- Pinned borgmatic 2.1.7 to match the existing working TrueNAS installation
  and the current upstream borgmatic release.

## 1.0.1 - 2026-09-18

- Fixed venv replacement so it is created directly at its final path. Python
  console scripts contain absolute interpreter paths and cannot be safely
  created under `venv-new` and then renamed.
- Added automatic rollback on installation errors, interrupts, and signals
  after replacement begins.

## 1.0.0 - 2026-09-18

- Added a TrueNAS SCALE-safe borgmatic installer.
- Pinned borgmatic, Borg, and virtualenv versions.
- Added SHA-256 verification for downloaded executables.
- Added private runtime and SSH directory permissions.
- Added download retries and prerequisite checks.
- Added safe replacement with one retained rollback generation.
- Added a whitelist-based Git ignore policy for use in the live dataset.
- Added a sanitized borgmatic configuration example and shell validation.
