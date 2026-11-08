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
| `/config`: database, metadata, subtitles, plugins, XML config | Static `local-nvme` PV on the node (`local_storage.jellyfin`), claim `jellyfin-config` | Created by the `k8s_data_dirs` role, owned by the pod's uid/gid. Not NFS: the database is SQLite |
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

The media is mounted at the same path the host install used (for example
`/media/bigdisk/media`), so the library paths in an imported database match.
The chart's own `/media` and `/cache` volumes are unused.

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

In a trial (`jellyfin.trial: true`, `jellyfin.host_network: false`) the pod
has no host networking. It is reached only through its ClusterIP Service, so
it cannot clash with a host install listening on 8096 and 7359.

Its config starts empty and is throwaway. It is written to the real config
volume, and an init container marks it with a file
`TRIAL-CONFIG-SAFE-TO-DELETE` at the volume's root, so the cutover can clear
it without any hand edits on the node (see [Cutover](#cutover)). The init
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
   `/config/log/FFmpeg.Transcode-*.log` in the pod, shows `vaapi` in the
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

## Cutover

An outline of the move from a host install; each step is its own change.

1. **Prepare the host install.** Remove libraries whose paths no longer exist
   (they would leave stale items and errors). If remote clients use
   Tailscale, make sure the node is logged in to the tailnet, with key expiry
   disabled for it. Re-check the `jellyfin` account's uid and gid and the
   `render` group ID on the node, and update `jellyfin.uid`, `gid` and
   `render_gid` (and the `k8s_data_dirs` owner) to match.
2. **Stop the host service, keeping its files:**
   `sudo systemctl disable --now jellyfin`. Do not uninstall the package or
   touch its data and config directories yet: they are the rollback copy.
3. **Cutover change**, in git:
   - stop the trial pod first: the Job mounts the same volume on the same
     node, and must not run while Jellyfin has the database open. Either set
     `enable_jellyfin: false` and let ArgoCD remove the trial (the config
     claim and its data are kept) before the cutover change, or have the Job
     wait until no Jellyfin pod is running in the namespace;
   - set the image tag to the host's Jellyfin version or newer (a database
     cannot be opened by an older Jellyfin);
   - set `jellyfin.trial: false` and `jellyfin.host_network: true`;
   - add a one-off Job (an ArgoCD sync hook, before the Deployment) that runs
     on the node with the host's data and config directories mounted
     read-only, and the config volume read-write. It:
     - empties the volume **only if** `TRIAL-CONFIG-SAFE-TO-DELETE` is at its
       root, then removes the marker. It refuses to wipe, and fails, if
       `SEEDED-FROM-HOST` is also there (see below): that is real data. (A
       database newer than the marker is no sign of real data, since a trial
       writes its database after every start.);
     - copies the host data **only if** the volume has no database yet,
       mapping the host's layout onto the image's: the data directory (for
       example `/var/lib/jellyfin`) to `/config`, and the config directory
       (for example `/etc/jellyfin`) to `/config/config`;
     - checks the copied database with `PRAGMA integrity_check`, then
       writes `SEEDED-FROM-HOST` at the volume's root.

   The media paths are unchanged, so the libraries need no remapping. Check
   the copied config for any remaining absolute paths under the old data
   directory, and fix them in the Job or by a library rescan.
4. **Verify:** the web UI on each LAN address on port 8096, client
   auto-discovery (UDP 7359), remote clients over Tailscale, users and watch
   history, one hardware transcode, and the scheduled tasks.
5. **Backups:** a nightly CronJob copying the database (`sqlite3 .backup`)
   and the config to the NAS. Extracted subtitles and metadata stay on the
   volume but are not backed up: a rescan rebuilds them.
6. **Retire the host install** after a settling period: remove the packages
   (without purging, so the old data stays as a cold copy for a while) and
   the apt source. Keep the `jellyfin` account, as it owns the files on the
   config volume.

**Rollback** at any point: set `enable_jellyfin: false`, then
`sudo systemctl enable --now jellyfin` on the host. The host database is as it
was at step 2.
