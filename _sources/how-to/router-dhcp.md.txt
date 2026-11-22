# Manage the router's DNS and DHCP

The router (OpenWrt at 192.168.1.1, {doc}`/how-to/router-recovery`) hands
out the LAN's addresses and answers its DNS with dnsmasq. Its whole
`/etc/config/dhcp` is code: the template
`roles/router/templates/dhcp.j2`, filled from `hosts.yml` and
`group_vars/all.yml`. Change those, preview the diff, and push it with
confirm-or-revert. Don't edit the router's copy in LuCI or with `uci`: the
next push puts the template's version back.

In the Claude sandbox add
`--private-key /root/.config/claude-ssh/id_ed25519` to the commands on this
page (`just router-dhcp` passes it on).

## What the file holds

| Section | Comes from |
|---------|------------|
| `config dnsmasq`: OpenWrt's defaults (`domain 'lan'`, `rebind_protection`, a 1000-entry cache, ...) | The template itself |
| `list server`: the upstream DNS servers, 1.1.1.1 and 1.0.0.1 | `router_dns_servers` in `group_vars/all.yml` |
| `list rebind_domain 'gkcluster.org'`: the cluster's public names may answer with LAN addresses, which rebind protection would otherwise drop | `cluster_domain` |
| `config dhcp 'lan'` and `'wan'`, `config odhcpd`: the DHCPv4 pool (.100 to .249, 12 h leases), IPv6 RA and DHCPv6 | The template itself |
| `config host` by name: node02, node03, node04, ws03, nuc1, nuc2 and gknas | `lan_ip` of each host in `hosts.yml` |
| `config host` by MAC: turingpi (the BMC), node01, GX7050, GoogleTV, pi1 to pi4 and two unnamed devices | `router_dhcp_hosts` in `group_vars/all.yml` |
| `config domain`: `k3s.lan` | `k3s_api_name`, pointing at `control_plane`'s `lan_ip` (node02, 192.168.1.82) |

### Reserved by name, or by MAC

A host in `hosts.yml` with a `lan_ip` gets a reservation with a name and an
address but no MAC. OpenWrt turns that into `--dhcp-host=node02,192.168.1.82`,
which dnsmasq matches on the hostname the client sends with its DHCP
request. The cluster's machines send theirs: the flash role (cloud-init) and
the install stick set it from `hosts.yml`, and systemd-networkd and
NetworkManager send it by default. So a replacement board or a new NIC gets
the same address with no router change, as long as the new machine is
installed under the inventory name, and once the old machine's lease has
gone (see "Replace a machine" below).

The trade-off: any device on the LAN that asks with a node's hostname gets
the node's address, as a device that copies a MAC does with a MAC
reservation. Don't run an old and a new board with the same name at once:
whichever asks second gets an address from the pool. For the same reason,
cable only one of the NAS's two ports.

Devices whose hostname this repo doesn't set (the Turing Pi BMC, the
Raspberry Pis, the TV and the rest) are matched by MAC, in
`router_dhcp_hosts`. An entry there has:

- `name`: optional; served as `<name>.lan`. The two entries without one
  (192.168.1.195 and 192.168.1.141) are marked `# unnamed`: give them
  names once you know what they are.
- `ip`: the address it always gets.
- `macs`: a list, in lower case; the template writes them in upper case,
  as LuCI does.

Every reservation has `option dns '1'`, so the router serves `<name>.lan`
from its configuration whether or not the device holds a lease. Without
it, a name lived only in the lease file (`/tmp/dhcp.leases`, in RAM), so
after a router reboot `node02.lan` and the rest failed to resolve until
each device renewed its lease, up to six hours later.

The file starts with a comment that says it is generated. `uci commit` and
LuCI rewrite the file without comments, so after any change made on the
router the preview shows at least that comment coming back.

## Preview

```bash
ansible-playbook pb_router.yml --tags dhcp-diff
```

