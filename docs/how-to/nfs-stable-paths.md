# Stable NFS volumes

The NFS CSI driver (the `nfs-csi` ArgoCD app) provides two storage classes
on the same export of the NAS (192.168.1.3). This page is how to work with
them; where they sit among the cluster's other storage is in
{doc}`/explanations/architecture/storage`.

| Class | Set by (`kubernetes-services/values.yaml`) | Folder per PVC | On PVC delete | Used by |
|-------|-------|----------------|---------------|---------|
| `nfs-stable` (default) | `nfs_csi.stable_storage_class`, share `nfs_csi.stable_share` (`/k8s-dynamic/stable`) | `<namespace>/<pvc>` | folder archived | every claim that names no class: today the Minecraft worlds |
| `nfs-rwx` | `nfs_csi.fresh_storage_class`, share `nfs_csi.share` (`/k8s-dynamic`) | `<namespace>/<pvc>-<pv>` | data deleted | scratch volumes that name it: none today |

Both have reclaim policy `Delete`, bind at once and mount with NFS 4.1; what
differs is the folder name and what the driver does on delete
(`onDelete: archive` against `delete`).

In the `nfs-stable` share the folders look like this:

```text
/k8s-dynamic/stable/<namespace>/<pvc>             live data
/k8s-dynamic/stable/archived-<namespace>/<pvc>    data of a deleted PVC
```

For example, the world `science-lab` is the PVC `minecraft/science-lab-data`
and lives in `/k8s-dynamic/stable/minecraft/science-lab-data`.

Because the folder depends only on the PVC's namespace and name, a PVC
re-created with the same name finds its data again. That is what carries
volumes across a cluster rebuild: the rebuild wipes etcd, so every PV and PVC
object goes, but the folders stay on the NAS, and the re-created PVCs bind to
them. The Minecraft dashboard, for example, re-creates its worlds from its
registry on the store ({doc}`/how-to/minecraft`).

A new claim with no `storageClassName` gets `nfs-stable`. Name `nfs-rwx`
explicitly for a scratch volume that must start empty on every deploy: on
`nfs-stable` a PVC re-created under the same name gets the old data back.
Existing claims keep the class they were made with (`storageClassName` is
immutable), so changing the default moves no data.

**A second cluster would need its own stable share and its own Minecraft
store.** Two clusters sharing either would see each other's worlds: the same
`minecraft/<world>-data` folders, and each other's registry to restore from.

## Creating the share

The share root (`nfs_csi.stable_share`, `/k8s-dynamic/stable`) is not
created by the cluster. It is made once on the NAS, by hand, before ArgoCD
syncs the class: the driver cannot provision into a missing share, and the
dashboard, which mounts the share read-only, cannot start. See
{ref}`nfs-csi-nas-share`.

Keep the stable share a folder of `nfs_csi.share`, on the same export and
the same filesystem (not a separate dataset or volume mounted inside it):
`scripts/nfs-stable-paths` (below) moves a volume between the classes by
renaming its folder, which only works within one filesystem. The script
checks this and stops before the rename if the two folders are on different
filesystems.

## Deleting an `nfs-stable` PVC

Deleting an `nfs-stable` PVC never deletes data: the driver
(`onDelete: archive`) moves the folder to
`/k8s-dynamic/stable/archived-<namespace>/<pvc>`. A new PVC with the same name then
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
   then `kubectl delete pv <pv>`. (A dynamically provisioned PV is not an
   ArgoCD-managed resource, so this is not a change behind ArgoCD's back.)
3. On the NAS, deal with both folders by hand (keep, merge or delete).

Do not clear an archive while a PV of that name is stuck. The retried delete
would then succeed and archive the folder, even if a new PVC is now using it.

## Worlds made before `nfs-stable`

The Minecraft worlds made before the class existed had their PVCs on
`nfs-rwx`, in `/k8s-dynamic/minecraft/<world>-data-<pv-name>`, where a
rebuild would have left them behind. They have all been moved: every claim
in the cluster is now on `nfs-stable` (`kubectl get pvc -A` shows no
`nfs-rwx` claim), so there is nothing left to migrate.

The tool that moved them, `scripts/nfs-stable-paths`, stays in the
repository for a world restored onto `nfs-rwx` by an old manifest. What it
does, one world at a time:

- it moves only Minecraft world PVCs (`minecraft/<world>-data`) and refuses
  any other, or a PV whose server, share or folder is not the `nfs-rwx` one
  in `kubernetes-services/values.yaml`;
- with no arguments, or with PVC names, it is a dry run that lists each
  world, its old and new folder, and any pod still referencing the PVC;
  `--apply minecraft/<world>-data` does the move, and needs the worlds named;
- it sets the PV to `Retain`, renames the folder into the stable share (a
  rename on the NAS, not a copy), re-creates the PVC under the same name in
  `nfs-stable`, and checks that the new volume holds the same number of
  files. The world must be stopped in the dashboard first; the script checks
  that before the rename and again before it deletes the PVC;
- it saves each PVC and PV manifest in `~/nfs-stable-paths-<time>/` first.
  If it stops part-way it says where. Before the PVC is deleted, a re-run
  carries on (it sees a folder already renamed). After that a re-run cannot
  help, as it starts from a bound `nfs-rwx` PVC: delete the old PV if it is
  left `Released` (it is `Retain`, so nothing on the NAS changes), then
  re-create the PVC with
  `kubectl create -f ~/nfs-stable-paths-<time>/minecraft.<pvc>.pvc.new.json`,
  which the class provisions in the moved folder.

### Undoing a move

The saved manifests make a move reversible:

1. Stop the world.
2. Set the new PV to `Retain`, so that deleting its PVC does not archive the
   folder, then delete the PVC and the PV:

   ```bash
   kubectl patch pv <new-pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
   kubectl delete pvc -n minecraft <pvc>
   kubectl delete pv <new-pv>
   ```

3. On the NAS, rename `/k8s-dynamic/stable/minecraft/<pvc>` back to
   `/k8s-dynamic/minecraft/<pvc>-<old-pv>`.
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
