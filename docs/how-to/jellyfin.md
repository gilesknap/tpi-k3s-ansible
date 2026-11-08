# Run Jellyfin

[Jellyfin](https://jellyfin.org) is a self-hosted media server. This
repository runs it in the cluster from the upstream
[jellyfin/jellyfin](https://github.com/jellyfin/jellyfin-helm) Helm chart,
pinned to one node with an Intel iGPU for hardware transcoding. It is for the
LAN and Tailscale only: there is no Ingress and no Cloudflare route.

The page describes a move from a Jellyfin installed on a node's host OS (the
apt package) into the cluster. It happens in stages: first a **trial** that
runs alongside the host install with a throwaway config, then a **cutover**
that copies the host's data in and takes over its ports.

## What this deploys

The cluster wiring is:

- An ArgoCD Application (`kubernetes-services/templates/jellyfin.yaml`),
  toggled by `enable_jellyfin` and configured from the `jellyfin` block in
  `kubernetes-services/values.yaml`. Its first source is the upstream chart;
  the second is `kubernetes-services/additions/jellyfin/`, with the claims
  and volumes below.
- The chart repository `https://jellyfin.github.io/jellyfin-helm` in the
  AppProject's `sourceRepos` (`argo-cd/argo-project.yaml`).

| Piece | Where | Notes |
|-------|-------|-------|
| Deployment and ClusterIP Service on 8096 | Upstream chart, namespace `jellyfin` | One pod, `Recreate` strategy, no PodDisruptionBudget |
| Data (database, metadata, subtitles, plugins), XML config, logs | Static `local-nvme` PV on the node (`local_storage.jellyfin`), claim `jellyfin-config`: its `data/`, `config/` and `log/` | Created by the `k8s_data_dirs` role, owned by the pod's uid/gid. Not NFS: the database is SQLite |
| Media library | Static NFS PV `jellyfin-media-nfs` of `jellyfin.media.nfs_path` on `nfs.server`, claim `jellyfin-media` | Read-only (PV, access mode and mount), at `jellyfin.media.mount_path` |
| Cache and transcodes | `emptyDir` at `/var/cache/jellyfin`, `jellyfin.cache_size` | Lost on a pod restart, which is harmless; see the note below on its size |
| GPU | `gpu.intel.com/i915: 1` from the [Intel GPU device plugin](../reference/services.md#intel-gpu-device-plugin) | Not privileged |

The pod:

- is pinned to the node by `nodeSelector` (and by the local PV's
  `nodeAffinity`);
- runs as `jellyfin.uid`:`jellyfin.gid`, the node's own `jellyfin` account,
  so files on the volume have the owner a host install would give them;
- has the node's `render` and `video` group IDs in `supplementalGroups`
  (`jellyfin.render_gid`, `jellyfin.video_gid`), so it can open
  `/dev/dri/renderD128` (`root:render`, mode 0660) and `/dev/dri/card0`;
- requests 500m CPU and 1Gi memory, with a 4Gi memory limit and no CPU
  limit, so transcode bursts are not throttled.

Jellyfin sees the same paths as a host install of the Debian/Ubuntu package,
not the image's `/config` layout:

| Pod path | Variable | Comes from |
|----------|----------|------------|
| `/var/lib/jellyfin` (data, and `HOME`) | `jellyfin.data_dir` | the config volume's `data/` |
| `/etc/jellyfin` (XML config) | `jellyfin.config_dir` | the config volume's `config/` |
| `/var/log/jellyfin` | `jellyfin.log_dir` | the config volume's `log/` |
| `/var/cache/jellyfin` | `jellyfin.cache_dir` | the cache `emptyDir` |
| for example `/media/bigdisk/media` | `jellyfin.media.mount_path` | the media NFS volume |

Jellyfin is pointed at them with its `JELLYFIN_*_DIR` environment variables,
and the volume's subdirectories are mounted there with `subPath`. So the
absolute paths stored in a database and XML config copied from a host
install stay valid, with nothing rewritten, and the host copy stays usable
for a rollback. The chart's own `/config`, `/media` and `/cache` are unused
`emptyDir`s.

The pod's init containers, in order, all on the config volume's root:

- `mark-trial` (trial only; see [Trial](#trial));
- `seed-copy` and `seed-verify` (`jellyfin.seed_from_host` only; see
  [Seed from a host install](#seed-from-a-host-install));
- `layout`, which creates `data/`, `config/` and `log/` if missing, as the
  pod's uid, so kubelet never creates them as root for the `subPath` mounts.

:::{note}
The cache `emptyDir` has a `sizeLimit` (20Gi by default), and the transcode
segments are written under it. If it fills, kubelet **evicts the pod**, which
stops every stream. Jellyfin deletes old segments as playback moves on, so
one stream uses a few GB at most, but several concurrent 4K transcodes, or
seeking far ahead in them, can reach the limit. Raise `jellyfin.cache_size`
if you expect that.
:::

kured may reboot the node: Jellyfin is then down until the node is back, as a
host install would be.

:::{note}
The node's `render` group ID is allocated dynamically and can change across an
OS release upgrade. Check it with `getent group render` on the node, and set
`jellyfin.render_gid` to match. With the wrong ID, the GPU is silently
unusable and Jellyfin falls back to software transcoding.
:::

## Before the first sync

1. **The node is labelled for the GPU.** Set `intel_gpu_node: true` for it in
   `hosts.yml` and run the k3s role, so the device plugin advertises
   `gpu.intel.com/i915` there:

   ```bash
   kubectl get nodes -o custom-columns='NODE:.metadata.name,I915:.status.allocatable.gpu\.intel\.com/i915'
   ```

   The node must also be schedulable (not cordoned).

2. **The config directory exists.** The `local_storage.jellyfin` entry in
   `kubernetes-services/values.yaml` and the `jellyfin` entry in
   `k8s_data_dirs` (`group_vars/all.yml`) must agree on node and path. Create
   the directory, before ArgoCD syncs, with:

   ```bash
   ansible-playbook pb_all.yml --tags k8s_data_dirs --limit <node>
   ```

   Without it the pod stays in `ContainerCreating`, as the local PV's path
   does not exist.

3. **ArgoCD may use the chart repository.** The AppProject is applied by
   Ansible, not ArgoCD. After adding the repository to
   `argo-cd/argo-project.yaml`, apply it with:

   ```bash
   ansible-playbook pb_all.yml --tags cluster
   ```

4. **The NAS export allows the node** to mount the media path. A host install
   that mounts the export already proves that; a subdirectory of an NFSv4
   export mounts the same way. To check from the cluster, run the throwaway
   pod in {doc}`nas-setup`, pinned to the node, with your media path.

## Trial

In a trial (`jellyfin.trial: true`, `jellyfin.seed_from_host: false`,
`jellyfin.host_network: false`) the pod has no host networking. It is reached
only through its ClusterIP Service, so it cannot clash with a host install listening on 8096 and 7359.

Its config starts empty and is throwaway. It is written to the real config
volume, and an init container marks it with a file
`TRIAL-CONFIG-SAFE-TO-DELETE` at the volume's root, so the seed can clear it
without any hand edits on the node (see
[Seed from a host install](#seed-from-a-host-install)). The init
container writes the marker only when the volume is empty or already marked,
so turning the trial back on later (for example by reverting the cutover)
never marks real data as throwaway.

### Reach it

```bash
kubectl -n jellyfin port-forward svc/jellyfin 8097:8096
```

Then open <http://localhost:8097>, complete the setup wizard with a throwaway
admin account, and add a library under the media mount path, for example
`/media/bigdisk/media/movies`.

### Check hardware transcoding

1. In **Dashboard › Playback › Transcoding**, set **Hardware acceleration**
   to **Video Acceleration API (VAAPI)** and **VA-API Device** to
   `/dev/dri/renderD128`. Enable hardware decoding for the codecs your GPU
   supports, and save.
2. Play a file and force a transcode: in the player's settings pick a lower
   **Quality** (bitrate) than the file's.
3. **Dashboard › Activity** (or the active session on the Dashboard home)
   shows the playback as transcoding. Its FFmpeg log, under
   `/var/log/jellyfin/FFmpeg.Transcode-*.log` in the pod, shows `vaapi` in the
   command line and no error opening the device.
4. Query the GPU from inside the pod with the `vainfo` bundled in the image:

   ```bash
   kubectl -n jellyfin exec deploy/jellyfin -- ls -l /dev/dri
   kubectl -n jellyfin exec deploy/jellyfin -- \
     /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128
   ```

   It should list the iHD driver and its `VAProfile…` entrypoints. A
   `permission denied` means `jellyfin.render_gid` does not match the node's
   `render` group; no `/dev/dri` at all means the pod did not get the
   `gpu.intel.com/i915` resource.

### End a trial

To remove it, set `enable_jellyfin: false` and push. ArgoCD deletes the pod,
Service and media volume. The config claim is kept (`Prune=false,Delete=false`),
and the volume's data on the node is never deleted by ArgoCD.

## Seed from a host install

With `jellyfin.seed_from_host: true`, two init containers copy a **stopped**
host install into the config volume before Jellyfin starts. They mount the
host's data and config directories (`jellyfin.data_dir`,
`jellyfin.config_dir`) as read-only `hostPath`s, so the host copy is never
written. Both run as the pod's uid (the host files' owner) with no
capabilities; the `Recreate` strategy means the old pod has stopped before
they run.

Markers at the volume's root decide what happens:

| Marker | Meaning |
|--------|---------|
| `SEEDED-FROM-HOST` | Seeded (with a timestamp): both steps do nothing, on every later start |
| `TRIAL-CONFIG-SAFE-TO-DELETE` | A trial config: the seed may clear it |
| `SEED-IN-PROGRESS` | The seed owns the volume's contents, and clears and recopies them if interrupted |
| `SEED-COPY-COMPLETE` | The copy is done, waiting for `seed-verify` |

`seed-copy` (Jellyfin image):

1. Does nothing if the volume is `SEEDED-FROM-HOST`.
2. Refuses (fails, and retries with back-off) while the host service looks
   live: something listening on port 8096 of the node, or a non-empty
   `jellyfin.db-wal` in the host's data directory. A clean stop leaves it
   empty or removes it; after an unclean stop, start and stop the host
   service once.
3. Claims the volume: clears it only if it is empty, trial-marked or already
   `SEED-IN-PROGRESS`. A volume holding anything else fails loudly and is
   never cleared.
4. Copies the host's data and config directories (`cp -a`, keeping modes
   and times) to temporary names, compares the database byte for byte and
   each tree's file count and size with the host, then renames them to
   `data/` and `config/`. Files whose group the pod is not in (`adm`, on a
   host's config directory) take the volume's group.
5. If `jellyfin.seed.hardware_decoding_codecs` is set, replaces
   `HardwareDecodingCodecs` in the **copied** `encoding.xml` with that list.

`seed-verify` (an SQLite image, `jellyfin.seed.sqlite_image`, as the
Jellyfin image has no `sqlite3`) runs `PRAGMA integrity_check` on the copied
database and only then writes `SEEDED-FROM-HOST`.

Watch it:

```bash
kubectl -n jellyfin get pods -w
kubectl -n jellyfin logs deploy/jellyfin -c seed-copy -f
kubectl -n jellyfin logs deploy/jellyfin -c seed-verify
```

About 25 GB on one node takes a few minutes. The seed is safe to leave
enabled, as it is a no-op once the volume is marked, but a later change
should set `jellyfin.seed_from_host: false`, which also drops the host
mounts.

## Cutover

The move from a host install, after a successful trial.

1. **Prepare the host install.** Remove libraries whose paths no longer exist
   (they would leave stale items and errors; this can also be done in the UI
   after the cutover). If remote clients use Tailscale, make sure the node is
   logged in to the tailnet, with key expiry disabled for it. Re-check the
   `jellyfin` account's uid and gid and the `render` group ID on the node,
   and update `jellyfin.uid`, `gid` and `render_gid` (and the
   `k8s_data_dirs` owner) to match. Note the host's Jellyfin version.
2. **Create the backup directories on the NAS**, `backups/jellyfin` and
   `backups/jellyfin/weekly` (see {doc}`nas-setup`).
3. **Stop the host service, keeping its files:**
   `sudo systemctl disable --now jellyfin`. Do not uninstall the package or
   touch its data and config directories: they are the rollback copy.
4. **Cutover change**, in git, then merge:
   - the image tag at the host's Jellyfin version or newer (a database
     cannot be opened by an older Jellyfin);
   - `jellyfin.trial: false`, `jellyfin.seed_from_host: true` and
     `jellyfin.host_network: true`.

   ArgoCD replaces the trial pod; the new pod seeds the volume (above) and
   starts Jellyfin on the node's network.
5. **Verify:** the web UI on each LAN address on port 8096, client
   auto-discovery (UDP 7359), remote clients over Tailscale, users and watch
   history, one hardware transcode, and the scheduled tasks. Then run a
   first backup by hand (see [Backups](#backups)) and check it on the NAS.
6. **Retire the seed** in a later change (`jellyfin.seed_from_host: false`).
7. **Retire the host install** after a settling period: remove the packages
   (without purging, so the old data stays as a cold copy for a while) and
   the apt source. Keep the `jellyfin` account, as it owns the files on the
   config volume.

### Rollback

The host's data and config were never written, so rollback is:

1. Set `enable_jellyfin: false` and push. ArgoCD removes the pod, which frees
   port 8096 (the config claim and the volume's data are kept).
2. On the node: `sudo systemctl enable --now jellyfin`.

The host database is as it was when the host service stopped: watch history
and changes made in the cluster are not in it.

Switching back to the cluster later reuses the volume as it is: it is
already `SEEDED-FROM-HOST`, so the seed does not copy again, and changes made
on the host since are not in it. Nothing in this repository clears a seeded
volume; recopying from the host means deliberately removing the volume's
contents on the node first.

## Backups

The `backups` Application runs two CronJobs on the node, as Jellyfin's uid
and with the config volume's directory mounted read-only:

| CronJob | Schedule (Europe/London) | NAS path | Kept |
|---------|--------------------------|----------|------|
| `jellyfin-daily` | 01:45 daily | `backups/jellyfin/<date>_<time>.tar.gz` | 7 days |
| `jellyfin-weekly` | 01:50 Sundays | `backups/jellyfin/weekly/<date>.tar.gz` | 28 days |

01:45 is after Jellyfin's default 01:00 scheduled tasks and before the kured
reboot window. Each tarball holds a consistent `sqlite3 .backup` snapshot of
the database (checked with `PRAGMA quick_check`), and from the volume
`config/`, `data/plugins/`, `data/root/` (library definitions) and
`data/data`'s `playlists/`, `ScheduledTasks/` and `*.txt`. It is laid out
like the volume, so it unpacks at the volume's root. Extracted subtitles and
metadata are not backed up: a library scan rebuilds them.

Run one now:

```bash
kubectl create job --from=cronjob/jellyfin-daily manual-$(date +%s) -n backups
kubectl logs -n backups job/manual-<timestamp> -f
```

### Restore from a backup

1. Set `enable_jellyfin: false` and push, so nothing has the database open.
2. On the node, unpack the tarball over the volume's root as the `jellyfin`
   account, for example with the NAS share mounted on the node:

   ```bash
   sudo -u jellyfin tar --no-overwrite-dir \
     -xzf <nas>/backups/jellyfin/<date>_<time>.tar.gz \
     -C /home/k8s-data/jellyfin
   sudo -u jellyfin rm -f /home/k8s-data/jellyfin/data/data/jellyfin.db-wal \
     /home/k8s-data/jellyfin/data/data/jellyfin.db-shm
   ```

   This replaces the database and the config, and leaves the subtitles and
   metadata in place. (Without the share on the node, do the same from a
   pod pinned to the node that mounts the `k8s-cluster-nfs` claim and the
   volume's directory.)
3. Set `enable_jellyfin: true` and push. If the volume was empty (a new
   node), Jellyfin rebuilds the metadata and subtitles by its next library
   scan.
