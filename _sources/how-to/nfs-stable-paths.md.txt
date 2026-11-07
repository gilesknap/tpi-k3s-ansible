# Stable NFS Volumes

The cluster has two NFS CSI storage classes on the same NAS export:

| Class | Value | Folder per PVC | On PVC delete | Used by |
|-------|-------|----------------|---------------|---------|
| `nfs-stable` (default) | `nfs_csi.stable_storage_class`, share `nfs_csi.stable_share` | `<namespace>/<pvc>` | folder archived | every claim that names no class; Minecraft worlds |
| `nfs-rwx` | `nfs_csi.fresh_storage_class`, share `nfs_csi.share` | `<namespace>/<pvc>-<pv>` | data deleted | scratch volumes that name it; claims made before `nfs-stable` was the default |

In the `nfs-stable` share the folders look like this:

```text
<stable_share>/<namespace>/<pvc>             live data
<stable_share>/archived-<namespace>/<pvc>    data of a deleted PVC
```

Because the folder depends only on the PVC's namespace and name, a PVC
re-created with the same name finds its data again. That is what carries
volumes across a cluster rebuild: the rebuild wipes etcd, so every PV and PVC
object goes, but the folders stay on the NAS, and the re-created PVCs bind to
them. The Minecraft dashboard, for example, re-creates its worlds from its
registry on the store ({doc}`minecraft`).

A new claim with no `storageClassName` gets `nfs-stable`. Name `nfs-rwx`
explicitly for a scratch volume that must start empty on every deploy: on
`nfs-stable` a PVC re-created under the same name gets the old data back.
Existing claims keep the class they were made with (`storageClassName` is
immutable), so changing the default moves no data.

**Each cluster needs its own stable share and its own Minecraft store.** Two
clusters sharing either would see each other's worlds: the same
`minecraft/<world>-data` folders, and each other's registry to restore from.

## Creating the share

The share root (`nfs_csi.stable_share`, default `/k8s-dynamic/stable`) is
not created by the cluster. Create it once on the NAS before Argo CD syncs
the class: the driver cannot provision into a missing share, and the
dashboard, which mounts the share read-only, cannot start. See
{ref}`nfs-csi-nas-share`.

Keep the stable share a folder of `nfs_csi.share`, on the same export and
the same filesystem (not a separate dataset or volume mounted inside it):
the migration below moves old worlds by renaming their folders, which only
works within one filesystem. The script checks this and stops before the
rename if the old and new folders are on different filesystems.

## Deleting an `nfs-stable` PVC

Deleting an `nfs-stable` PVC never deletes data: the driver
(`onDelete: archive`) moves the folder to
`<stable_share>/archived-<namespace>/<pvc>`. A new PVC with the same name then
starts empty. Clear archives on the NAS when you no longer need them, and
always clear the old archive before deleting a PVC whose name was used before.

The driver keeps only one archive per name, and it does not overwrite one. If
a PVC is deleted while an archive of the same name still exists, the second
archive fails. The PV then stays `Released`, the driver retries its delete,
and the folder stays where it is, so a third PVC of that name would bind to
the second one's data. The Minecraft dashboard refuses to create a world
whose name still has an archive; other workloads have no such guard. To
recover:

1. Find the stuck PV: `kubectl get pv | grep Released`.
2. Stop it from retrying:
   `kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`,
   then `kubectl delete pv <pv>`.
3. On the NAS, deal with both folders by hand (keep, merge or delete).

Do not clear an archive while a PV of that name is stuck. The retried delete
would then succeed and archive the folder, even if a new PVC is now using it.

## Moving worlds made before `nfs-stable`

Worlds created before the class have their PVCs on `nfs-rwx`, in
`<share>/minecraft/<world>-data-<pv-name>`, with the delete policy that
deletes the data with the PVC. They work as before, but a rebuild leaves
them behind. `scripts/nfs-stable-paths` moves them, one world at a time: it
sets the PV to `Retain`, renames the folder into the stable share on the NAS
(a rename, not a copy), re-creates the PVC under the same name in
`nfs-stable` and checks that the new volume holds the same files. It checks
that the world is not running just before the rename, and again just before
it deletes the PVC. It saves each PVC and PV manifest in
`~/nfs-stable-paths-<time>/` first.

The script moves only Minecraft world PVCs (`minecraft/<world>-data`, made
by the dashboard). It refuses any other PVC; those stay on `nfs-rwx`. It
reads the expected server, shares and class names from
`kubernetes-services/values.yaml`, and refuses a PV whose server, share or
folder is not the expected `nfs-rwx` one.

1. Make sure the class is live:

   ```bash
   kubectl get storageclass nfs-stable -o jsonpath='{.parameters.share} {.parameters.subDir} {.parameters.onDelete}{"\n"}'
   # /k8s-dynamic/stable ${pvc.metadata.namespace}/${pvc.metadata.name} archive
   ```

