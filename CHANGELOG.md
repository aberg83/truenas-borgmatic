# Changelog

All notable changes to this repository are documented here.

## Unreleased

- `config.yaml.example` adds `-o ServerAliveInterval=60 -o
  ServerAliveCountMax=5` to `ssh_command`, so idle connections aren't dropped
  during long server-side checks and a dead link fails the run in about 5
  minutes instead of hanging while holding the lock.
- `config.yaml.example` warns against the `data` check: with Borg 1.x it
  downloads and verifies every chunk in the repository regardless of
  `check_last`.
- `config.yaml.example` sets `compression: auto,zstd` (better ratio than the
  lz4 default, skipping incompressible data) and `lock_wait: 300`, so a
  short manual `borgmatic list` or `mount` no longer fails the nightly run
  on the repository lock.

## 1.3.2 - 2026-10-15

- `--check` (and the installer's final sanity check) now verifies that the
  passphrase file from `encryption_passcommand: cat ...` and the SSH key from
  `ssh_command: ssh -i ...` exist, aren't empty, and aren't readable by group
  or others, so a missing secret shows up before the nightly run fails.
- Added borgmatic 2.1.10 to `BORGMATIC_SKIP_VERSIONS`. Its release notes don't
  mention a fix for the 2.1.8+ files-cache regression; remove it once a
  release is tested with two consecutive fast `create --stats` runs.
- `config.yaml.example` enables `retries: 3` and `retry_wait: 60`, so a brief
  network or host outage is retried instead of failing the run.
- `config.yaml.example` explains borgmatic's default monthly repository and
  archives checks, what a full archives check costs on a large remote
  repository, and how `check_last` limits it.
- Removed the `borg` alias from `aliases.sh`. It ran the Borg wrapper
  without the repository, passphrase or SSH settings, so repository
  commands failed; use `borgmatic borg ...` instead. Re-run the installer to
  regenerate `aliases.sh`. `bin/borg-wrapper.sh` stays, since borgmatic uses
  it as `local_path`.
- Fixed the optional Post Init self-heal command for the aliases line. Init
  scripts run as root, so `~/.zshrc` pointed at `/root/.zshrc`; it now names
  `/home/truenas_admin/.zshrc`.
- Removed the passwordless sudo step from the installer's AFTER RUNNING
  notes and the README. The `borgmatic`/`borg` aliases prompt for the sudo
  password as usual; the cron job runs as root and never needed a grant.
  Later steps are renumbered.
- README: documented creating the passphrase file (generated for a new
  repository, or entered at a silent prompt for an existing one), creating
  the repository with `repo-create`, and exporting the repository key. The
  key export is added to the disaster-recovery list.

## Unarchived - 2026-10-15

- Back in use on the TrueNAS system; removed the archived notice from the
  README. Pins are unchanged at v1.3.1 (borgmatic 2.1.7, Borg 1.4.5).
  borgmatic 2.1.10 is out but its release notes don't mention the
  runtime-directory change behind the 2.1.8+ files-cache regression.
- README: documented creating the Borg host SSH key and registering it,
  with BorgBase (web UI) and rsync.net or self-hosted (`authorized_keys`
  forced command) as examples.
- Docs and comments no longer assume rsync.net: placeholders are now
  `BORG_USER`/`BORG_HOST`, the example repository label is `offsite`, and
  `remote_path` is explained as host-specific.

## Archived - 2026-10-07

- Setup removed from the TrueNAS system; repository archived. v1.3.1 is the
  last tested release. No further updates.

## 1.3.1 - 2026-09-28

- Reverted borgmatic 2.1.9 -> 2.1.7, restoring the exact `requirements.txt`
  dependency set from 1.2.0. borgmatic 2.1.8 started creating its runtime
  directory under a new random name every run. The ZFS hook mounts snapshots
  inside it, and Borg keys its files cache on the full path, so every file
  was treated as new and re-read on each backup (a 3-minute nightly run took
  3 hours). Upstream has no fix as of 2.1.10.dev0.
- Added `BORGMATIC_SKIP_VERSIONS` (currently 2.1.8 and 2.1.9). The monthly
  version check reports those releases as skipped instead of opening an
  update issue for them, and the installer refuses to install one.

## 1.3.0 - 2026-09-27

- The installer refuses to run, before changing anything, when the system
  `python3` isn't the version `requirements.txt` was resolved for (new
  `REQUIREMENTS_PYTHON` setting, currently 3.11). `--check` warns about the
  mismatch. Previously a TrueNAS Python bump would only surface as a failed
  install and rollback.
