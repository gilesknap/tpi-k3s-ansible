#!/bin/sh
# shellcheck shell=busybox
# Off-site copy of the NAS backups tree (backups/ of the cluster share) to
# DEST_ROOT/backups, in one of two scopes (the first argument), each run by
# its own container as the uid that can read it:
#
#   runs    the subtrees of RUN_DIRS (scrap's backup runs, whose files are
#           scrap's, many mode 0600): each run directory (a subdirectory of
#           one of RUN_DIRS) as one tarball, <dir>.tar.age once it has a
#           COMPLETE marker, or <dir>.incomplete.tar.age if it has none once
#           the folder's mtime is two days old; and any other file in those
#           subtrees as below;
#   others  everything else: every file as <path>.age, or as it is if it
#           already ends .age (the etcd bundles and sealed-secrets key
#           exports). It does not look inside RUN_DIRS at all.
#
# A backup goes up only if it is not on the target yet, compared by name.
# Each scope reads, cleans up and prunes only its own part of
# DEST_ROOT/backups
# (the RUN_DIRS subtrees, or the rest), so the two never touch each other's
# files.
#
# Dotfiles, files written in the last 10 minutes and EXCLUDE (paths of
# files rewritten in place, such as etcd/LATEST) are skipped. A file
# deleted on the NAS stays on the target.
#
# Then, when PRUNE_DAYS is above 0 and the run had no errors, a file on
# the target is deleted (on B2: hidden) only if all of these hold: its
# source is no longer on the NAS; it was uploaded over PRUNE_DAYS ago; and
# it is not one of the KEEP_MIN newest of its series (the same folder and
# name but for the date or time in it; a .sha256 sidecar counts with its
# bundle).
#
# Environment, besides offsite-lib.sh's: SRC (the backups tree, read-only),
# RUN_DIRS and EXCLUDE (space-separated), PRUNE_DAYS, KEEP_MIN;
# FIND_RECHECK_PAUSE (seconds, default 30; tests shorten it).
set -eu
set -o pipefail
set -f # no globbing of the space-separated lists

# shellcheck source-path=SCRIPTDIR source=offsite-lib.sh
. "$(dirname "$0")/offsite-lib.sh"

scope=${1:-}
case $scope in
    runs | others) ;;
    *) log "ERROR: usage: $0 runs|others" >&2; exit 2 ;;
esac
setup

dest=$DEST_ROOT/backups
remote=$WORK/remote
# Every name on the target that a backup now on the NAS maps to: never pruned.
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