2. Dry run. It changes nothing and lists each world PVC, its old and new
   folder, and any pod that references it, in any phase. A `Succeeded` or
   `Failed` pod blocks the move too (pvc-protection holds the PVC while it
   exists): save its spec with `kubectl get pod -o yaml`, then delete it.

   ```bash
   scripts/nfs-stable-paths                          # every world
   scripts/nfs-stable-paths minecraft/<world>-data   # chosen worlds
   ```

3. For each world:
   1. Running world: **Stop** it in the dashboard and wait until it shows
      stopped. A world already stopped needs nothing.
   2. `scripts/nfs-stable-paths --apply minecraft/<world>-data`. `--apply`
      needs the worlds named. Use nothing on the dashboard for that world
      meanwhile; a snapshot or start would need the PVC.
   3. **Start** it again if it was running.
4. Verify: a final dry run lists every world as `stable` and `0 to move`.

Expect 2 to 5 minutes per running world: about 20 s to stop, under a minute
to move (mostly two short Jobs), and 1 to 2 minutes to start a vanilla
world, or a few minutes for a modded one. A stopped world has no downtime.

Finish the move before the next rebuild. A rebuild brings the moved worlds
back with their data. A world not yet moved is not restored, because its
folder is not in the stable share; its data stays in the old `nfs-rwx`
folder.

### If the script stops part-way

It says where it stopped:

- **Before the PVC is deleted:** the folder may already be renamed while
  the old PV still points at the old name. Re-run the script: the rename step
  sees the folder is already moved and carries on.
- **Between the PVC and PV delete:** the old PV is left `Released`, with
  reclaim policy `Retain`, pointing at a folder that is no longer there.
  Delete it with `kubectl delete pv <pv>`: with `Retain`, nothing on the NAS
  changes. Then re-create the PVC as below.
- **After the PVC is deleted:** a re-run cannot help, because the script
  starts from a bound `nfs-rwx` PVC. Finish by hand:

  1. Re-create the PVC from the saved copy, unless the script already did
     (`kubectl get pvc -n minecraft <pvc>` shows class `nfs-stable`):

     ```bash
     kubectl create -f ~/nfs-stable-paths-<time>/minecraft.<pvc>.pvc.new.json
     ```

     The class provisions it in the moved folder.
  2. Wait for it to bind, and check its PV points at the moved folder:

     ```bash
     kubectl wait pvc -n minecraft <pvc> --for=jsonpath='{.status.phase}'=Bound
     kubectl get pv "$(kubectl get pvc -n minecraft <pvc> -o jsonpath='{.spec.volumeName}')" \
       -o jsonpath='{.spec.csi.volumeAttributes.share} {.spec.csi.volumeAttributes.subDir}{"\n"}'
     # /k8s-dynamic/stable minecraft/<pvc>
     ```

  3. Compare the file counts by hand. The rename Job's log keeps its
     `entries=<n>` line for 24 hours, until the Job is cleaned up:

     ```bash
     kubectl get jobs -n minecraft -l app.kubernetes.io/name=nfs-stable-paths
     kubectl logs -n minecraft job/<nfs-mv-job> | grep entries=
     ```

     On the NAS, count the moved folder the same way; the two numbers must
     match:

     ```bash
     # the stable share's folder on the NAS, e.g. /share/CACHEDEV1_DATA/k8s-dynamic/stable
     find <stable-folder>/minecraft/<pvc> | wc -l
     ```

     If they differ, or the Job is gone, check the folder's contents by hand
     before starting the world.

### Undoing one world

1. Stop the world.
2. Set the new PV to `Retain`, so deleting its PVC does not archive the
   folder, then delete the PVC and the PV:

   ```bash
   kubectl patch pv <new-pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
   kubectl delete pvc -n minecraft <pvc>
   kubectl delete pv <new-pv>
   ```

3. On the NAS, rename `<stable_share>/minecraft/<pvc>` back to
   `<share>/minecraft/<pvc>-<old-pv>`.
4. Re-create the old PV and PVC from the saved copies. The saved `.pv.json`
   was taken before the script set `Retain`, so it still says `Delete`: set
   `Retain`, and strip the fields the API server owns:

   ```bash
   cd ~/nfs-stable-paths-<time>
   jq '.spec.persistentVolumeReclaimPolicy = "Retain"
       | del(.metadata.creationTimestamp, .metadata.uid, .metadata.resourceVersion,
             .spec.claimRef.uid, .spec.claimRef.resourceVersion, .status)' \
     minecraft.<pvc>.pv.json | kubectl create -f -
   jq 'del(.metadata.creationTimestamp, .metadata.uid, .metadata.resourceVersion,
           .status)' \
     minecraft.<pvc>.pvc.json | kubectl create -f -
   ```

   The PVC keeps its `volumeName` and class `nfs-rwx`, so it binds to the
   old PV.
