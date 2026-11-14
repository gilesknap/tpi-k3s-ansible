#!/bin/sh
# shellcheck shell=busybox
# Off-site copy of the NAS backups tree (backups/ of the cluster share) to
# DRIVE_ROOT/backups. Each backup that is not on Drive yet, compared by
# name, goes up age-encrypted:
#
#   - a run directory (a subdirectory of one of RUN_DIRS, e.g. scrap's
#     dated runs) as one tarball, <dir>.tar.age, once it has a COMPLETE
#     marker or has not changed for two days;
#   - every other file as <path>.age, or as it is if it already ends .age
#     (the etcd bundles and sealed-secrets key exports).
#
# Dotfiles, files written in the last 10 minutes and EXCLUDE (paths of
# files rewritten in place, such as etcd/LATEST) are skipped. A file deleted on the NAS stays on Drive. Then, when PRUNE_DAYS
# is above 0 and the run had no errors, files this job uploaded more than
# PRUNE_DAYS ago are deleted from Drive (to its trash), except the KEEP_MIN
# newest in each folder.
#
# Environment, besides offsite-lib.sh's: SRC (the backups tree, read-only),
# RUN_DIRS and EXCLUDE (space-separated), PRUNE_DAYS, KEEP_MIN.
set -eu
set -o pipefail
set -f # no globbing of the space-separated lists

# shellcheck source=offsite-lib.sh
. "$(dirname "$0")/offsite-lib.sh"
setup

dest=$DRIVE_ROOT/backups
remote=$WORK/remote
uploaded=0
present=0

is_run_dir_parent() {
    for _r in $RUN_DIRS; do
        [ "$1" = "$_r" ] && return 0
    done
    return 1
}

# True for a path inside a run directory (packed as a whole instead).
in_run() {
    for _r in $RUN_DIRS; do
        case $1 in
            "$_r"/*/*)
                _rest=${1#"$_r"/}
                is_run_dir_parent "$_r/${_rest%%/*}" || return 0
                ;;
        esac
    done
    return 1
}

excluded() {
    for _p in $EXCLUDE; do
        [ "$1" = "$_p" ] && return 0
    done
    return 1
}

on_drive() { grep -qxF "$1" "$remote"; }

cd "$SRC"
if [ -z "$(ls -A .)" ]; then
    # A missing mount or a wiped NAS: upload nothing and prune nothing.
    log "ERROR: $SRC is empty" >&2
    exit 1
fi

rclone mkdir "$dest"
remove_partials "$dest"
rclone lsf -R --files-only "$dest" >"$remote"
log "$(wc -l <"$remote") files already in $dest"

# Run directories, each as one tarball.
for parent in $RUN_DIRS; do
    [ -d "$parent" ] || continue
    find "$parent" -mindepth 1 -maxdepth 1 -type d | sort >"$WORK/runs"
    while IFS= read -r run <&3; do
        case ${run##*/} in .*) continue ;; esac
        is_run_dir_parent "$run" && continue
        target=$run.tar.age
        if on_drive "$target"; then
            present=$((present + 1))
            continue
        fi
        if [ ! -e "$run/COMPLETE" ] && [ -z "$(find "$run" -maxdepth 0 -mtime +1)" ]; then
            log "skipping $run: no COMPLETE marker yet"
            continue
        fi
        st=0
        tar -cf - "$run" </dev/null | stream_to "$dest/$target" || st=$?
        if finish "$dest/$target" "$st"; then
            log "uploaded $target"
            uploaded=$((uploaded + 1))
        else
            fail "could not upload $run"
        fi
    done 3<"$WORK/runs"
done

# Every other file. find reports unreadable directories but carries on.
find . -type f -mmin +10 2>"$WORK/find.err" | sed 's|^\./||' | sort >"$WORK/local" || true
if [ -s "$WORK/find.err" ]; then
    fail "could not read all of $SRC: $(head -n 3 "$WORK/find.err")"
fi
while IFS= read -r f <&3; do
    case /$f in */.*) continue ;; esac
    excluded "$f" && continue
    in_run "$f" && continue
    case $f in
        *.age) target=$f ;;
        *) target=$f.age ;;
    esac
    if on_drive "$target"; then
        present=$((present + 1))
        continue
    fi
    case $f in
        *.age)
            # Already encrypted (to the same key): upload as it is. Drive
            # only creates the file once the whole upload has arrived.
            if rclone copyto "$f" "$dest/$target" </dev/null; then
                ok=1
            else
                ok=
            fi
            ;;
        *)
            st=0
            stream_to "$dest/$target" <"$f" || st=$?
            if finish "$dest/$target" "$st"; then ok=1; else ok=; fi
            ;;
    esac
    if [ -n "$ok" ]; then
        log "uploaded $target"
        uploaded=$((uploaded + 1))
    else
        fail "could not upload $f"
    fi
done 3<"$WORK/local"

log "uploaded $uploaded, already on Drive $present, errors $failures"

if [ "$PRUNE_DAYS" -gt 0 ] && [ "$failures" -eq 0 ]; then
    cutoff=$(($(date +%s) - PRUNE_DAYS * 86400))
    # folder|upload time|path, newest first in each folder; keep the
    # KEEP_MIN newest whatever their age.
    rclone lsf -R --files-only --format tp --separator '|' --time-format unix "$dest" |
        awk -F'|' '{ p = substr($0, length($1) + 2); d = p
                     if (!sub(/\/[^\/]*$/, "", d)) d = "."
                     print d "|" $1 "|" p }' |
        sort -t'|' -k1,1 -k2,2nr |
        awk -F'|' -v cutoff="$cutoff" -v keep="$KEEP_MIN" '
            $1 != dir { dir = $1; n = 0 }
            { n++ }
            n > keep && $2 < cutoff { print $3 }' >"$WORK/prune"
    pruned=0
    while IFS= read -r p <&3; do
        if rclone deletefile "$dest/$p" </dev/null; then
            log "pruned $p"
            pruned=$((pruned + 1))
        else
            fail "could not prune $p"
        fi
    done 3<"$WORK/prune"
    log "pruned $pruned files uploaded over $PRUNE_DAYS days ago"
elif [ "$PRUNE_DAYS" -gt 0 ]; then
    log "not pruning: this run had errors"
fi

[ "$failures" -eq 0 ]
