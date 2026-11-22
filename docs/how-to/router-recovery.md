# Back up and recover the router

The home router is a MikroTik hEX S (RouterBOARD 760iGS, MediaTek MT7621)
running OpenWrt 23.05.5, at 192.168.1.1 (`dns_router` in
`group_vars/all.yml`). It carries every household device's traffic and
DNS, not only the cluster's. This page covers its daily backup, restoring
it with a playbook, and getting it back when SSH to it is gone.

A backup is a `sysupgrade -b` tarball: everything under `/etc/config/`,
`/etc/passwd`, `/etc/shadow` (the root password hash), the Dropbear host
keys and `authorized_keys`, the LuCI TLS key, and the PPPoE login of the
WAN in `/etc/config/network`. (The hEX S has no Wi-Fi radio, so there are
no Wi-Fi keys.) It is only ever stored encrypted, and **never goes in the
repository**, decrypted or not.

## How the backup runs

The `etcd_backup` role installs a second timer next to the etcd backup on
the control plane (node02), `router-backup.timer`. Every day at 23:00
Europe/London it:

1. connects to the router as `root` with its own SSH key,
   `/etc/k3s-etcd-backup/router_ed25519`, which never leaves node02. The
   router accepts that key for one command only: its line in
   `/etc/dropbear/authorized_keys` (Dropbear does not read `/root/.ssh`)
   starts `command="sysupgrade -b -",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty`,
   so whatever node02 asks for, the router runs `sysupgrade -b -`. The
   router's host key is pinned in `/etc/k3s-etcd-backup/router_known_hosts`;
   the role reads it from the router over the connection Ansible already
   trusts;
2. holds the tarball in RAM (`/run`), checks it lists `etc/config/network`,
   and encrypts it with age to `etcd_backup_age_recipient`, the key every
   backup uses;
3. copies it to the NAS as
   `/bigdisk/k8s-cluster/backups/router/router-<UTC time>.tar.gz.age`,
   checks the copy's checksum, and keeps the newest 30;
4. writes `router_backup_*` metrics for node-exporter.

The two jobs share a lock, so they never use the NAS mount at once. The
off-site jobs copy `backups/router/` to Google Drive and B2 each morning
with the rest of `backups/` ({ref}`offsite-backup`). The alerts
`RouterBackupFailed`, `RouterBackupStale`, `RouterBackupNeverSucceeded`
and `RouterBackupMetricsMissing` (`additions/grafana/router-backup-rules.yaml`)
reach the phone through ntfy.

The role authorizes the key on the router with `raw` (the router has no
Python), adding the line only if it is missing. If the control plane
moves, or is re-flashed (a new key), the old line stays, still limited to
`sysupgrade -b` and harmless; delete it by hand if you like
({doc}`/how-to/recover-control-plane`).

### Set it up

Done once, and again only on a new NAS or a new control plane:

```bash
ansible-playbook pb_nas.yml --tags nas_datasets   # creates backups/router, owned by 65534
ansible-playbook pb_all.yml --limit node02 --tags etcd_backup
just router-backup
```

### Back up now

Run this **before every change to the router**:

```bash
just router-backup
```

It starts the same service on the control plane, waits for it and prints
its log and metrics. To list the backups:

```bash
ssh nas sudo ls -l /bigdisk/k8s-cluster/backups/router
```

## Restore with the playbook

For a router that still answers SSH, e.g. after a bad change.

1. Copy the backup off the NAS and decrypt it with the offline age key
   (where it is kept: {ref}`decrypt-router-backup` below):

   ```bash
   f=$(ssh nas sudo ls /bigdisk/k8s-cluster/backups/router | grep '\.age$' | tail -n 1)
   ssh nas sudo cat "/bigdisk/k8s-cluster/backups/router/$f" > "$f"
   (umask 077; age -d -i ~/k3s-etcd-backup.agekey "$f" > /dev/shm/router.tar.gz)
   ```

2. Restore it:

   ```bash
   ansible-playbook pb_router.yml --tags restore -e router_restore_file=/dev/shm/router.tar.gz
   ```

   The playbook runs on the controller with your own ssh to `dns_router`,
   the same way `just k3s-api-dns` does. It lists the files in the backup
   and asks you to type `yes` (anything else stops it), then pipes the file to
   `sysupgrade -r -` on the router (no scp or copy in `/tmp` needed),
   reboots the router and waits for its SSH to come back. The internet is
   down for everyone for a minute or two.

3. Delete `/dev/shm/router.tar.gz`.

The backup holds the router's own host keys and `authorized_keys`, so SSH
works afterwards as before.

A restore only unpacks the tarball over `/`: files added since the backup
(a new `/etc/nftables.d/*.nft` or `/etc/config/*`) stay. To undo a bad
change that added files, reset the saved configuration first with
`firstboot -y` and a reboot (as in failsafe, below), then restore.

An older backup also brings back its `authorized_keys`. If the control
plane has been rebuilt since, its backup key is not in them: rerun
`ansible-playbook pb_all.yml --limit node02 --tags etcd_backup` afterwards
to authorize it again.

## When SSH to the router is gone

