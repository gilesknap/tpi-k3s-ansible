#!/bin/bash
# Encrypted nightly backup of the Secrets that are not in git.
#
# Exports the sealed-secrets controller's private keys and the other Secrets
# listed in $SOURCES as re-appliable YAML, tars them, encrypts the tar stream
# with age to the public key in $AGE_RECIPIENT, and copies the result to the
# NAS. Plaintext only exists in $WORK, which in the CronJob is a RAM-backed
# (medium: Memory) emptyDir: it never reaches a disk or the NAS. Nothing in
# the cluster holds the private key, so the cluster cannot read the backups.
#
# Each line of $SOURCES selects the Secrets for one file in the bundle:
#
#   file|namespace|names|selector|name_suffix|min
#
#   names        comma-separated Secret names, fetched with get
#   selector     label selector, used when names is empty (list)
#   name_suffix  keep only Secrets whose name ends with this
#   min          fail if fewer Secrets than this are found
#
# Runs in the backups/secrets-backup CronJob (see the backups chart). Written
# for bash with busybox tools (the alpine/k8s image), so it avoids GNU-only
# flags such as find -printf.
set -euo pipefail
umask 077

AGE_RECIPIENT=${AGE_RECIPIENT:-}
SOURCES=${SOURCES:-/etc/secrets-backup/sources}
DEST=${DEST:-/backup}
WORK=${WORK:-/work}
KEEP=${KEEP:-30}
KUBECTL=${KUBECTL:-kubectl}
AGE=${AGE:-age}