# The RUN_DIRS not inside another of them: the subtrees that are the runs
# scope's, on the NAS and on the target.
roots=
for _r in $RUN_DIRS; do
    _top=1
    for _q in $RUN_DIRS; do
        case $_r in "$_q"/*) _top= ;; esac
    done
    if [ -n "$_top" ]; then roots="$roots $_r"; fi
done
if [ "$scope" = runs ] && [ -z "$roots" ]; then
    log "ERROR: no RUN_DIRS" >&2
    exit 1
fi

# This scope's files under SRC (relative to it), to stdout.
local_files() {
    if [ "$scope" = runs ]; then
        set --
        for _r in $roots; do
            if [ -d "$_r" ]; then set -- "$@" "$_r"; fi
        done
        [ $# -gt 0 ] || return 0
        find "$@" -type f -mmin +10
    elif [ -z "$roots" ]; then
        find . -type f -mmin +10
    else
        set --
        for _r in $roots; do
            set -- "$@" -o -path "./$_r"
        done
        shift # the first -o
        find . \( "$@" \) -prune -o -type f -mmin +10 -print
    fi
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

# rclone filters for this scope's part of $dest, as the positional
# parameters: each listing and deletion below passes them.
set --
for _r in $roots; do
    if [ "$scope" = runs ]; then
        set -- "$@" --filter "+ /$_r/**"
    else
        set -- "$@" --filter "- /$_r/**"
    fi
done
if [ "$scope" = runs ]; then set -- "$@" --filter "- **"; fi

# The folders exist: the init container made them (the runs scope's too).
if [ "$scope" = runs ]; then
    for _r in $roots; do
        remove_partials "$dest/$_r"
    done
else
    remove_partials "$dest" "$@"
fi
rclone lsf -R --files-only "$@" "$dest" >"$remote"
log "$(wc -l <"$remote") files of the $scope scope already in $dest"

# Run directories, each as one tarball. An unreadable one is an error
# (so nothing is pruned), and the rest carry on.
if [ "$scope" != runs ]; then RUN_DIRS=; fi
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
        if send "$dest/$target" age tar -cf - "$run" </dev/null; then
            log "uploaded $target"
            uploaded=$((uploaded + 1))
        else
            fail "could not upload $run"
        fi
    done 3<"$WORK/runs"
done

# Every other file. find reports unreadable directories but carries on.
local_files 2>"$WORK/find.err" | sed 's|^\./||' | sort >"$WORK/local" || true
if [ -s "$WORK/find.err" ]; then
    # A listing sometimes reports ./scrap, which this scope prunes, as
    # "Permission denied" (21, 24 and 28 Nov 2026), and a second listing
    # after a pause is clean. Use that second listing; fail if it is not.
    log "find: $(head -n 3 "$WORK/find.err"); listing again"
    sleep "${FIND_RECHECK_PAUSE:-30}"
    local_files 2>"$WORK/find.err" | sed 's|^\./||' | sort >"$WORK/local" || true
    if [ -s "$WORK/find.err" ]; then
        fail "could not read all of $SRC: $(head -n 3 "$WORK/find.err")"
    else
        log "second listing clean"
    fi
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
    case $f in
        # Already encrypted (to the same key): upload as it is.
        *.age) mode=as-is ;;
        *) mode=age ;;
    esac
    if send "$dest/$target" "$mode" cat "$f" </dev/null; then
        log "uploaded $target"
        uploaded=$((uploaded + 1))
    else
        fail "could not upload $f"
    fi
done 3<"$WORK/local"

log "uploaded $uploaded, already there $present, errors $failures"

# Pruning, of this scope's files (the filters are prune's arguments). Each
# line of the listing becomes
#   series|name time|upload time|instance|file time|source on NAS (1/0)|path
# where the instance is the path without a .sha256(.age) sidecar suffix
# (a bundle and its sidecar are one instance, timed by the newer upload),
# the series is the instance with its dates, times and version tokens
# (v1.34.13-k3s1) replaced by "*", and the name time is the date or time
# in the instance's name as digits (YYYYMMDDhhmmss, or an epoch), 0 if
# none. Instances rank newest first by name time, then upload time, then
# name.
prune() {
    cutoff=$(($(date +%s) - PRUNE_DAYS * 86400))
    if ! rclone lsf -R --files-only --format tp --separator '|' --time-format unix \
        "$@" "$dest" >"$WORK/remote-times"; then
        fail "could not list $dest: not pruning"
        return
    fi
    # (No {n} intervals in the patterns: not every awk has them.)
    awk -F'|' '
        function stamp(b,   m) {
            if (match(b, /[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z/)) {
                m = substr(b, RSTART, RLENGTH); return substr(m, 1, 8) substr(m, 10, 6)
            }
            if (match(b, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9]/)) {
                m = substr(b, RSTART, RLENGTH); gsub(/[-_]/, "", m); return m "00"
            }
            if (match(b, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
                m = substr(b, RSTART, RLENGTH); gsub(/-/, "", m); return m "000000"
            }
            if (match(b, /[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]+/)) return substr(b, RSTART, RLENGTH)
            return 0
        }
        NR == FNR { live[$0] = 1; next }
        {
            t = $1; p = substr($0, length($1) + 2)
            if (p ~ /(^|\/)\.partial-/) next
            inst = p; sub(/\.sha256(\.age)?$/, "", inst)
            base = inst; sub(/^.*\//, "", base)
            ser = inst
            gsub(/-v[0-9]+(\.[0-9]+)+(-k3s[0-9]+)?/, "-v*", ser)
            gsub(/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z/, "*", ser)
            gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9]/, "*", ser)
            gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/, "*", ser)
            gsub(/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]+/, "*", ser)
            if (t + 0 > itime[inst] + 0) itime[inst] = t
            n++; ft[n] = t; fp[n] = p; fi[n] = inst; fs[n] = ser; nt[n] = stamp(base)
        }
        END {
            for (i = 1; i <= n; i++)
                print fs[i] "|" nt[i] "|" itime[fi[i]] "|" fi[i] "|" ft[i] "|" ((fp[i] in live) ? 1 : 0) "|" fp[i]
        }' "$live" "$WORK/remote-times" |
        sort -t'|' -k1,1 -k2,2nr -k3,3nr -k4,4r |
        awk -F'|' -v cutoff="$cutoff" -v keep="$KEEP_MIN" '
            $1 != ser { ser = $1; k = 0; inst = "" }
            $4 != inst { inst = $4; k++ }
            k > keep && $5 < cutoff && $6 == 0 { print $7 }' >"$WORK/prune"
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
    prune "$@"
elif [ "$PRUNE_DAYS" -gt 0 ]; then
    log "not pruning: this run had errors"
fi

[ "$failures" -eq 0 ]
