# shellcheck shell=busybox
# Shared by the offsite-*.sh scripts, which source it. They run in the
# rclone image (Alpine, busybox sh) with age on the PATH.
#
# Environment:
#   TARGET         drive or b2: the kind of remote DEST_ROOT is
#   DEST_ROOT      rclone path of the target's root, e.g.
#                  drive:home-cluster-offsite or b2:<bucket>
#   AGE_RECIPIENT  the age public key every upload is encrypted to
#   RCLONE_SECRET  rclone.conf from the Secret (read-only)
#   WORK           a writable directory for this container
#
# Every upload is new and dated or content-named: nothing here mirrors a
# deletion from the NAS. Pruning, where a script does it, touches only files
# this job made on the target (on Drive the drive.file scope cannot see any
# others; the B2 bucket holds nothing else). On Drive deletions skip the
# trash (RCLONE_DRIVE_USE_TRASH=false, set in the CronJob), whose contents
# would still count against the quota. On B2 a deletion only hides the file
# (RCLONE_B2_HARD_DELETE=false): under the bucket's Object Lock its version
# stays until its retention ends.

failures=0

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

fail() {
    log "ERROR: $*" >&2
    failures=$((failures + 1))
}

# rclone writes a refreshed access token back to its config file, so it
# needs a writable copy. The refresh token in it does not change.
setup_rclone() {
    mkdir -p "$WORK/cache"
    cp "$RCLONE_SECRET" "$WORK/rclone.conf"
    chmod 600 "$WORK/rclone.conf"
    export RCLONE_CONFIG="$WORK/rclone.conf" HOME="$WORK" TMPDIR="$WORK" \
        XDG_CACHE_HOME="$WORK/cache"
}

setup() {
    case $TARGET in
        drive | b2) ;;
        *) log "ERROR: TARGET is not drive or b2" >&2; exit 1 ;;
    esac
    case $AGE_RECIPIENT in
        age1*) ;;
        *) log "ERROR: AGE_RECIPIENT is not an age public key" >&2; exit 1 ;;
    esac
    setup_rclone
    log "age $(age --version), $(rclone version | head -n 1)"
}

# The temporary name a Drive upload streams to, beside its final name. A
# failed stream is deleted, so a truncated file never takes the final name
# (which would make later runs think it was uploaded).
partial_of() { printf '%s/.partial-%s' "${1%/*}" "${1##*/}"; }

# produce MODE CMD [ARG...]: run CMD, its output encrypted to AGE_RECIPIENT
# (MODE age) or as it is (MODE as-is: a file that is already encrypted).
produce() {
    _m=$1
    shift
    if [ "$_m" = age ]; then
        "$@" | age -r "$AGE_RECIPIENT"
    else
        "$@"
    fi
}

# send DEST MODE CMD [ARG...]: upload produce's output to DEST. Nothing
# plaintext is written anywhere. Like every upload it gets the upload time
# as its time on the target, which pruning goes by (rclone copyto would keep
# the NAS file's time). Succeeds only if the whole pipeline did; otherwise
# nothing is left under DEST's name:
#   - drive: the stream goes to DEST's temporary name, which is renamed to
#     DEST once the pipeline has succeeded, and deleted if it failed;
#   - b2: a rename there is a copy, and under Object Lock the temporary
#     version would be kept for the whole retention too, so the stream goes
#     straight to DEST. rclone reads it from a fifo whose write end this
#     shell holds open until the pipeline's status is known: if it failed,
#     rclone is killed, and waited for, before the stream is closed, so a
#     cut-off stream is never finished as a file (an unfinished large-file upload
#     is cancelled by the bucket's lifecycle rule).
send() {
    _dest=$1
    _mode=$2
    shift 2
    _st=0
    if [ "$TARGET" = b2 ]; then
        _fifo=$WORK/upload.fifo
        rm -f "$_fifo"
        mkfifo "$_fifo"
        rclone rcat "$_dest" <"$_fifo" &
        _pid=$!
        exec 4>"$_fifo"
        produce "$_mode" "$@" >&4 || _st=$?
        if [ "$_st" -ne 0 ]; then
            # Wait for rclone to be gone before closing the stream: closed
            # first, it could see the end of it while handling the signal
            # and finish the cut-off stream as the file.
            kill "$_pid" 2>/dev/null || true
            wait "$_pid" 2>/dev/null || true
            exec 4>&-
        else
            exec 4>&-
            wait "$_pid" || _st=$?
        fi
        rm -f "$_fifo"
        return "$_st"
    fi
    produce "$_mode" "$@" | rclone rcat "$(partial_of "$_dest")" || _st=$?
    finish "$_dest" "$_st"
}

# finish DEST STATUS (Drive): give the temporary upload its final name if
# the whole pipeline (STATUS) succeeded, else delete it.
finish() {
    _p=$(partial_of "$1")
    if [ "$2" -eq 0 ] && rclone moveto "$_p" "$1"; then
        return 0
    fi
    rclone deletefile "$_p" >/dev/null 2>&1 || true
    return 1
}

# remove_partials DIR [FILTER...]: delete leftovers of Drive uploads cut
# off by a killed pod. The rclone --filter options FILTER, if any, come first: an
# excluded path is left alone.
remove_partials() {
    [ "$TARGET" = b2 ] && return 0 # no temporary names there
    _d=$1
    shift
    rclone delete "$@" --filter '+ .partial-*' --filter '- **' "$_d" ||
        fail "could not remove old partial uploads in $_d"
}
