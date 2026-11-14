# shellcheck shell=busybox
# Shared by offsite-backups.sh and offsite-minecraft.sh, which source it.
# They run in the rclone image (Alpine, busybox sh) with age on the PATH.
#
# Environment:
#   DRIVE_ROOT     rclone path of the Drive folder, e.g. drive:home-cluster-offsite
#   AGE_RECIPIENT  the age public key every upload is encrypted to
#   RCLONE_SECRET  rclone.conf from the Secret (read-only)
#   WORK           a writable directory for this container
#
# Every upload is new and dated or content-named: nothing here mirrors a
# deletion from the NAS. Pruning, where a script does it, touches only files
# this job made on Drive (the drive.file scope cannot see any others).

failures=0

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

fail() {
    log "ERROR: $*" >&2
    failures=$((failures + 1))
}

setup() {
    case $AGE_RECIPIENT in
        age1*) ;;
        *) log "ERROR: AGE_RECIPIENT is not an age public key" >&2; exit 1 ;;
    esac
    mkdir -p "$WORK/cache"
    # rclone writes a refreshed access token back to its config file, so it
    # needs a writable copy. The refresh token in it does not change.
    cp "$RCLONE_SECRET" "$WORK/rclone.conf"
    chmod 600 "$WORK/rclone.conf"
    export RCLONE_CONFIG="$WORK/rclone.conf" HOME="$WORK" TMPDIR="$WORK" \
        XDG_CACHE_HOME="$WORK/cache"
    log "age $(age --version), $(rclone version | head -n 1)"
}

# The temporary name an upload streams to, beside its final name. A failed
# stream is deleted, so a truncated file never takes the final name (which
# would make later runs think it was uploaded).
partial_of() { printf '%s/.partial-%s' "${1%/*}" "${1##*/}"; }

# stream_to DEST: encrypt stdin to AGE_RECIPIENT and stream it to DEST's
# temporary name. Nothing plaintext is written anywhere. Follow it with
# finish DEST STATUS.
stream_to() {
    age -r "$AGE_RECIPIENT" | rclone rcat "$(partial_of "$1")"
}

# finish DEST STATUS: give the temporary upload its final name if the whole
# pipeline (STATUS) succeeded, else delete it.
finish() {
    _p=$(partial_of "$1")
    if [ "$2" -eq 0 ] && rclone moveto "$_p" "$1"; then
        return 0
    fi
    rclone deletefile --drive-use-trash=false "$_p" >/dev/null 2>&1 || true
    return 1
}

# remove_partials DIR: delete leftovers of uploads cut off by a killed pod.
remove_partials() {
    rclone delete --drive-use-trash=false --include '.partial-*' "$1" || fail "could not remove old partial uploads in $1"
}