It reads the router's `/etc/config/dhcp`, renders the template on the
controller and prints a unified diff (the router's copy first). It changes
nothing and arms nothing. "No difference" means the router already has
this configuration.

## Apply

```bash
just router-dhcp
```

It runs the preview, asks `Apply this to the router, with
confirm-or-revert? [y/N]`, and on `y` runs

```bash
ansible-playbook pb_router.yml --tags change -e router_change_tasks=dhcp
```

That backs the router up to the NAS and arms the revert (as in
{doc}`/how-to/router-recovery`, "Change the router safely"), then runs
`roles/router/tasks/dhcp.yml`: it renders and compares again and, only if
the files differ, writes the new file beside the old and renames it over
`/etc/config/dhcp`, then reloads dnsmasq and odhcpd. dnsmasq restarts if
its generated configuration changed (any reservation, its name included,
or an option); a change to `k3s.lan` alone only makes it reread its hosts
files. DNS pauses for a moment either way. With no difference it pushes
and reloads nothing.

The checks then decide. Besides the internet, a public name, `k3s.lan`,
the cluster API and SSH, they ask the router for `node02.lan`
(`control_plane` plus `router_dns_domain`), and expect node02's `lan_ip`
for both, so a configuration that stops dnsmasq or loses the static names
fails, and the router reverts. They reach node02 at its `lan_ip`, never by
a name the router serves, so they still work while its DNS is broken.

A device moves to a new reservation only when it next renews its lease
(halfway through the 12 hours) or reconnects. The guard cannot see a host
that does not send its hostname until then: after the first push, which
moves the nodes from MAC to name, check each one keeps its address once it
has renewed. `ssh root@192.168.1.1 cat /tmp/dhcp.leases` lists each lease's
address. Its name is the one the client sent for a reservation by name, and
the reservation's own for one by MAC, so check the address.

Make this first push before any `--tags drill`
({doc}`/how-to/router-recovery`): until then the router's reboot loses the
`.lan` names, and the `<control_plane>.lan` check fails for hours although
the guard worked.

## Add a device

**A cluster node or another host in `hosts.yml`:** give it `lan_ip` (an
address outside the pool: .2 to .99, or .250 to .254, not already used)
and push. Its hostname must be its inventory name. The rest of the
node checklist is in {doc}`/reference/inventory`.

**Anything else:**

1. Find its MAC: in LuCI under **Status > Overview**, "Active DHCP Leases",
   or with `ssh root@192.168.1.1 cat /tmp/dhcp.leases`.
2. Add an entry to `router_dhcp_hosts` in `group_vars/all.yml`, with a free
   address outside the pool:

   ```yaml
   - {name: printer, ip: 192.168.1.40, macs: ["aa:bb:cc:dd:ee:ff"]}
   ```

3. `just router-dhcp`, check the diff adds one `config host`, and answer `y`.
4. The device gets the address at its next renewal; reconnect it to have it
   now. `printer.lan` resolves at once.

## Change an address

Edit the host's `lan_ip` (or the entry's `ip`) and push. The device keeps
its old address until it renews, so reconnect it.

Changing the control plane's own address is not covered here: k3s and its
embedded etcd need changes too. The guard reaches the control plane at its
`lan_ip`, so a push that changes it stops at the backup and changes
nothing. Moving the control plane to another node is
{doc}`/how-to/recover-control-plane`. The NAS exports take
their addresses from `lan_ip` too: run `pb_nas.yml --tags nas_nfs`
afterwards. These still repeat addresses by hand, so change them with it:

| Address | Where |
|---------|-------|
| The NAS, 192.168.1.3 | `nfs.server`, `nfs_csi.server` and `nas.monitoring.targets` in `kubernetes-services/values.yaml`; `nfs.server` in `kubernetes-services/additions/jellyfin/values.yaml`; `nfs.server` and `worlds_server` in `kubernetes-services/additions/backups/values.yaml` |
| node02, 192.168.1.82 | `k3s.etcd_metrics_endpoints` in `kubernetes-services/values.yaml` |
| node01 to node04 and nuc1 | The `except` list of `minecraft.worlds.rcon_allowed_cidrs` in `kubernetes-services/values.yaml` |
| nuc2, 192.168.1.92 | `node_ip` in `hosts.yml`; the `vps_relay` forward's `target` in `kubernetes-services/values.yaml` |
| Any cluster node | Its `allow-ip` line in `.devcontainer/claude-sandbox.conf` ({doc}`/reference/inventory`) |

## Replace a machine

A node's new board or NIC needs no change here: installed with the
inventory name, it asks with that name and gets its `lan_ip`, but only once
the old board's lease has gone. dnsmasq won't give a name-only
reservation's address to a new MAC while another MAC holds a lease on it
(up to 12 hours), so until then the new board gets a pool address, and
`node02.lan` still points at the reserved one. Either wait for the old
lease to run out, reboot the router (leases live in RAM), or remove the old
board's line from the lease file with dnsmasq stopped:

```bash
ssh root@192.168.1.1
/etc/init.d/dnsmasq stop
vi /tmp/dhcp.leases    # delete the line with the old board's MAC
/etc/init.d/dnsmasq start
```

Then restart networking on the new board, or reboot it. A device reserved
by MAC needs its new MAC in `router_dhcp_hosts`.

## Remove a device

Delete its entry (or its `lan_ip`) and push. Its name stops resolving at
once; it keeps its address until its lease runs out, then gets one from
the pool.

## k3s.lan and the control plane

The `k3s.lan` record always points at `control_plane`'s `lan_ip`. To move
the API name, change `control_plane` in `group_vars/all.yml` and push;
there is no separate record to edit.

In a control plane recovery, `just k3s-api-dns <ip>` repoints `k3s.lan`
straight away with `uci`, without the guard
({doc}`/how-to/recover-control-plane`). That is fine in an emergency, but
the template doesn't know about it: once `control_plane` names the new node
and its router backup timer is installed (the guard's first step runs that
backup on the control plane), run `just router-dhcp`. The diff should show
only the comment coming back, as the template now points `k3s.lan` at the
same node; a diff that moves `k3s.lan` back means `control_plane` still
names the old node. Fix that before answering `y`.
