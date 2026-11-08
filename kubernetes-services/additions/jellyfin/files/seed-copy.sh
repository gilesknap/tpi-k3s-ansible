#!/bin/bash
# Seed step 1 of 2 (init container, Jellyfin image, as the jellyfin uid):
# copy a stopped host install of Jellyfin into the config volume.
#
#   /pv           the config volume's root (read-write)
#   /host/data    the host's data directory, e.g. /var/lib/jellyfin (read-only)
#   /host/config  the host's config directory, e.g. /etc/jellyfin (read-only)
#
# Layout written: /pv/data (host data dir), /pv/config (host config dir),
# /pv/log (empty). Step 2 (seed-verify.sh) checks the database and writes
# SEEDED-FROM-HOST. Markers at the volume's root:
#
#   SEEDED-FROM-HOST              seeded: never touch the volume again
#   TRIAL-CONFIG-SAFE-TO-DELETE   a throwaway trial config: may be cleared
#   SEED-IN-PROGRESS              this script owns the volume's contents
#   SEED-COPY-COMPLETE            the copy is done, waiting for step 2
#
# The volume is cleared only under SEED-IN-PROGRESS, which this script writes
# only on an empty or trial-marked volume. Anything else fails loudly.
# The host directories are never written (read-only mounts).
set -euo pipefail

pv=/pv
seeded=$pv/SEEDED-FROM-HOST
trial=$pv/TRIAL-CONFIG-SAFE-TO-DELETE
busy=$pv/SEED-IN-PROGRESS
copied=$pv/SEED-COPY-COMPLETE
db=data/jellyfin.db

log() { echo "seed-copy: $*"; }
die() { echo "seed-copy: ERROR: $*" >&2; exit 1; }

if [ -e "$seeded" ]; then
  log "already seeded ($(head -n 1 "$seeded")): nothing to do"
  exit 0
fi
if [ -e "$busy" ] && [ -e "$copied" ]; then
  log "copy already complete: left for seed-verify"
  exit 0
fi

# Refuse while the host service looks live. Nothing in this pod listens yet
# (init containers run before Jellyfin), so a listener on 8096 is the host's.
# With hostNetwork, 127.0.0.1 is the node; HOST_IP covers the pod network.
for ip in 127.0.0.1 "${HOST_IP:?}"; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/8096" 2>/dev/null; then
    die "something listens on $ip:8096: the host Jellyfin looks live." \
      "Stop it (sudo systemctl disable --now jellyfin); this step retries."
  fi
done
if [ -s "/host/data/$db-wal" ]; then
  die "/host/data/$db-wal is not empty: the host Jellyfin looks live, or" \
    "did not stop cleanly. Stop it (or start and stop it again); this" \
    "step retries."
fi
[ -f "/host/data/$db" ] || die "no host database at /host/data/$db"
[ -d /host/config ] || die "no host config directory at /host/config"

# Claim the volume. SEED-IN-PROGRESS is written before the trial marker is
# removed, so an interrupted run always resumes here.
if [ -e "$busy" ]; then
  log "resuming an interrupted seed"
elif [ -e "$trial" ]; then
  log "trial config found: clearing it"
  touch "$busy"
  rm -f "$trial"
elif [ -z "$(ls -A "$pv")" ]; then
  log "empty volume"
  touch "$busy"
else
  ls -la "$pv" >&2
  die "the volume holds data without $(basename "$trial") or" \
    "$(basename "$seeded"): refusing to clear it. Check it by hand."
fi
find "$pv" -mindepth 1 -maxdepth 1 ! -name "$(basename "$busy")" \
  -exec rm -rf {} +

# Copy under temporary names, renamed once complete. cp -a keeps modes and
# times; the owner is this uid already, and a group the uid is not in (adm,
# on the config directory) falls back to the volume's group.
log "copying /host/data ($(du -sh /host/data | cut -f1))"
cp -a /host/data/. "$pv/.seed-data"
log "copying /host/config"
cp -a /host/config/. "$pv/.seed-config"

# The host was stopped cleanly: its -wal is empty or gone, so the -shm is
# stale. Drop both from the copy; SQLite recreates them.
rm -f "$pv/.seed-data/$db-shm" "$pv/.seed-data/$db-wal"

# Check the copy against the host: the database byte for byte, and the file
# count and total size of each tree (without those two files).
cmp "/host/data/$db" "$pv/.seed-data/$db" || die "database copy differs"
tally() {
  (cd "$1" && find . -type f ! -path "./$db-shm" ! -path "./$db-wal" \
    -printf '%s\n' | awk '{ n++; s += $1 } END { print n + 0, s + 0 }')
}
for t in data config; do
  src=$(tally "/host/$t")
  dst=$(tally "$pv/.seed-$t")
  [ "$src" = "$dst" ] || die "$t: host has $src (files bytes), copy has $dst"
  log "$t: $dst (files bytes) match the host"
done

# Patch HardwareDecodingCodecs in the copied encoding.xml (never the host's).
enc=$pv/.seed-config/encoding.xml
if [ -n "${CODECS:-}" ]; then
  [ -f "$enc" ] || die "no encoding.xml in the host config"
  awk -v codecs="$CODECS" '
    /<HardwareDecodingCodecs>/ || /<HardwareDecodingCodecs *\/>/ {
      match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH)
      print ind "<HardwareDecodingCodecs>"
      n = split(codecs, c, " ")
      for (i = 1; i <= n; i++) print ind "  <string>" c[i] "</string>"
      print ind "</HardwareDecodingCodecs>"
      found++
      if ($0 !~ /\/>/ && $0 !~ /<\/HardwareDecodingCodecs>/) skip = 1
      next
    }
    skip { if ($0 ~ /<\/HardwareDecodingCodecs>/) skip = 0; next }
    { print }
    END { if (found != 1 || skip) exit 3 }
  ' "$enc" > "$enc.new" || die "encoding.xml: no single HardwareDecodingCodecs"
  cat "$enc.new" > "$enc"
  rm -f "$enc.new"
  log "encoding.xml: HardwareDecodingCodecs set to: $CODECS"
fi

mv "$pv/.seed-data" "$pv/data"
mv "$pv/.seed-config" "$pv/config"
mkdir -p "$pv/log"
touch "$copied"
log "copy complete"
