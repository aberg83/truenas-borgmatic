#!/bin/sh
#
# setup-borgmatic.sh
#
# Installer/upgrader for a pinned borgmatic + Borg environment on TrueNAS
# SCALE, without modifying the appliance-managed operating system.
#
# WHY THIS SCRIPT EXISTS
# -----------------------
# TrueNAS SCALE disables apt/dpkg outright, and Debian 12's system Python is
# "externally managed" (PEP 668), so neither `python3 -m venv` nor a normal
# `pip install borgbackup` work out of the box on this host:
#   - stdlib venv needs ensurepip, which needs the (apt-blocked) python3-venv
#     package.
#   - borgbackup has no PyPI wheels; it builds from source, which needs a
#     compiler, pkg-config, and dev headers (openssl/lz4/zstd/xxhash/acl) --
#     none of which are installable here.
#   - the PyInstaller-built standalone `borg` binary unpacks bundled shared
#     libraries into $TMPDIR at runtime and mmaps them PROT_EXEC. TrueNAS
#     mounts /tmp as tmpfs with noexec, so it fails unless TMPDIR points
#     somewhere on a normal (exec-enabled) ZFS dataset.
#   - `sudo` strips TMPDIR by default (env_reset), so `sudo TMPDIR=... borg`
#     doesn't work interactively either -- TMPDIR has to be set *inside* a
#     script that then execs borg, not passed across the sudo boundary.
#
# This script works around all of these by using the `virtualenv` zipapp
# (bundles its own pip, ignores PEP 668), grabbing Borg's official static
# binary instead of building it, pinning TMPDIR to a directory on the same
# dataset, and wrapping raw `borg` invocations in a small script that sets
# TMPDIR itself before exec'ing the binary.
#
# USAGE
# ------
#   sudo sh setup-borgmatic.sh                  Install or upgrade.
#   sudo sh setup-borgmatic.sh --check           Verify an existing install
#                                                 only -- no downloads, no
#                                                 replacement, and no persistent
#                                                 install changes. Borg uses the
#                                                 private tmp directory briefly.
#                                                 Safe to run any time,
#                                                 including while a backup is
#                                                 in progress. Use this right
#                                                 after a TrueNAS update or
#                                                 reboot, before trusting the
#                                                 nightly cron job.
#   sudo sh setup-borgmatic.sh --simulate-failure
#                                                 Runs a REAL install, but
#                                                 deliberately fails partway
#                                                 through -- after replacement
#                                                 venv and Borg binaries are
#                                                 installed --
#                                                 to prove the automatic
#                                                 rollback actually restores
#                                                 them. Requires an existing
#                                                 working install. Ends with
#                                                 your previous install back
#                                                 in place, confirmed working.
#   sudo sh setup-borgmatic.sh --version         Print this script's version.
#   sh setup-borgmatic.sh --help                 Print usage.
#
# requirements.txt (next to this script) hash-locks borgmatic and every one of
# its Python dependencies; the installer refuses to run if its borgmatic pin
# disagrees with BORGMATIC_VERSION below.
#
# WHEN TO RUN A REAL INSTALL/UPGRADE
# ------------------------------------
#   - First-time setup.
#   - After a major TrueNAS version jump, if `borgmatic --version` (or the
#     nightly cron job) starts failing -- e.g. a Python ABI mismatch after
#     an OS Python version bump, or a glibc floor bump that the pinned Borg
#     binary no longer meets. Bump BORG_VERSION below if you need a newer
#     Borg release to match a newer glibc.
#   - Deliberately bumping BORGMATIC_VERSION or BORG_VERSION. Change one
#     component at a time; commit, deploy, run a real backup, and test a
#     restore before tagging.
#
# LOCKING
# --------
# A single lock file ($BASE_DIR/borgmatic.lock) is shared between this
# installer and the actual cron-triggered backup run, so the two can never
# execute at the same time, and two overlapping backup runs (if one ever
# takes longer than your schedule interval) can't stack either. This
# requires your TrueNAS Cron Job command to be flock-wrapped -- see step 4
# below. --check does NOT take this lock (it makes no persistent install
# changes and is safe to run concurrently with a real backup). The interactive
# `borgmatic`/`borg`
# aliases are deliberately NOT flock-wrapped: a `borgmatic mount` session
# left open would otherwise silently block every subsequent cron run for as
# long as it stayed mounted, which is a worse failure mode than the rare
# overlap this lock is meant to catch. Manual, supervised use is lower risk
# than an unattended cron collision.
#
# BEFORE RUNNING
# ---------------
#   1. Create the dataset via the TrueNAS GUI first (Datasets -> your pool ->
#      Add Dataset). Do NOT create it with `zfs create` at the CLI -- GUI-
#      created datasets get TrueNAS's expected ACL/permission defaults;
#      CLI-created ones can fight the permissions UI later.
#        Name: apps/borgmatic  (adjust BASE_DIR below if yours differs)
#        Type: Filesystem
#        Atime: Off
#   2. Run this script with sudo: `sudo sh setup-borgmatic.sh`
#
# AFTER RUNNING -- manual steps this script does NOT do
# --------------------------------------------------------
#   1. Write $BASE_DIR/config.yaml. See config.yaml.example for the full
#      annotated template. Minimum settings to match this install:
#
#        local_path: $BASE_DIR/bin/borg-wrapper.sh   # NOT the raw borg binary
#                                             # -- borgmatic doesn't reliably
#                                             # pass TMPDIR through to the
#                                             # borg subprocess for every
#                                             # action (works for create/
#                                             # list, but NOT for umount,
#                                             # observed directly on this
#                                             # box). The wrapper guarantees
#                                             # TMPDIR is set for every
#                                             # action, not just the ones
#                                             # tested so far.
#        remote_path: borgXX                 # match your rsync.net-side
#                                             # pinned Borg version, e.g.
#                                             # borg14 for Borg 1.4.x
#        temporary_directory: $BASE_DIR/tmp
#        user_runtime_directory: $BASE_DIR/tmp
#        borg_base_directory: $BASE_DIR      # covers cache/config/security
#                                             # dirs -- keeps them off /root
#        ssh_command: ssh -i $BASE_DIR/ssh/id_ed25519 -o BatchMode=yes
#            -o StrictHostKeyChecking=yes
#            -o UserKnownHostsFile=$BASE_DIR/ssh/known_hosts
#                                             # (one line) -- host keys live
#                                             # on the dataset, not in /root,
#                                             # and an unknown or changed key
#                                             # fails fast instead of hanging
#                                             # the cron job on a prompt
#        encryption_passcommand: cat $BASE_DIR/passphrase   # NOT a plaintext
#                                             # encryption_passphrase: line --
#                                             # config.yaml gets backed up
#                                             # into the repo it unlocks
#        zfs: {}
#        repositories:
#            - path: ssh://youruser@yourhost.rsync.net/./yourrepo
#              label: rsync.net
#        keep_daily: 30
#        keep_weekly: 52
#        keep_monthly: 24
#        keep_yearly: 5
#        healthchecks:
#            ping_url: https://hc-ping.com/your-uuid
#            send_logs: true
#        monitoring_verbosity: 1
#
#   2. Passphrase file (if using encryption_passcommand as above). Type the
#      passphrase at the silent prompt, so it never lands in shell history or
#      a process listing, and the file is never briefly world-readable:
#        sudo sh -c 'umask 077; stty -echo; IFS= read -r p; stty echo; printf %s "$p" > BASE_DIR/passphrase'
#
#   3. rsync.net authorized_keys needs a forced command restricted to this
#      repo, using the versioned remote binary name (borg14, borg15, etc. --
#      whatever `remote_path` above is set to), e.g.:
#        command="borg14 serve --restrict-to-repository /home/XXXXX/yourrepo",restrict ssh-ed25519 AAAA...
#      A bare "borg serve" (unversioned) will fail on providers that pin
#      multiple Borg versions -- match remote_path exactly.
#
#      Pin the server's host key on the dataset (matches the ssh_command
#      above). Fetch it, compare the fingerprint against the one your provider
#      publishes, and only then install it:
#        sudo ssh-keyscan -t ed25519 yourhost.rsync.net > /tmp/known_hosts.new
#        ssh-keygen -lf /tmp/known_hosts.new
#        sudo install -m 600 /tmp/known_hosts.new BASE_DIR/ssh/known_hosts
#      If root has already connected and trusted this host, copy that entry
#      instead:
#        sudo sh -c 'umask 077; ssh-keygen -F yourhost.rsync.net -f /root/.ssh/known_hosts | grep -v "^#" > BASE_DIR/ssh/known_hosts'
#      The installer's verification (and --check) fails if config.yaml names a
#      UserKnownHostsFile that is missing or empty.
#
#   4. TrueNAS Cron Job (System Settings -> Advanced -> Cron Jobs):
#        User: root
#        Command: flock -n $LOCK_FILE $BASE_DIR/venv/bin/borgmatic -c $BASE_DIR/config.yaml
#        Hide Standard Output: checked
#        Hide Standard Error: unchecked (catches failures before a
#          healthchecks ping would ever fire)
#      The flock -n wrapper is new -- if you're upgrading from a version of
#      this installer that predates locking, update the existing Cron Job's
#      command to add it. -n means non-blocking: if a backup or install is
#      already using the lock, this run is skipped rather than queued --
#      healthchecks' dead-man's-switch will flag a skipped run the same way
#      it flags any other missed one.
#
#   5. TrueNAS-managed passwordless sudo (Credentials -> Users ->
#      truenas_admin -> Allowed Sudo Commands (No Password) -- do NOT use a
#      manual /etc/sudoers.d file, TrueNAS's own GUI-managed grant silently
#      overrides it):
#        $BASE_DIR/venv/bin/borgmatic *
#        $BASE_DIR/bin/borg-wrapper.sh *
#      SECURITY: these two grants are equivalent to passwordless root for
#      anything running as truenas_admin. `borgmatic -c <any file>` runs that
#      file's command hooks as root, and `borg --rsh '<command>'` runs an
#      arbitrary command as root. The `*` cannot be narrowed to prevent this.
#      Only add them if that is acceptable for this account; otherwise skip
#      this step and type the sudo password when using the aliases (the
#      cron job runs as root and doesn't need either grant).
#
#   6. Source $BASE_DIR/aliases.sh from your shell's rc file (this script
#      creates aliases.sh but can't safely edit your rc file for you):
#        echo 'source BASE_DIR/aliases.sh' >> ~/.zshrc   # or ~/.bashrc
#      Optionally add a TrueNAS Init/Shutdown Script (Post Init, type
#      Command) to self-heal that line if a future update wipes ~/.zshrc:
#        grep -qxF 'source BASE_DIR/aliases.sh' ~/.zshrc || echo 'source BASE_DIR/aliases.sh' >> ~/.zshrc
#
#   7. Test end-to-end before trusting the cron job -- a dry run is NOT a
#      valid test here: the zfs hook skips taking an actual snapshot during
#      --dry-run, and with no static source_directories (property-based
#      discovery only), that leaves borg with zero paths and a guaranteed
#      false failure. Go straight to a real create:
#        borgmatic create --list --stats
#        borgmatic list
#        borgmatic extract --archive latest --path /some/test/path --destination /tmp/restore-test
#
#   8. Mounting archives to browse/copy files out (alternative to extract):
#        sudo mkdir -p BASE_DIR/restore-mount
#        borgmatic mount --mount-point BASE_DIR/restore-mount   # mounts ALL
#                                             # archives, one subdir each
#      Only the mounting user (root, via sudo) can access it -- browse with
#      `sudo -s` (a root shell) rather than `sudo cd ...`, since cd is a shell
#      builtin and doesn't work prefixed with sudo the way other commands do.
#      Unmount with:
#        borgmatic umount --mount-point BASE_DIR/restore-mount
#      If that hangs/errors, a plain `sudo umount BASE_DIR/restore-mount` (or
#      `sudo fusermount -u BASE_DIR/restore-mount`) always works as a fallback
#      -- it's a normal FUSE mount at the kernel level, so standard unmount
#      tools apply regardless of what borgmatic itself is doing.
#      Don't leave a mount open indefinitely -- see LOCKING above for why.
#
#   9. Prove the rollback mechanism actually works, once, deliberately:
#        sudo sh setup-borgmatic.sh --simulate-failure
#      then confirm your install is intact:
#        sudo sh setup-borgmatic.sh --check
#
set -eu
umask 077