- Added a monthly **Pinned version check** workflow and
  `.github/scripts/check-pinned-versions.sh`: compares the borgmatic, Borg
  (within the pinned series) and virtualenv pins against upstream, and opens,
  refreshes or closes a single tracking issue. It never changes pins.
- CI reads the Python version from `REQUIREMENTS_PYTHON` instead of
  hard-coding it, and shellchecks the new script.
- `config.yaml.example` documents why borgmatic's `spot` check is not used
  with ZFS property-based dataset discovery.
- Bumped borgmatic 2.1.7 -> 2.1.9 and regenerated `requirements.txt` (adds
  `psutil`, a new borgmatic dependency, installed from a binary wheel). The
  only breaking changes in 2.1.8/2.1.9 affect Borg 2. 2.1.9 deprecates
  boolean `statistics: true/false`; existing configs still validate, with a
  warning.

## 1.2.0 - 2026-09-27

- Install borgmatic and its full dependency tree from a new hash-locked
  `requirements.txt` (`--require-hashes --only-binary :all:`) instead of an
  unpinned `pip install borgmatic==X`. The installer refuses to run if the
  file's borgmatic pin disagrees with `BORGMATIC_VERSION`.
- Keep virtualenv's seed-wheel cache in the private tmp directory (removed
  after the build), disable virtualenv's periodic seed update, and run pip
  with `--isolated --no-cache-dir`, so nothing is written under `/root`.
- Close the interrupt window between flagging a component as replaced and
  moving its original aside: rollback now records whether each component
  existed and restores idempotently from whatever point was reached. A
  second Ctrl-C can no longer abort a rollback halfway through.
- Added `--help`; combining `--check` and `--simulate-failure` is now an
  error instead of silently using the last one.
- `config.yaml.example` pins SSH host keys in `ssh/known_hosts` on the
  dataset with `BatchMode` and `StrictHostKeyChecking`; verification fails
  if a configured `UserKnownHostsFile` is missing or empty.
- Documented that the passwordless sudo grants are equivalent to
  passwordless root.
- CI installs `requirements.txt` on Python 3.11 exactly as the installer
  does and checks its borgmatic pin matches the script.

## 1.1.3 - 2026-09-27

- Fetch and verify both downloads (virtualenv bootstrap and Borg binary)
  before moving any installed component aside. Previously a Borg download or
  checksum failure left the new `virtualenv.pyz` swapped in without rollback.
- Remove partial `.new` downloads on any failed exit.
- `--simulate-failure` now refuses to run without an existing install to
  restore, instead of installing and then rolling back to nothing.
- `--check` warns when the installed borgmatic version or Borg binary
  differs from the versions pinned in the script.
- Passphrase-file instructions no longer put the passphrase in shell history
  or a process listing, or leave the file briefly world-readable.
- CI validates `config.yaml.example` against the pinned borgmatic schema.
- README: updated rollback and `--simulate-failure` descriptions for all four
  components; review updates against `origin/main` before merging rather
  than `HEAD~1` after pulling; generic tag examples.

## 1.1.2 - 2026-09-19

- Extended automatic rollback to include the downloaded `virtualenv.pyz`
  bootstrap and generated Borg wrapper, keeping the full installed generation
  consistent after a failed upgrade.
- Moved `--simulate-failure` until after the replacement wrapper is written,
  so the rollback test now exercises the virtualenv bootstrap, venv, Borg
  binary, and wrapper together.
- Made deliberate `--simulate-failure` rollback output clearly identify the
  failure as intentional rather than reporting it as an unexpected install
  failure.
- Added CI validation that `config.yaml.example` is syntactically valid YAML.

## 1.1.1 - 2026-09-18

- Made `--check` non-mutating with respect to persistent install state by
  entering check mode before command prerequisites, directory creation,
  permission changes, or lock creation.
- Treat a missing or non-executable Borg wrapper as a failed verification
  instead of a warning.
- Moved `--simulate-failure` until after both replacement components are
  installed, so it exercises restoration of both the venv and Borg binary.
- Corrected the 1.1.0 changelog date.

## 1.1.0 - 2026-09-18

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
