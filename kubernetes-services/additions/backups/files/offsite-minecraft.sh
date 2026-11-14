#!/bin/sh
# shellcheck shell=busybox
# Off-site copy of the Minecraft data to DRIVE_ROOT/minecraft, age-encrypted:
#
#   - nightly/minecraft-<UTC time>.tar.age: the dashboard's store (backups,
#     snapshots, dashboard state) and the live worlds' volumes, keeping the
#     KEEP newest. Nothing is pruned after a failed run, nor while the new
#     tarball is under MIN_SIZE_PERCENT of the largest copy on Drive: a wiped
#     or half-mounted source must not push the good copies out. (After a
#     deliberate large deletion, delete the larger copies on Drive by hand.)
#   - archive/minecraft-archive-<fingerprint>.tar.age: the read-only world
#     archive, uploaded only when no copy with its fingerprint (a hash of its
#     file names and sizes) is on Drive. So it goes up once, and again only if
#     the archive changes; older copies are never deleted.
#
# The worlds are copied while they run, as the Minecraft server writes
# them; the dashboard's own backups in the store are the consistent copies.
#
# Read-only mounts: /src/store, /src/worlds and, with ARCHIVE=true,
# /src/archive. Environment, besides offsite-lib.sh's: ARCHIVE, KEEP,
# MIN_SIZE_PERCENT.
set -eu
set -o pipefail

# shellcheck source=offsite-lib.sh
. "$(dirname "$0")/offsite-lib.sh"
setup

dest=$DRIVE_ROOT/minecraft
src=/src
rclone mkdir "$dest/nightly"
rclone mkdir "$dest/archive"
remove_partials "$dest"

nonempty() { [ -d "$1" ] && [ -n "$(ls -A "$1")" ]; }

# Nightly tarball of the store and the worlds.
nightly_ok=
if ! nonempty "$src/store" || ! nonempty "$src/worlds"; then
    fail "the store or the worlds are missing or empty: not uploading"
else
    largest=$(rclone lsf --files-only --format sp --separator '|' "$dest/nightly" |
        grep '|minecraft-[0-9TZ]*\.tar\.age$' | cut -d'|' -f1 | sort -n | tail -n 1) || largest=
    target=minecraft-$(date -u +%Y%m%dT%H%M%SZ).tar.age
    st=0
    tar -cf - -C "$src" store worlds </dev/null |
        stream_to "$dest/nightly/$target" || st=$?
    if finish "$dest/nightly/$target" "$st"; then
        size=$(rclone lsf --files-only --format s "$dest/nightly/$target")
        log "uploaded nightly/$target ($size bytes)"
        if [ -n "$largest" ] && [ $((size * 100)) -lt $((largest * MIN_SIZE_PERCENT)) ]; then
            fail "nightly/$target is under $MIN_SIZE_PERCENT% of the largest copy on Drive ($largest bytes): not pruning"
        else
            nightly_ok=1
        fi
    else
        fail "could not upload the nightly tarball"
    fi
fi

if [ -n "$nightly_ok" ]; then
    rclone lsf --files-only "$dest/nightly" | grep '^minecraft-[0-9TZ]*\.tar\.age$' |
        sort -r | tail -n +$((KEEP + 1)) >"$WORK/prune" || true
    while IFS= read -r p <&3; do
        if rclone deletefile "$dest/nightly/$p" </dev/null; then
            log "pruned nightly/$p"
        else
            fail "could not prune nightly/$p"
        fi
    done 3<"$WORK/prune"
fi

# The world archive, once per version of it.
if [ "$ARCHIVE" = true ]; then
    if ! nonempty "$src/archive"; then
        fail "the archive is missing or empty"
    else
        fp=$(cd "$src/archive" && find . -type f | sort | while IFS= read -r f; do
            stat -c '%n %s' "$f"
        done | sha256sum | cut -c1-12)
        target=minecraft-archive-$fp.tar.age
        if rclone lsf --files-only "$dest/archive" | grep -qxF "$target"; then
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