# ---- Configuration -- adjust these if your paths/versions differ ----------
SCRIPT_VERSION="1.3.0"
BASE_DIR="/mnt/apps/borgmatic"
BORGMATIC_VERSION="2.1.7"
BORG_VERSION="1.4.5"
BORG_ASSET="borg-linux-glibc231-x86_64"
BORG_SHA256="c8457f70660064d0f45b38283ab4cc65b342970012013201d3aec713a75898fb"
BORG_URL="https://github.com/borgbackup/borg/releases/download/${BORG_VERSION}/${BORG_ASSET}"
VIRTUALENV_VERSION="21.7.4"
VIRTUALENV_URL="https://github.com/pypa/virtualenv/releases/download/${VIRTUALENV_VERSION}/virtualenv.pyz"
# The system Python minor version requirements.txt was resolved for. The
# installer refuses to run on any other; regenerate requirements.txt on the
# new Python and update this together with it.
REQUIREMENTS_PYTHON="3.11"
VIRTUALENV_SHA256="2dfdb6785b762b8a7a7a31d413c16516aa785552d05f61435b072fde1cb340cc"
LOCK_FILE="$BASE_DIR/borgmatic.lock"
# -----------------------------------------------------------------------------

usage() {
    echo "Usage: sudo sh $0 [--check | --simulate-failure | --version | --help]"
    echo ""
    echo "  (no option)         Install or upgrade."
    echo "  --check             Verify an existing install; changes nothing."
    echo "  --simulate-failure  Real install that deliberately fails, to prove rollback."
    echo "  --version           Print this script's version."
    echo "  --help              Print this help."
}

