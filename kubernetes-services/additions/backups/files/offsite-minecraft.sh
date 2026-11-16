#!/bin/sh
# shellcheck shell=busybox
# Off-site copy of the Minecraft data to DEST_ROOT/minecraft, age-encrypted:
#
#   - with NIGHTLY=true, nightly/minecraft-<UTC time>.tar.age: the dashboard's store (backups,
#     snapshots, dashboard state) and, from the worlds' share, WORLD_DIRS:
#     the live worlds' volumes and the deleted worlds the dashboard archived.
#     One a UTC day: a Job retry does not upload a second. The KEEP newest
#     are kept. Nothing is pruned after a failed run, when
#     the listing on the target fails, or while the new tarball is under
#     MIN_SIZE_PERCENT of the largest copy there: a wiped or half-mounted
#     source must not push the good copies out. (After a deliberate large
#     deletion, delete the larger copies on the target by hand.)
#   - with ARCHIVE=true, archive/minecraft-archive-<fingerprint>.tar.age: the read-only world
#     archive, uploaded only when no copy with its fingerprint (a hash of its
#     file names and sizes) is on the target. So it goes up once, and again only if
#     the archive changes; older copies are never deleted. A state that
#     comes back is not uploaded again, so the newest copy is not always the
#     current one: archive/CURRENT.age (encrypted like every upload) names
#     the copy whose fingerprint matched on the last successful check.
#
# The worlds are copied while they run, as the Minecraft server writes
# them; the dashboard's own backups in the store are the consistent copies.
# tar fails if a file shrinks or vanishes under it (an autosave), so the
# nightly tarball is tried up to 3 times.
#
# Read-only mounts: with NIGHTLY=true, /src/store and /src/stable (the
# worlds' share); with ARCHIVE=true, /src/archive. Environment, besides
# offsite-lib.sh's: NIGHTLY, WORLD_DIRS (space-separated folders of
# /src/stable; the first must not be empty), ARCHIVE, KEEP,
# MIN_SIZE_PERCENT.
set -eu
set -o pipefail
set -f

# shellcheck source-path=SCRIPTDIR source=offsite-lib.sh
. "$(dirname "$0")/offsite-lib.sh"
setup

# The folders exist: the init container made them.
dest=$DEST_ROOT/minecraft
src=/src
remove_partials "$dest"

nonempty() { [ -d "$1" ] && [ -n "$(ls -A "$1")" ]; }

# Nightly tarball of the store and the worlds.
nightly_ok=
set -- store
for d in $WORLD_DIRS; do
    [ -d "$src/stable/$d" ] && set -- "$@" "stable/$d"
done
first_world=${WORLD_DIRS%% *}
if [ "$NIGHTLY" != true ]; then
    log "no nightly tarball for this target"
elif ! nonempty "$src/store" || ! nonempty "$src/stable/$first_world"; then
    fail "the store or the worlds ($first_world) are missing or empty: not uploading"
else
    # Fail closed: with no listing there is nothing to check the size
    # against, so nothing is pruned.
    listed=1
    if ! rclone lsf --files-only --format sp --separator '|' "$dest/nightly" >"$WORK/nightly"; then
        fail "could not list $dest/nightly: not pruning"
        listed=
    fi
    largest=$(grep '|minecraft-[0-9TZ]*\.tar\.age$' "$WORK/nightly" |
        cut -d'|' -f1 | sort -n | tail -n 1) || largest=
    today=$(date -u +%Y%m%d)
    target=minecraft-$(date -u +%Y%m%dT%H%M%SZ).tar.age
    uploaded=
    tries="1 2 3"
    if grep -q "|minecraft-${today}T[0-9]*Z\.tar\.age$" "$WORK/nightly"; then
        # A retry of tonight's Job, or a second manual run.
        log "a nightly tarball from today (UTC) is already there: not uploading another"
        tries=
        uploaded=skipped
    fi
    for try in $tries; do
        if send "$dest/nightly/$target" age tar -cf - -C "$src" "$@" </dev/null; then
            uploaded=1
            break
        fi
        log "the nightly tarball failed (try $try of 3)"
        if [ "$try" -lt 3 ]; then sleep "${RETRY_SLEEP:-30}"; fi
    done
    if [ -z "$uploaded" ]; then
        fail "could not upload the nightly tarball"
    elif [ "$uploaded" = skipped ]; then
        :
    else
        size=$(rclone lsf --files-only --format s "$dest/nightly/$target") || size=
        log "uploaded nightly/$target (${size:-unknown} bytes; $*)"
        if [ -z "$listed" ]; then
            :
        elif [ -z "$size" ]; then
            fail "could not read the size of nightly/$target: not pruning"
        elif [ -n "$largest" ] && [ $((size * 100)) -lt $((largest * MIN_SIZE_PERCENT)) ]; then
            fail "nightly/$target is under $MIN_SIZE_PERCENT% of the largest copy there ($largest bytes): not pruning"
        else
            nightly_ok=1
        fi
    fi
fi

if [ -n "$nightly_ok" ]; then
    if rclone lsf --files-only "$dest/nightly" >"$WORK/nightly"; then
        grep '^minecraft-[0-9TZ]*\.tar\.age$' "$WORK/nightly" |
            sort -r | tail -n +$((KEEP + 1)) >"$WORK/prune" || true
        while IFS= read -r p <&3; do
            if rclone deletefile "$dest/nightly/$p" </dev/null; then
                log "pruned nightly/$p"
            else
                fail "could not prune nightly/$p"
            fi
        done 3<"$WORK/prune"
    else
        fail "could not list $dest/nightly: not pruning"
    fi
fi

# The world archive, once per version of it.
if [ "$ARCHIVE" = true ]; then
    if ! nonempty "$src/archive"; then
        fail "the archive is missing or empty"
    elif ! rclone lsf --files-only "$dest/archive" >"$WORK/archive"; then
        fail "could not list $dest/archive: not uploading the archive"
    else
        fp=$(cd "$src/archive" && find . -type f | sort | while IFS= read -r f; do
            stat -c '%n %s' "$f"
        done | sha256sum | cut -c1-12)
        target=minecraft-archive-$fp.tar.age
        current=
        if grep -qxF "$target" "$WORK/archive"; then
            log "archive/$target is already there"
            current=1
        else
            log "uploading archive/$target"
            if send "$dest/archive/$target" age tar -cf - -C "$src" archive </dev/null; then
                log "uploaded archive/$target"
                current=1
            else
                fail "could not upload the archive"
            fi
        fi
        # Which copy is the current archive. Not one of the
        # minecraft-archive-*.tar.age names, so the check above never
        # matches it.
        if [ -n "$current" ]; then
            if send "$dest/archive/CURRENT.age" age printf 'current: %s\nchecked: %s\n' \
                "$target" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
                log "archive/CURRENT.age names $target"
            else
                fail "could not write archive/CURRENT.age"
            fi
        fi
    fi
fi

log "errors $failures"
[ "$failures" -eq 0 ]
