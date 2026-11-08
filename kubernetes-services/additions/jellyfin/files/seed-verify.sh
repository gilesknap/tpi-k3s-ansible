#!/bin/sh
# Seed step 2 of 2 (init container, an SQLite image, as the jellyfin uid):
# check the copied database and mark the volume SEEDED-FROM-HOST.
# See seed-copy.sh for the markers.
set -eu

pv=/pv
seeded=$pv/SEEDED-FROM-HOST

if [ -e "$seeded" ]; then
  echo "seed-verify: already seeded: nothing to do"
  exit 0
fi
if [ ! -e "$pv/SEED-IN-PROGRESS" ] || [ ! -e "$pv/SEED-COPY-COMPLETE" ]; then
  echo "seed-verify: ERROR: no completed copy to verify" >&2
  exit 1
fi

# Read-write open of the copy (never the host's): SQLite creates and, on
# close, removes the -wal and -shm, owned by this uid.
result=$(sqlite3 "$pv/data/data/jellyfin.db" 'PRAGMA integrity_check;')
if [ "$result" != ok ]; then
  echo "seed-verify: ERROR: integrity_check failed:" >&2
  echo "$result" | head -n 20 >&2
  exit 1
fi
echo "seed-verify: integrity_check: ok"

# The marker is written last, atomically.
{
  echo "seeded from the host install at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "data: ${DATA_DIR:-?}, config: ${CONFIG_DIR:-?}"
  echo "integrity_check: ok"
} > "$pv/.seeded.tmp"
mv "$pv/.seeded.tmp" "$seeded"
rm -f "$pv/SEED-IN-PROGRESS" "$pv/SEED-COPY-COMPLETE"
echo "seed-verify: marked $seeded"
