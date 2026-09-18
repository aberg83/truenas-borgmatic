# Changelog

All notable changes to this repository are documented here.

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