ACTION="install"
set_action() {
    if [ "$ACTION" != "install" ] && [ "$ACTION" != "$1" ]; then
        echo "ERROR: --$ACTION and --$1 cannot be combined." >&2
        usage >&2
        exit 1
    fi
    ACTION="$1"
}
for arg in "$@"; do
    case "$arg" in
        --version)
            echo "setup-borgmatic.sh $SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --check)
            set_action check
            ;;
        --simulate-failure)
            set_action simulate-failure
            ;;
        *)
            echo "ERROR: Unknown argument: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (use: sudo sh $0)" >&2
    exit 1
fi

if [ ! -d "$BASE_DIR" ]; then
    echo "ERROR: $BASE_DIR does not exist." >&2
    echo "Create the dataset via the TrueNAS GUI first -- see the header of this script." >&2
    exit 1
fi

echo "==> setup-borgmatic.sh $SCRIPT_VERSION ($ACTION)"
echo "==> Using base directory: $BASE_DIR"

verify_sha256() {
    expected="$1"
    file="$2"
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: SHA-256 mismatch for $file" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

download() {
    url="$1"
    destination="$2"
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
        -o "$destination" "$url"
}

# Shared by a normal install's final sanity check and standalone --check
# mode. Never downloads, replaces, or changes persistent install files.
run_verification() {
    echo "==> Verifying Borg binary runs (using TMPDIR=$BASE_DIR/tmp)"
    if TMPDIR="$BASE_DIR/tmp" "$BASE_DIR/bin/borg" --version; then
        echo "    Borg OK."
    else
        echo "    Borg failed to run. Check glibc compatibility (asset: $BORG_ASSET) and TMPDIR permissions." >&2
        return 1
    fi

    if [ -x "$BASE_DIR/bin/borg-wrapper.sh" ]; then
        echo "==> Verifying borg-wrapper.sh"
        if TMPDIR="$BASE_DIR/tmp" "$BASE_DIR/bin/borg-wrapper.sh" --version >/dev/null; then
            echo "    Wrapper OK."
        else
            echo "    Wrapper failed to run." >&2
            return 1
        fi
    else
        echo "ERROR: $BASE_DIR/bin/borg-wrapper.sh is missing or not executable." >&2
        return 1
    fi

    echo "==> Verifying borgmatic runs"
    if "$BASE_DIR/venv/bin/borgmatic" --version; then
        echo "    borgmatic OK."
    else
        echo "    borgmatic failed to run." >&2
        return 1
    fi

    if [ -f "$BASE_DIR/config.yaml" ]; then
        echo "==> Validating existing borgmatic configuration"
        if "$BASE_DIR/venv/bin/borgmatic" config validate \
            --config "$BASE_DIR/config.yaml"; then
            echo "    Configuration OK."
        else
            echo "    Configuration validation failed." >&2
            return 1
        fi

        known_hosts_file="$(sed -n 's/.*UserKnownHostsFile=\([^ "'"'"']*\).*/\1/p' \
            "$BASE_DIR/config.yaml" | head -n 1)"
        if [ -n "$known_hosts_file" ]; then
            echo "==> Verifying SSH known_hosts file"
            if [ -s "$known_hosts_file" ]; then
                echo "    $known_hosts_file OK."
            else
                echo "    config.yaml uses UserKnownHostsFile=$known_hosts_file, but it is missing or empty." >&2
                echo "    See step 3 of AFTER RUNNING in this script's header." >&2
                return 1
            fi
        fi
    else
        echo "NOTE: $BASE_DIR/config.yaml not found -- skipping config validation."
    fi
}

# Prints the system python3's major.minor version, e.g. "3.11".
system_python_version() {
    python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'
}

# Informational only: flags an installed generation that differs from the
# versions pinned in this copy of the script (e.g. after a `git pull` that
# hasn't been installed yet). Never fails the check.
report_version_drift() {
    installed_borgmatic="$("$BASE_DIR/venv/bin/borgmatic" --version 2>/dev/null || true)"
    if [ "$installed_borgmatic" != "$BORGMATIC_VERSION" ]; then
        echo "WARNING: installed borgmatic is '$installed_borgmatic'; this script pins $BORGMATIC_VERSION."
        echo "         Run the installer without --check to bring them in line."
    fi
    system_python="$(system_python_version || true)"
    if [ "$system_python" != "$REQUIREMENTS_PYTHON" ]; then
        echo "WARNING: system python3 is '$system_python'; requirements.txt is resolved for $REQUIREMENTS_PYTHON."
        echo "         Regenerate requirements.txt on this Python before the next install."
    fi
    installed_borg_sha256="$(sha256sum "$BASE_DIR/bin/borg" | awk '{print $1}')"
    if [ "$installed_borg_sha256" != "$BORG_SHA256" ]; then
        echo "WARNING: installed Borg binary does not match the pinned $BORG_VERSION ($BORG_ASSET) checksum."
        echo "         Run the installer without --check to bring them in line."
    fi
}

# ---- --check mode: no persistent changes and no lock needed ----------------
if [ "$ACTION" = "check" ]; then
    if [ ! -x "$BASE_DIR/bin/borg" ] || [ ! -x "$BASE_DIR/venv/bin/borgmatic" ]; then
        echo "ERROR: No existing installation found at $BASE_DIR to check." >&2
        echo "Run this script without --check to install." >&2
        exit 1
    fi
    if run_verification; then
        report_version_drift
        echo ""
        echo "==> All checks passed."
        exit 0
    else
        echo ""
        echo "==> One or more checks failed. See above." >&2
        exit 1
    fi
fi

if [ "$ACTION" = "simulate-failure" ]; then
    if [ ! -x "$BASE_DIR/bin/borg" ] || [ ! -x "$BASE_DIR/venv/bin/borgmatic" ]; then
        echo "ERROR: --simulate-failure needs an existing installation to roll back to." >&2
        echo "Run this script without arguments to install first." >&2
        exit 1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"
if [ ! -f "$REQUIREMENTS_FILE" ]; then
    echo "ERROR: $REQUIREMENTS_FILE not found; it must sit next to this script." >&2
    exit 1
fi
if ! awk -v pin="borgmatic==$BORGMATIC_VERSION" '$1 == pin { found = 1 } END { exit !found }' \
    "$REQUIREMENTS_FILE"; then
    echo "ERROR: $REQUIREMENTS_FILE does not pin borgmatic==$BORGMATIC_VERSION." >&2
    echo "Regenerate it -- see \"Updating pinned versions\" in README.md." >&2
    exit 1
fi

for required_command in curl python3 sha256sum awk grep flock; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $required_command" >&2
        exit 1
    fi
done

SYSTEM_PYTHON="$(system_python_version)"
if [ "$SYSTEM_PYTHON" != "$REQUIREMENTS_PYTHON" ]; then
    echo "ERROR: system python3 is $SYSTEM_PYTHON, but requirements.txt is resolved for $REQUIREMENTS_PYTHON." >&2
    echo "Likely a TrueNAS update changed the OS Python. Regenerate requirements.txt on" >&2
    echo "Python $SYSTEM_PYTHON and update REQUIREMENTS_PYTHON -- see \"Updating pinned" >&2
    echo "versions\" in README.md. Nothing has been changed." >&2
    exit 1
fi

# ---- install / simulate-failure: acquire the shared lock -------------------
# Shared with the cron-invoked backup itself (see LOCKING above) so the
# installer and a real backup run can never execute at the same time.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: Could not acquire $LOCK_FILE." >&2
    echo "A backup or another instance of this installer appears to be running." >&2
    echo "Wait for it to finish, then try again." >&2
    exit 1
fi

mkdir -p "$BASE_DIR/bin" "$BASE_DIR/tmp" "$BASE_DIR/ssh"
chmod 700 "$BASE_DIR/ssh" "$BASE_DIR/tmp"

# Put one component back the way it was before this run, whichever point the
# replacement reached. Each *_REPLACED flag is set before its component's
# original is moved aside, so an interrupt can land between the flag and the
# move: the original is then still in place with no .previous, and the
# *_EXISTED flag (recorded first) tells that apart from a first install.
restore_component() {
    current="$1"
    previous="$2"
    existed="$3"
    if [ -e "$previous" ]; then
        rm -rf "$current"
        mv "$previous" "$current"
    elif [ "$existed" -eq 0 ]; then
        rm -rf "$current"
    fi
}

rollback_install() {
    if [ "$ACTION" = "simulate-failure" ]; then
        echo "==> Intentional simulated failure; restoring previous installation." >&2
    else
        echo "ERROR: Installation failed; restoring previous installation." >&2
    fi
    if [ "$VENV_REPLACED" -eq 1 ]; then
        restore_component "$BASE_DIR/venv" "$BASE_DIR/venv-previous" "$VENV_EXISTED"
    fi
    if [ "$BORG_REPLACED" -eq 1 ]; then
        restore_component "$BASE_DIR/bin/borg" "$BASE_DIR/bin/borg.previous" "$BORG_EXISTED"
    fi
    if [ "$WRAPPER_REPLACED" -eq 1 ]; then
        restore_component "$BASE_DIR/bin/borg-wrapper.sh" \
            "$BASE_DIR/bin/borg-wrapper.sh.previous" "$WRAPPER_EXISTED"
    fi
    if [ "$VIRTUALENV_REPLACED" -eq 1 ]; then
        restore_component "$BASE_DIR/virtualenv.pyz" \
            "$BASE_DIR/virtualenv.pyz.previous" "$VIRTUALENV_EXISTED"
    fi
    ROLLBACK_ACTIVE=0
    echo "==> Rollback complete. Run '$0 --check' to confirm the restored install works."
}

handle_exit() {
    exit_status="$?"
    trap - EXIT
    # A second Ctrl-C must not abort a rollback halfway through.
    trap '' HUP INT TERM
    if [ "$ROLLBACK_ACTIVE" -eq 1 ]; then
        rollback_install
    fi
    rm -f "$BASE_DIR/virtualenv.pyz.new" "$BASE_DIR/bin/borg.new"
    rm -rf "$VIRTUALENV_OVERRIDE_APP_DATA"
    exit "$exit_status"
}

# virtualenv's seed-wheel cache would otherwise land in /root/.cache on the OS
# image (even `--version` creates it, so --app-data alone isn't enough). Point
# it at the private tmp directory and remove it once the venv is built. pip's
# own cache is disabled with --no-cache-dir below.
VIRTUALENV_OVERRIDE_APP_DATA="$BASE_DIR/tmp/virtualenv-app-data"
export VIRTUALENV_OVERRIDE_APP_DATA
rm -rf "$VIRTUALENV_OVERRIDE_APP_DATA"

ROLLBACK_ACTIVE=0
VENV_REPLACED=0
BORG_REPLACED=0
WRAPPER_REPLACED=0
VIRTUALENV_REPLACED=0
VENV_EXISTED=0
BORG_EXISTED=0
WRAPPER_EXISTED=0
VIRTUALENV_EXISTED=0
trap handle_exit EXIT
trap 'exit 1' HUP INT TERM

# Both downloads are fetched and verified before anything installed is moved
# aside, so a network or checksum failure leaves the current generation
# completely untouched.

# ---- 1. virtualenv zipapp (bypasses ensurepip + PEP 668) -------------------
echo "==> Fetching virtualenv.pyz"
download "$VIRTUALENV_URL" "$BASE_DIR/virtualenv.pyz.new"
verify_sha256 "$VIRTUALENV_SHA256" "$BASE_DIR/virtualenv.pyz.new"
if ! python3 "$BASE_DIR/virtualenv.pyz.new" --version | grep -F "virtualenv $VIRTUALENV_VERSION" >/dev/null; then
    echo "ERROR: Downloaded virtualenv.pyz is not version $VIRTUALENV_VERSION." >&2
    exit 1
fi

# ---- 2. Borg standalone binary (avoids building borgbackup from source) ---
echo "==> Fetching Borg $BORG_VERSION standalone binary ($BORG_ASSET)"
download "$BORG_URL" "$BASE_DIR/bin/borg.new"
verify_sha256 "$BORG_SHA256" "$BASE_DIR/bin/borg.new"
chmod 755 "$BASE_DIR/bin/borg.new"
if ! TMPDIR="$BASE_DIR/tmp" "$BASE_DIR/bin/borg.new" --version; then
    echo "ERROR: Replacement Borg binary failed to run." >&2
    exit 1
fi

# ---- 3. exec-enabled TMPDIR (works around noexec /tmp) --------------------
# This installation only runs Borg as root, so a private directory is enough.
chmod 700 "$BASE_DIR/tmp"

# ---- 4. Install verified replacements --------------------------------------
# All downloads are verified before this point. Python console scripts contain
# absolute interpreter paths, so the venv must be created directly at its final
# path; a completed venv cannot safely be renamed from venv-new to venv. Keep
# one previous working generation and restore it automatically on any failure.
echo "==> Installing verified replacements"
ROLLBACK_ACTIVE=1
rm -f "$BASE_DIR/virtualenv.pyz.previous"
if [ -f "$BASE_DIR/virtualenv.pyz" ]; then
    VIRTUALENV_EXISTED=1
fi
VIRTUALENV_REPLACED=1
if [ "$VIRTUALENV_EXISTED" -eq 1 ]; then
    mv "$BASE_DIR/virtualenv.pyz" "$BASE_DIR/virtualenv.pyz.previous"
fi
mv "$BASE_DIR/virtualenv.pyz.new" "$BASE_DIR/virtualenv.pyz"

rm -rf "$BASE_DIR/venv-new"
rm -rf "$BASE_DIR/venv-previous"
if [ -d "$BASE_DIR/venv" ]; then
    VENV_EXISTED=1
fi
VENV_REPLACED=1
if [ "$VENV_EXISTED" -eq 1 ]; then
    mv "$BASE_DIR/venv" "$BASE_DIR/venv-previous"
fi

echo "==> Building replacement venv at $BASE_DIR/venv"
python3 "$BASE_DIR/virtualenv.pyz" --no-periodic-update "$BASE_DIR/venv"
rm -rf "$VIRTUALENV_OVERRIDE_APP_DATA"

echo "==> Installing hash-locked borgmatic $BORGMATIC_VERSION into the venv (wheels only)"
"$BASE_DIR/venv/bin/pip" --isolated --no-cache-dir --disable-pip-version-check \
    install --require-hashes --only-binary :all: -r "$REQUIREMENTS_FILE"
"$BASE_DIR/venv/bin/borgmatic" --version

rm -f "$BASE_DIR/bin/borg.previous"
if [ -f "$BASE_DIR/bin/borg" ]; then
    BORG_EXISTED=1
fi
BORG_REPLACED=1
if [ "$BORG_EXISTED" -eq 1 ]; then
    mv "$BASE_DIR/bin/borg" "$BASE_DIR/bin/borg.previous"
fi
mv "$BASE_DIR/bin/borg.new" "$BASE_DIR/bin/borg"

# ---- 5. Wrapper script for `borg` invocations ------------------------------
# This wrapper is used TWO ways, both load-bearing:
#   (a) as the `borg` shell alias, for standalone interactive commands -- a
#       bare `borg` run directly from a shell never goes through borgmatic,
#       so nothing sets TMPDIR for it, and `sudo TMPDIR=... borg` doesn't
#       work either since sudo's env_reset policy strips TMPDIR by default.
#   (b) as `local_path` in config.yaml -- borgmatic does NOT reliably pass
#       TMPDIR through to the borg subprocess for every action. It works for
#       create/list, but NOT for umount (observed directly on this box).
#       Pointing local_path at this wrapper instead of the raw binary
#       guarantees TMPDIR is set no matter which borgmatic action invokes it.
# Both cases are solved the same way: set TMPDIR from inside a script that
# then execs the real binary, rather than trying to pass it in from outside.
echo "==> Writing borg-wrapper.sh"
rm -f "$BASE_DIR/bin/borg-wrapper.sh.previous"
if [ -f "$BASE_DIR/bin/borg-wrapper.sh" ]; then
    WRAPPER_EXISTED=1
fi
WRAPPER_REPLACED=1
if [ "$WRAPPER_EXISTED" -eq 1 ]; then
    mv "$BASE_DIR/bin/borg-wrapper.sh" "$BASE_DIR/bin/borg-wrapper.sh.previous"
fi
cat > "$BASE_DIR/bin/borg-wrapper.sh" <<WRAPPER_EOF
#!/bin/sh
export TMPDIR=$BASE_DIR/tmp
exec $BASE_DIR/bin/borg "\$@"
WRAPPER_EOF
chmod 755 "$BASE_DIR/bin/borg-wrapper.sh"

if [ "$ACTION" = "simulate-failure" ]; then
    echo ""
    echo "==> --simulate-failure: replacement virtualenv bootstrap, venv, Borg binary,"
    echo "    and Borg wrapper are now installed."
    echo "    Deliberately failing to prove all previous components are restored."
    exit 1
fi

# ---- 6. Shell aliases (survive on the dataset, not the OS image) ----------
# Deliberately NOT flock-wrapped -- see LOCKING above.
echo "==> Writing aliases.sh"
cat > "$BASE_DIR/aliases.sh" <<ALIASES_EOF
alias borgmatic='sudo $BASE_DIR/venv/bin/borgmatic -c $BASE_DIR/config.yaml'
alias borg='sudo $BASE_DIR/bin/borg-wrapper.sh'
ALIASES_EOF
chmod 644 "$BASE_DIR/aliases.sh"

# ---- 7. Sanity checks -------------------------------------------------------
if ! run_verification; then
    exit 1
fi

if [ ! -f "$BASE_DIR/config.yaml" ]; then
    echo "      See the AFTER RUNNING section in this script's header comments"
    echo "      for the required config.yaml settings."
fi

ROLLBACK_ACTIVE=0
trap - EXIT HUP INT TERM

cat <<EOF

==============================================================================
Done. venv, Borg binary, wrapper script, and aliases.sh are all in place.

One previous installation generation is retained when earlier components
existed: venv-previous, bin/borg.previous, bin/borg-wrapper.sh.previous, and
virtualenv.pyz.previous.

Still to do manually -- see the "AFTER RUNNING" section in this script's
header comments for the full list (config.yaml, passphrase file, rsync.net
authorized_keys, the flock-wrapped Cron Job command, GUI-managed
passwordless sudo, sourcing aliases.sh, and end-to-end testing).

Worth doing once, now that a working install exists:
  sudo sh $0 --simulate-failure    # proves rollback actually works
  sudo sh $0 --check               # quick post-update/reboot verification
==============================================================================
EOF
