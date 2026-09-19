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
#        ssh_command: ssh -i $BASE_DIR/ssh/id_ed25519
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
#   2. Passphrase file (if using encryption_passcommand as above):
#        sudo sh -c 'echo -n "your-actual-passphrase" > BASE_DIR/passphrase'
#        sudo chmod 600 BASE_DIR/passphrase
#
#   3. rsync.net authorized_keys needs a forced command restricted to this
#      repo, using the versioned remote binary name (borg14, borg15, etc. --
#      whatever `remote_path` above is set to), e.g.:
#        command="borg14 serve --restrict-to-repository /home/XXXXX/yourrepo",restrict ssh-ed25519 AAAA...
#      A bare "borg serve" (unversioned) will fail on providers that pin
#      multiple Borg versions -- match remote_path exactly.
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
SCRIPT_VERSION="1.1.2"
BASE_DIR="/mnt/apps/borgmatic"
BORGMATIC_VERSION="2.1.7"
BORG_VERSION="1.4.5"
BORG_ASSET="borg-linux-glibc231-x86_64"
BORG_SHA256="c8457f70660064d0f45b38283ab4cc65b342970012013201d3aec713a75898fb"
BORG_URL="https://github.com/borgbackup/borg/releases/download/${BORG_VERSION}/${BORG_ASSET}"
VIRTUALENV_VERSION="21.7.4"
VIRTUALENV_URL="https://github.com/pypa/virtualenv/releases/download/${VIRTUALENV_VERSION}/virtualenv.pyz"
VIRTUALENV_SHA256="2dfdb6785b762b8a7a7a31d413c16516aa785552d05f61435b072fde1cb340cc"
LOCK_FILE="$BASE_DIR/borgmatic.lock"
# -----------------------------------------------------------------------------

ACTION="install"
for arg in "$@"; do
    case "$arg" in
        --version)
            echo "setup-borgmatic.sh $SCRIPT_VERSION"
            exit 0
            ;;
        --check)
            ACTION="check"
            ;;
        --simulate-failure)
            ACTION="simulate-failure"
            ;;
        *)
            echo "ERROR: Unknown argument: $arg" >&2
            echo "Usage: $0 [--check|--simulate-failure|--version]" >&2
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
    else
        echo "NOTE: $BASE_DIR/config.yaml not found -- skipping config validation."
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
        echo ""
        echo "==> All checks passed."
        exit 0
    else
        echo ""
        echo "==> One or more checks failed. See above." >&2
        exit 1
    fi
fi

for required_command in curl python3 sha256sum awk grep flock; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $required_command" >&2
        exit 1
    fi
done

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

rollback_install() {
    if [ "$ACTION" = "simulate-failure" ]; then
        echo "==> Intentional simulated failure; restoring previous installation." >&2
    else
        echo "ERROR: Installation failed; restoring previous installation." >&2
    fi
    if [ "$VENV_REPLACED" -eq 1 ]; then
        rm -rf "$BASE_DIR/venv"
        if [ -d "$BASE_DIR/venv-previous" ]; then
            mv "$BASE_DIR/venv-previous" "$BASE_DIR/venv"
        fi
    fi
    if [ "$BORG_REPLACED" -eq 1 ]; then
        rm -f "$BASE_DIR/bin/borg"
        if [ -f "$BASE_DIR/bin/borg.previous" ]; then
            mv "$BASE_DIR/bin/borg.previous" "$BASE_DIR/bin/borg"
        fi
    fi
    if [ "$WRAPPER_REPLACED" -eq 1 ]; then
        rm -f "$BASE_DIR/bin/borg-wrapper.sh"
        if [ -f "$BASE_DIR/bin/borg-wrapper.sh.previous" ]; then
            mv "$BASE_DIR/bin/borg-wrapper.sh.previous" "$BASE_DIR/bin/borg-wrapper.sh"
        fi
    fi
    if [ "$VIRTUALENV_REPLACED" -eq 1 ]; then
        rm -f "$BASE_DIR/virtualenv.pyz"
        if [ -f "$BASE_DIR/virtualenv.pyz.previous" ]; then
            mv "$BASE_DIR/virtualenv.pyz.previous" "$BASE_DIR/virtualenv.pyz"
        fi
    fi
    ROLLBACK_ACTIVE=0
    echo "==> Rollback complete. Run '$0 --check' to confirm the restored install works."
}

handle_exit() {
    exit_status="$?"
    trap - EXIT HUP INT TERM
    if [ "$ROLLBACK_ACTIVE" -eq 1 ]; then
        rollback_install
    fi
    exit "$exit_status"
}

ROLLBACK_ACTIVE=0
VENV_REPLACED=0
BORG_REPLACED=0
WRAPPER_REPLACED=0
VIRTUALENV_REPLACED=0
trap handle_exit EXIT
trap 'exit 1' HUP INT TERM

# ---- 1. virtualenv zipapp (bypasses ensurepip + PEP 668) -------------------
echo "==> Fetching virtualenv.pyz"
download "$VIRTUALENV_URL" "$BASE_DIR/virtualenv.pyz.new"
verify_sha256 "$VIRTUALENV_SHA256" "$BASE_DIR/virtualenv.pyz.new"
if ! python3 "$BASE_DIR/virtualenv.pyz.new" --version | grep -F "virtualenv $VIRTUALENV_VERSION" >/dev/null; then
    echo "ERROR: Downloaded virtualenv.pyz is not version $VIRTUALENV_VERSION." >&2
    exit 1
fi
rm -f "$BASE_DIR/virtualenv.pyz.previous"
if [ -f "$BASE_DIR/virtualenv.pyz" ]; then
    mv "$BASE_DIR/virtualenv.pyz" "$BASE_DIR/virtualenv.pyz.previous"
fi
VIRTUALENV_REPLACED=1
mv "$BASE_DIR/virtualenv.pyz.new" "$BASE_DIR/virtualenv.pyz"

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
rm -rf "$BASE_DIR/venv-new"
rm -rf "$BASE_DIR/venv-previous"
if [ -d "$BASE_DIR/venv" ]; then
    mv "$BASE_DIR/venv" "$BASE_DIR/venv-previous"
fi
VENV_REPLACED=1
ROLLBACK_ACTIVE=1

echo "==> Building replacement venv at $BASE_DIR/venv"
python3 "$BASE_DIR/virtualenv.pyz" "$BASE_DIR/venv"

echo "==> Installing borgmatic into the venv (pure Python -- no compiler needed)"
"$BASE_DIR/venv/bin/pip" install "borgmatic==$BORGMATIC_VERSION"
"$BASE_DIR/venv/bin/borgmatic" --version

rm -f "$BASE_DIR/bin/borg.previous"
if [ -f "$BASE_DIR/bin/borg" ]; then
    mv "$BASE_DIR/bin/borg" "$BASE_DIR/bin/borg.previous"
fi
BORG_REPLACED=1
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
    mv "$BASE_DIR/bin/borg-wrapper.sh" "$BASE_DIR/bin/borg-wrapper.sh.previous"
fi
WRAPPER_REPLACED=1
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

if [ -f "$BASE_DIR/config.yaml" ]; then
    :  # already validated inside run_verification
else
    echo "NOTE: no config.yaml yet -- see the AFTER RUNNING section in this"
    echo "      script's header comments for the required settings."
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
