#!/bin/sh
#
# Compares the versions pinned in setup-borgmatic.sh against the latest
# upstream releases and prints a Markdown report to stdout.
#
# Exit status: 0 = everything current, 10 = at least one update available,
# anything else = the check itself failed (network, parsing). A newer
# virtualenv is listed but never counts as an update on its own: it is only an
# installation bootstrap and stays pinned unless there is a reason to move it.
#
# Borg is compared within its pinned major.minor series (e.g. 1.4.x), since a
# new series needs a matching remote_path on rsync.net; a newer stable series
# is reported separately as informational.
#
# borgmatic versions listed in BORGMATIC_SKIP_VERSIONS are known-bad: they are
# reported as skipped and never count as an update.
#
# Needs curl, jq and git. Borg releases are read from the repository's tags
# (stable releases are plain X.Y.Z; betas and release candidates carry a
# suffix), so no GitHub API token is needed.
set -eu

script="${1:-setup-borgmatic.sh}"

pin() {
    value="$(sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$script")"
    if [ -z "$value" ]; then
        echo "ERROR: could not read $1 from $script" >&2
        exit 2
    fi
    printf '%s\n' "$value"
}

fetch() {
    curl -fsSL --retry 3 "$1"
}

# True when $2 is a strictly newer version than $1.
is_newer() {
    [ "$1" != "$2" ] &&
        [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]
}

pypi_latest() {
    fetch "https://pypi.org/pypi/$1/json" | jq -r '.info.version'
}

borgmatic_pinned="$(pin BORGMATIC_VERSION)"
borgmatic_skip="$(sed -n 's/^BORGMATIC_SKIP_VERSIONS="\(.*\)"$/\1/p' "$script")"
borg_pinned="$(pin BORG_VERSION)"
virtualenv_pinned="$(pin VIRTUALENV_VERSION)"

borgmatic_latest="$(pypi_latest borgmatic)"
virtualenv_latest="$(pypi_latest virtualenv)"

borg_stable_tags="$(git ls-remote --tags --refs https://github.com/borgbackup/borg.git |
    sed 's|.*refs/tags/||; s/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)"
borg_series="${borg_pinned%.*}"
borg_latest="$(printf '%s\n' "$borg_stable_tags" | grep -F "$borg_series." | tail -n 1)"
borg_newest_overall="$(printf '%s\n' "$borg_stable_tags" | tail -n 1)"

for value in "$borgmatic_latest" "$virtualenv_latest" "$borg_latest" "$borg_newest_overall"; do
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "ERROR: could not determine a latest upstream version" >&2
        exit 2
    fi
done

updates=0
row() {
    name="$1"
    pinned="$2"
    latest="$3"
    link="$4"
    informational="${5:-}"
    skipped="${6:-}"
    if is_newer "$pinned" "$latest" && [ -n "$skipped" ]; then
        status="skipped (known-bad, see BORGMATIC_SKIP_VERSIONS)"
    elif is_newer "$pinned" "$latest" && [ -n "$informational" ]; then
        status="newer available (optional)"
    elif is_newer "$pinned" "$latest"; then
        status="**update available**"
        updates=1
    else
        status="current"
    fi
    echo "| $name | $pinned | [$latest]($link) | $status |"
}

echo "| Component | Pinned | Latest | Status |"
echo "|---|---|---|---|"
borgmatic_skipped=""
for version in $borgmatic_skip; do
    if [ "$version" = "$borgmatic_latest" ]; then
        borgmatic_skipped=1
    fi
done
row borgmatic "$borgmatic_pinned" "$borgmatic_latest" \
    "https://github.com/borgmatic-collective/borgmatic/releases" "" "$borgmatic_skipped"
row "Borg ($borg_series.x)" "$borg_pinned" "$borg_latest" \
    "https://github.com/borgbackup/borg/releases/tag/$borg_latest"
row virtualenv "$virtualenv_pinned" "$virtualenv_latest" \
    "https://github.com/pypa/virtualenv/releases/tag/$virtualenv_latest" informational

if [ "${borg_newest_overall%.*}" != "$borg_series" ] &&
    is_newer "$borg_pinned" "$borg_newest_overall"; then
    echo ""
    echo "A newer stable Borg series is also available: $borg_newest_overall." \
        "Moving to it needs a matching remote_path (and authorized_keys forced" \
        "command) on rsync.net, so treat it as a separate, deliberate upgrade."
fi

cat <<'NOTES'

Update deliberately, one component at a time, following "Updating pinned
versions" in README.md:

- **borgmatic:** bump `BORGMATIC_VERSION` and regenerate `requirements.txt`.
- **Borg:** bump `BORG_VERSION` and `BORG_SHA256` together, taking the checksum
  from the official release; keep the rsync.net `remote_path` series compatible.
- **virtualenv:** only a bootstrap; leave it pinned unless a security or Python
  compatibility issue gives a reason to change it.

Commit, deploy, run a real backup, test a restore, and run `--simulate-failure`
before tagging.
NOTES

if [ "$updates" -eq 1 ]; then
    exit 10
fi
