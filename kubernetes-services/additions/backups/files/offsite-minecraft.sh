#!/bin/sh
# shellcheck shell=busybox
# Off-site copy of the Minecraft data to DRIVE_ROOT/minecraft, age-encrypted:
#
#   - nightly/minecraft-<UTC time>.tar.age: the dashboard's store (backups,
#     snapshots, dashboard state) and, from the worlds' share, WORLD_DIRS:
#     the live worlds' volumes and the deleted worlds the dashboard archived.
#     The KEEP newest are kept. Nothing is pruned after a failed run, when
#     the listing on Drive fails, or while the new tarball is under
#     MIN_SIZE_PERCENT of the largest copy on Drive: a wiped or half-mounted
#     source must not push the good copies out. (After a deliberate large
#     deletion, delete the larger copies on Drive by hand.)
#   - archive/minecraft-archive-<fingerprint>.tar.age: the read-only world
#     archive, uploaded only when no copy with its fingerprint (a hash of its
#     file names and sizes) is on Drive. So it goes up once, and again only if
#     the archive changes; older copies are never deleted.
#
# The worlds are copied while they run, as the Minecraft server writes
# them; the dashboard's own backups in the store are the consistent copies.
# tar fails if a file shrinks or vanishes under it (an autosave), so the
# nightly tarball is tried up to 3 times.
#
# Read-only mounts: /src/store, /src/stable (the worlds' share) and, with
# ARCHIVE=true, /src/archive. Environment, besides offsite-lib.sh's:
# WORLD_DIRS (space-separated folders of /src/stable; the first must not
# be empty), ARCHIVE, KEEP, MIN_SIZE_PERCENT.
set -eu
set -o pipefail
set -f

# shellcheck source-path=SCRIPTDIR source=offsite-lib.sh
. "$(dirname "$0")/offsite-lib.sh"
setup

# The folders exist: the init container made them.
dest=$DRIVE_ROOT/minecraft
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
if ! nonempty "$src/store" || ! nonempty "$src/stable/$first_world"; then
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
    target=minecraft-$(date -u +%Y%m%dT%H%M%SZ).tar.age
    uploaded=
    for try in 1 2 3; do
        st=0
        tar -cf - -C "$src" "$@" </dev/null | stream_to "$dest/nightly/$target" || st=$?
        if finish "$dest/nightly/$target" "$st"; then
            uploaded=1
            break
        fi
        log "the nightly tarball failed (try $try of 3)"
        if [ "$try" -lt 3 ]; then sleep "${RETRY_SLEEP:-30}"; fi
    done
    if [ -z "$uploaded" ]; then
        fail "could not upload the nightly tarball"
    else
        size=$(rclone lsf --files-only --format s "$dest/nightly/$target") || size=
        log "uploaded nightly/$target (${size:-unknown} bytes; $*)"
        if [ -z "$listed" ]; then
            :
        elif [ -z "$size" ]; then
            fail "could not read the size of nightly/$target: not pruning"
        elif [ -n "$largest" ] && [ $((size * 100)) -lt $((largest * MIN_SIZE_PERCENT)) ]; then
            fail "nightly/$target is under $MIN_SIZE_PERCENT% of the largest copy on Drive ($largest bytes): not pruning"
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
        if grep -qxF "$target" "$WORK/archive"; then
            log "archive/$target is already on Drive"
        else
            log "uploading archive/$target"
            st=0
            tar -cf - -C "$src" archive </dev/null |
                stream_to "$dest/archive/$target" || st=$?
            if finish "$dest/archive/$target" "$st"; then
                log "uploaded archive/$target"
            else
                fail "could not upload the archive"
            fi
        fi
    fi
fi

log "errors $failures"
[ "$failures" -eq 0 ]