log() { echo "secrets-backup: $*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}

stage="$WORK/stage"
# Partial copy on the NAS, removed if the run dies before the rename.
partial=""

cleanup() {
    local rc=$?
    rm -rf "$stage" "$WORK"/*.tar.age 2> /dev/null || true
    if [[ -n $partial ]]; then
        rm -f "$partial" || log "warning: could not remove $partial"
    fi
    [[ $rc == 0 ]] || log "FAILED (exit $rc)"
    exit "$rc"
}
trap cleanup EXIT

# 1. Refuse to run without a recipient: never produce anything unencrypted.
if ! [[ $AGE_RECIPIENT =~ ^age1[02-9ac-hj-np-z]{58}$ ]]; then
    die "AGE_RECIPIENT is not an age public key (age1...). Set" \
        "backup_age_recipient in group_vars/all.yml and run" \
        "'ansible-playbook pb_all.yml --tags cluster'. Nothing was written."
fi
command -v "$AGE" > /dev/null || die "age is not installed"
command -v jq > /dev/null || die "jq is not installed"
[[ -r $SOURCES ]] || die "no source list at $SOURCES"
[[ -d $DEST && -w $DEST ]] ||
    die "$DEST does not exist or is not writable (see docs/how-to/nas-setup.md)"

rm -rf "$stage"
mkdir -p "$stage"

# Fields that tie an object to the cluster it came from. Without them the
# YAML re-applies cleanly to a new cluster; ownerReferences would point at
# objects that do not exist there, and the garbage collector would delete
# the restored Secret.
# shellcheck disable=SC2016  # $suffix is a jq variable, not a shell one
filter='
  def clean:
    del(.metadata.managedFields, .metadata.uid, .metadata.resourceVersion,
        .metadata.creationTimestamp, .metadata.selfLink, .metadata.generation,
        .metadata.ownerReferences,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])
    | if .metadata.annotations == {} then del(.metadata.annotations) else . end;
  {apiVersion: "v1", kind: "List",
   items: [(if .kind == "List" or .kind == "SecretList" then .items else [.] end)[]
           | select(.metadata.name | endswith($suffix))
           | clean]}
'

# 2. Dump each source to a YAML file in the RAM-backed stage directory.
total=0
summary=""
while IFS='|' read -r file ns names selector suffix min || [[ -n $file ]]; do
    [[ -z $file || $file == \#* ]] && continue
    [[ $file =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || die "bad file name '$file' in $SOURCES"
    args=(get secret --namespace "$ns" --output json)
    if [[ -n $names ]]; then
        IFS=',' read -r -a name_list <<< "$names"
        args+=("${name_list[@]}")
    elif [[ -n $selector ]]; then
        args+=(--selector "$selector")
    fi
    "$KUBECTL" "${args[@]}" > "$stage/$file.json" ||
        die "could not read Secrets for $file from namespace $ns"
    jq --arg suffix "$suffix" "$filter" "$stage/$file.json" > "$stage/$file.list.json"
    rm -f "$stage/$file.json"
    count=$(jq '.items | length' "$stage/$file.list.json")
    ((count >= ${min:-0})) ||
        die "$file: found $count Secrets in $ns, expected at least ${min:-0}"
    yq --input-format json --output-format yaml "$stage/$file.list.json" > "$stage/$file"
    jq -r '.items[] | "    - \(.metadata.namespace)/\(.metadata.name) (\(.type))"' \
        "$stage/$file.list.json" > "$stage/$file.names"
    rm -f "$stage/$file.list.json"
    log "$file: $count Secrets from $ns"
    total=$((total + count))
    summary+="$file: $count"$'\n'
done < "$SOURCES"
((total > 0)) || die "no Secrets selected"

{
    echo "created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "secrets: $total"
    echo "files:"
    for f in "$stage"/*.yaml; do
        echo "  $(basename "$f"):"
        cat "$f.names"
        rm -f "$f.names"
    done
    echo "sha256:"
    (cd "$stage" && sha256sum ./*.yaml | sed 's/^/  /')
} > "$stage/MANIFEST"

# 3. Encrypt. tar reads the RAM-backed stage directory and age writes only
#    ciphertext; the plaintext tar stream exists only in the pipe.
name="secrets-$(date -u +%Y%m%dT%H%M%SZ).tar.age"
tar -C "$stage" -cf - . | "$AGE" -r "$AGE_RECIPIENT" -o "$WORK/$name"
rm -rf "$stage"
size=$(stat -c %s "$WORK/$name")
want=$(sha256sum "$WORK/$name" | cut -d' ' -f1)

# read_back FILE: sha256 of FILE as stored on the NAS. O_DIRECT bypasses the
# local page cache, so the check reads what the server holds rather than what
# was just written. If the mount or dd refuses O_DIRECT, read it normally.
read_back() {
    if dd if="$1" of=/dev/null iflag=direct bs=1M count=1 2> /dev/null; then
        dd if="$1" iflag=direct bs=1M 2> /dev/null | sha256sum | cut -d' ' -f1
    else
        log "warning: O_DIRECT reads not supported, verifying via a normal read"
        sha256sum < "$1" | cut -d' ' -f1
    fi
}

# 4. Copy to the NAS via a .partial file, verify, then rename.
partial="$DEST/.$name.partial"
cp "$WORK/$name" "$partial"
sync "$partial" 2> /dev/null || sync
got=$(read_back "$partial")
[[ $want == "$got" ]] || die "checksum mismatch writing $DEST/$name"
mv -f "$partial" "$DEST/$name"
partial=""
rm -f "$WORK/$name"
echo "$want  $name" > "$DEST/$name.sha256"

# 5. Keep the newest $KEEP bundles by mtime, and drop .partial files left by
#    failed runs once they are a day old.
# shellcheck disable=SC2012  # names are ours: secrets-<UTC time>.tar.age
ls -1t "$DEST" | grep -E '^secrets-[0-9TZ]+\.tar\.age$' | tail -n +"$((KEEP + 1))" |
    while read -r old; do
        rm -f "$DEST/$old" "$DEST/$old.sha256"
        log "pruned $old"
    done
find "$DEST" -maxdepth 1 -type f -name '.*.partial' -mmin +1440 -exec rm -f {} +

# 6. LATEST marker: written to a temporary name and renamed, so it always
#    names a complete bundle.
{
    echo "bundle: $name"
    echo "created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "sha256: $want"
    echo "size: $size"
    echo "secrets: $total"
    printf '%s' "$summary"
} > "$DEST/.LATEST.tmp"
mv -f "$DEST/.LATEST.tmp" "$DEST/LATEST"
log "uploaded $DEST/$name ($size bytes, $total Secrets)"