When a bad firewall, network or Dropbear change locks everyone out, use
OpenWrt's **failsafe mode**: a boot that ignores the saved configuration,
brings up only the first LAN port at 192.168.1.1, and runs SSH with no
password. Nothing in it needs the internet, but this does need a laptop
with `ssh`, `age` and the age key, and a network cable.

### 1. Get the backup and the key while you can

Do this first: once the laptop is cabled to the router alone, it reaches
nothing else.

- **The newest backup** is on the NAS (gknas, 192.168.1.3), in
  `/bigdisk/k8s-cluster/backups/router/`, `0600` to `65534`, so it needs
  `sudo`. With the router down there is no DHCP: give the laptop a static
  address on the LAN, e.g. 192.168.1.250/24, then copy it as in the
  playbook restore above. Whether the NAS answers depends on what broke:
  the router's LAN bridge, or a switch between the laptop and the NAS, still
  carries the traffic if only the router's own services are gone.
- **If the NAS cannot be reached**, the same files are off site, which
  needs the internet (a phone's hotspot): Google Drive
  `home-cluster-offsite/backups/router/`, or the B2 bucket
  `gk-cluster-offsite/backups/router/` ({ref}`offsite-b2`). The files are
  as on the NAS (already `.age`, uploaded as they are).
- **An older backup**, if the newest already holds the bad change: they are
  named by UTC time, newest last; pick the one from before it.

(decrypt-router-backup)=
### 2. Decrypt it

The age private key is offline, not on the cluster: the owner's
`~/k3s-etcd-backup.agekey`, kept in two places
({doc}`/how-to/backup-restore`, "One-time setup"), and the first page of
the paper kit ({doc}`/how-to/paper-kit`), which can be typed into
`key.txt` (`age-keygen -y key.txt` must print
`etcd_backup_age_recipient`). The laptop needs `age` already installed:
with the internet down it cannot fetch it (the devcontainer has it).

```bash
(umask 077; age -d -i ~/k3s-etcd-backup.agekey router-<time>.tar.gz.age > /dev/shm/router.tar.gz)
tar -tzf /dev/shm/router.tar.gz   # etc/config/network, etc/shadow, ...
```

### 3. Boot the router into failsafe mode

The hEX S has two LEDs besides the port lights: the blue power LED, which
OpenWrt uses for boot and failsafe, and a blue SFP link LED. It has two
buttons, `reset` and `mode`. During boot OpenWrt waits 2 seconds for a button press; any
button press then enters failsafe.

1. Set the laptop to the static address 192.168.1.2/24 (no gateway) and
   cable it to **port 2** of the router, the first LAN port: failsafe brings
   up only that one (port 1 is the WAN; ports 3 to 5 stay off). Unplug
   whatever else was in port 2.
2. Pull the router's power, and plug it back in. **Do not hold reset while
   plugging in**: before OpenWrt starts, the button belongs to MikroTik's
   RouterBOOT bootloader, which uses a press at power-on to boot its
   backup loader or to wait for a Netinstall over the network instead of
   starting OpenWrt. (What RouterBOOT does on this exact board with each
   hold time is not verified here; avoid it.)
3. Watch the power LED. When OpenWrt's preinit starts it blinks fast (about
   5 times a second): **press and release reset** then, within 2 seconds.
   Pressing it a few times during the fast blinking is fine.
4. In failsafe the LED blinks faster still (about 10 times a second) and
   keeps blinking. If it settles into a slower blink (about 2.5 times a
   second), the window was missed and the router is booting normally: go
   back to step 2.

Once the router is up normally, do not hold reset for 5 seconds or more:
on release that is a factory reset (`/etc/rc.button/reset` runs
`jffs2reset`). A short press reboots it.

### 4. Restore from failsafe

Failsafe makes new host keys in RAM and has no root password, so skip the
known_hosts check for this session only:

```bash
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@192.168.1.1 \
    'cat > /tmp/router.tar.gz' < /dev/shm/router.tar.gz
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@192.168.1.1
```

On the router:

```sh
mount_root                         # mount the saved configuration (the overlay) read-write
sysupgrade -r /tmp/router.tar.gz   # unpacks the backup over /
sync
reboot -f
```

`sysupgrade -r` only unpacks the tarball over `/`, as
`tar -C / -xzf /tmp/router.tar.gz` would, so files added since the backup
stay (see "Restore with the playbook"; `firstboot -y` below clears them).
As there, an older backup may need the control plane's backup key
authorized again. The router boots with the
restored configuration, its own host keys and `authorized_keys`; set the
laptop back to DHCP and check the internet, DNS (`k3s.lan` resolves) and
`ssh root@192.168.1.1`.

If the router still does not come up right (the overlay itself is damaged,
or the backup holds the fault), go back into failsafe and reset to defaults
instead, then restore an older backup:

```sh
firstboot -y    # erases the saved configuration: OpenWrt defaults, 192.168.1.1, no root password
reboot -f
```

After that reboot the router has OpenWrt's default configuration: LAN on
ports 2 to 5 at 192.168.1.1 with DHCP, no WAN login, no root password and
new host keys. Restore an older backup into it with the same two `ssh`
commands as above, without `mount_root`, then `reboot`; or upload it in
LuCI (`http://192.168.1.1`), **System > Backup / Flash Firmware >
Restore backup**.

Delete `/dev/shm/router.tar.gz` when done, and run `just router-backup`
once the cluster is back.
