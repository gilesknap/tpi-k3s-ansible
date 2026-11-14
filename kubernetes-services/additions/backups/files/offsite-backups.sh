#!/bin/sh
# shellcheck shell=busybox
# Off-site copy of the NAS backups tree (backups/ of the cluster share) to
# DRIVE_ROOT/backups. Each backup that is not on Drive yet, compared by
# name, goes up age-encrypted:
#
#   - a run directory (a subdirectory of one of RUN_DIRS, e.g. scrap's
#     dated runs) as one tarball: <dir>.tar.age once it has a COMPLETE
#     marker, or <dir>.incomplete.tar.age if it has none but has not
#     changed for two days;
#   - every other file as <path>.age, or as it is if it already ends .age
#     (the etcd bundles and sealed-secrets key exports).
#
# Dotfiles, files written in the last 10 minutes and EXCLUDE (paths of
# files rewritten in place, such as etcd/LATEST) are skipped. A file
# deleted on the NAS stays on Drive.
#
# Then, when PRUNE_DAYS is above 0 and the run had no errors, a file on
# Drive is deleted only if all of these hold: its source is no longer on
# the NAS; it was uploaded over PRUNE_DAYS ago; and it is not one of the
# KEEP_MIN newest of its series (the same folder and name but for the date
# or time in it; a .sha256 sidecar counts with its bundle).
#
# Environment, besides offsite-lib.sh's: SRC (the backups tree, read-only),
# RUN_DIRS and EXCLUDE (space-separated), PRUNE_DAYS, KEEP_MIN.
set -eu
set -o pipefail
set -f # no globbing of the space-separated lists

# shellcheck source-path=SCRIPTDIR source=offsite-lib.sh
. "$(dirname "$0")/offsite-lib.sh"
setup

dest=$DRIVE_ROOT/backups
remote=$WORK/remote
# Every name on Drive that a backup now on the NAS maps to: never pruned.
live=$WORK/live
: >"$live"
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

# The folder exists: the init container made it.
remove_partials "$dest"
rclone lsf -R --files-only "$dest" >"$remote"
log "$(wc -l <"$remote") files already in $dest"

# Run directories, each as one tarball. An unreadable one is an error
# (so nothing is pruned), and the rest carry on.
for parent in $RUN_DIRS; do
    [ -d "$parent" ] || continue
    if ! find "$parent" -mindepth 1 -maxdepth 1 -type d 2>"$WORK/runs.err" | sort >"$WORK/runs"; then
        fail "could not list $parent: $(head -n 3 "$WORK/runs.err")"
    fi
    while IFS= read -r run <&3; do
        case ${run##*/} in .*) continue ;; esac
        is_run_dir_parent "$run" && continue
        printf '%s\n%s\n' "$run.tar.age" "$run.incomplete.tar.age" >>"$live"
        if on_drive "$run.tar.age" || on_drive "$run.incomplete.tar.age"; then
            present=$((present + 1))
            continue
        fi
        if [ -e "$run/COMPLETE" ]; then
            target=$run.tar.age
        elif [ -n "$(find "$run" -maxdepth 0 -mtime +1 2>/dev/null)" ]; then
            target=$run.incomplete.tar.age
        else
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
    printf '%s\n' "$target" >>"$live"
    if on_drive "$target"; then
        present=$((present + 1))
        continue
    fi
    st=0
    case $f in
        # Already encrypted (to the same key): upload as it is.
        *.age) stream_as_is_to "$dest/$target" <"$f" || st=$? ;;
        *) stream_to "$dest/$target" <"$f" || st=$? ;;
    esac
    if finish "$dest/$target" "$st"; then ok=1; else ok=; fi
    if [ -n "$ok" ]; then
        log "uploaded $target"
        uploaded=$((uploaded + 1))
    else
        fail "could not upload $f"
    fi
done 3<"$WORK/local"

log "uploaded $uploaded, already on Drive $present, errors $failures"

# Pruning. Each line of the listing becomes
#   series|instance time|instance|file time|source on NAS (1/0)|path
# where the instance is the path without a .sha256(.age) sidecar suffix
# (a bundle and its sidecar are one instance, timed by the newer), and the
# series is the instance with its dates and times replaced by "*".
prune() {
    cutoff=$(($(date +%s) - PRUNE_DAYS * 86400))
    if ! rclone lsf -R --files-only --format tp --separator '|' --time-format unix \
        "$dest" >"$WORK/remote-times"; then
        fail "could not list $dest: not pruning"
        return
    fi
    awk -F'|' '
        NR == FNR { live[$0] = 1; next }
        {
            t = $1; p = substr($0, length($1) + 2)
            if (p ~ /(^|\/)\.partial-/) next
            inst = p; sub(/\.sha256(\.age)?$/, "", inst)
            ser = inst
            # (No {n} intervals: not every awk has them.)
            gsub(/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z/, "*", ser)
            gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9]/, "*", ser)
            gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/, "*", ser)
            gsub(/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]+/, "*", ser)
            if (t + 0 > itime[inst] + 0) itime[inst] = t
            n++; ft[n] = t; fp[n] = p; fi[n] = inst; fs[n] = ser
        }
        END {
            for (i = 1; i <= n; i++)
                print fs[i] "|" itime[fi[i]] "|" fi[i] "|" ft[i] "|" ((fp[i] in live) ? 1 : 0) "|" fp[i]
        }' "$live" "$WORK/remote-times" |
        sort -t'|' -k1,1 -k2,2nr -k3,3 |
        awk -F'|' -v cutoff="$cutoff" -v keep="$KEEP_MIN" '
            $1 != ser { ser = $1; k = 0; inst = "" }
            $3 != inst { inst = $3; k++ }
            k > keep && $4 < cutoff && $5 == 0 { print $6 }' >"$WORK/prune"
    pruned=0
    while IFS= read -r p <&3; do
        if rclone deletefile "$dest/$p" </dev/null; then
            log "pruned $p"
            pruned=$((pruned + 1))
        else
            fail "could not prune $p"
        fi
    done 3<"$WORK/prune"
    log "pruned $pruned files gone from the NAS and uploaded over $PRUNE_DAYS days ago"
}

if [ "$PRUNE_DAYS" -gt 0 ] && [ "$failures" -eq 0 ]; then
    prune
elif [ "$PRUNE_DAYS" -gt 0 ]; then
    log "not pruning: this run had errors"
fi

[ "$failures" -eq 0 ]
