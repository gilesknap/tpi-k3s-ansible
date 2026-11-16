#!/bin/sh
# shellcheck shell=busybox
# Init container (Drive only): make DEST_ROOT and its FOLDERS
# (space-separated) before the upload containers start. Drive allows two
# folders of one name, so two containers each making a missing folder at
# once could leave duplicates; made here, one at a time, they exist once
# and the uploads only use them.
set -eu
set -f

# shellcheck source-path=SCRIPTDIR source=offsite-lib.sh
. "$(dirname "$0")/offsite-lib.sh"
setup_rclone

rclone mkdir "$DEST_ROOT"
for d in $FOLDERS; do
    rclone mkdir "$DEST_ROOT/$d"
done
log "folders ready in $DEST_ROOT: $FOLDERS"
