# Expose Cluster Ports Through a VPS Relay

The `vps-relay` service publishes chosen cluster ports on the fixed public IP
of a VPS. Use it when the cluster cannot accept inbound connections, for
example because the home connection is behind ISP carrier-grade NAT (CGNAT),
or when you do not want to publish your home IP. Minecraft game ports are the
first user; any TCP or UDP service can be added as one more list entry.

The Cloudflare tunnel ({doc}`cloudflare-web-tunnel`) already covers HTTP(S)
services. The relay is for protocols the tunnel cannot carry.

## How it works

```
player ──► VPS public :port ──► frps ◄══ tunnel opened BY the cluster, over the tailnet ══ frpc ──► target:port
```

- The `vps-relay` Deployment runs two containers in one pod:
  - **tailscale** joins your tailnet as an **ephemeral** node tagged
    `tag:vps-relay`, in **userspace mode** (no `NET_ADMIN`, no
    `/dev/net/tun`, no `hostNetwork`). It exposes a SOCKS5 proxy on
    `127.0.0.1:1055` inside the pod.
  - **[frpc](https://github.com/fatedier/frp)** connects through that proxy
    to `frps` on the VPS, authenticates with a shared token over TLS, and
    registers one proxy per forwarded port.
- `frps` on the VPS listens for players on each forwarded port and relays
  each connection back down the tunnel that frpc opened. frpc delivers it to
  the forward's `target` on the same port number.

**Every connection is opened from the cluster side.** The VPS never
initiates a connection into the home network, the tailnet policy gives the
VPS no access to the relay node, and the relay node advertises no subnet
routes.

| Piece | Where | Notes |
|-------|-------|-------|
| `vps-relay` Deployment and `vps-relay-frpc` ConfigMap | `kubernetes-services/additions/vps-relay/`, namespace `vps-relay` | `frpc.toml` is generated from `vps_relay.forwards` |
| `vps-relay-credentials` SealedSecret | `additions/vps-relay/templates/vps-relay-secret.yaml` | Tailscale OAuth client secret + frp token (created by you) |
| `frps` | The VPS (Docker or systemd) | Control port bound to the VPS's tailnet IP only |
| Tailnet policy | Tailscale admin console | `tag:vps-relay` may reach only the VPS's frp port |
| Public DNS name | Cloudflare **DNS-only** A record | Points at the VPS's public IP |

### Trade-offs

- Services see every client as coming from the relay pod, not the client's
  real IP. IP-based bans and logs are of no use; name-based controls (such
  as Minecraft whitelists and ops) still work.
- The relay depends on Tailscale's coordination service to set up the
  tailnet connection between the pod and the VPS.

## Prerequisites

- A VPS with a public IPv4 address, already on your tailnet (`tailscale up`).
- Admin access to your tailnet's policy file and its OAuth clients.
- A DNS name you can point at the VPS (for example a grey-cloud Cloudflare
  record in your cluster domain).

## Step 1: Tailnet policy

In the Tailscale admin console, **Access controls**, add an owner for the
tag and one grant that lets the relay reach only the VPS's frp port. Replace
`100.x.y.z` with the VPS's tailnet IP.

```json
{
  "tagOwners": {
    "tag:vps-relay": ["autogroup:admin"]
  },
  "hosts": {
    "vps": "100.x.y.z"
  },
  "grants": [
    {
      "src": ["tag:vps-relay"],
      "dst": ["vps"],
      "ip": ["tcp:7000"]
    }
  ]
}
```

Merge these into your existing policy. Do **not** add any rule that gives
the VPS (or `*`) access to `tag:vps-relay`.

:::{warning}
A new tailnet starts with an allow-all rule (`"src": ["*"], "dst": ["*"]`).
While that rule is present, every device on the tailnet, including the VPS,
can reach the relay node. Replace it with explicit grants before relying on
the "VPS never dials in" property. The relay advertises no routes, so even
then the VPS cannot reach the rest of your home network through it.
:::

## Step 2: OAuth client

The pod authenticates with an OAuth client secret. Unlike auth keys, which
expire after at most 90 days, OAuth clients do not expire.

1. In the admin console go to **Settings → OAuth clients → Generate OAuth
   client**.
2. Grant the **Auth Keys** scope with **Write** access, and add the tag
   `tag:vps-relay`.
3. Generate the client and copy the **client secret** (`tskey-client-…`).
   It is shown only once.

The pod appends `?ephemeral=true&preauthorized=true` to the secret, so each
pod joins as an ephemeral node that Tailscale removes soon after the pod
goes away. No Tailscale state is stored in the cluster.

## Step 3: Set up frps on the VPS

Generate the shared frp token, and keep it for Step 4:

```bash
openssl rand -hex 32
```

On the VPS, create `/etc/frp/frps.toml`. Replace `100.x.y.z` with the VPS's
tailnet IP, and make `allowPorts` exactly the union of the port ranges in
`vps_relay.forwards`:

```toml
# Control port: tailnet only, never the public interface.
bindAddr = "100.x.y.z"
bindPort = 7000

# Player-facing listeners for each forwarded port.
proxyBindAddr = "0.0.0.0"

auth.method = "token"
auth.token = "{{ .Envs.FRP_AUTH_TOKEN }}"
transport.tls.force = true

# Exactly the ports in vps_relay.forwards — frps refuses any others.
allowPorts = [
  { start = 30565, end = 30584 },
]

log.to = "console"
```

Put the token in `/etc/frp/frps.env`, readable by root only:

```bash
sudo install -m 600 /dev/null /etc/frp/frps.env
echo "FRP_AUTH_TOKEN=<token>" | sudo tee /etc/frp/frps.env > /dev/null
```

Run frps with Docker Compose, using host networking so it can bind the
tailnet IP. Pin the same frp version as the `frpc` image in
`additions/vps-relay/values.yaml`:

```yaml
# /etc/frp/compose.yaml
services:
  frps:
    image: fatedier/frps:v0.71.0
    command: ["-c", "/etc/frp/frps.toml"]
    network_mode: host
    restart: unless-stopped
    env_file: /etc/frp/frps.env
    volumes:
      - /etc/frp/frps.toml:/etc/frp/frps.toml:ro
```

```bash
sudo docker compose -f /etc/frp/compose.yaml up -d
sudo docker compose -f /etc/frp/compose.yaml logs -f
```

If frps starts before Tailscale has brought up the tailnet IP, it fails to
bind and Docker restarts it until the address exists. The frps binary from
the [frp releases](https://github.com/fatedier/frp/releases) under systemd
works equally well; use the same config and environment file.

### Firewall

Open each forward's ports publicly and the frp control port on the tailnet
interface only. With `ufw`:

```bash
sudo ufw allow 30565:30584/tcp                          # minecraft forward
sudo ufw allow in on tailscale0 to any port 7000 proto tcp
```

Also open the ports in your VPS provider's cloud firewall, if it has one.

## Step 4: Seal the credentials

Seal both values into the `vps-relay` namespace as the
`vps-relay-credentials` Secret. The file name must end in `-secret.yaml`
(singular), because the `.gitleaks.toml` allowlist only covers that pattern.
See {doc}`manage-sealed-secrets` for background.

```bash
# Prompt for both values (not echoed, not stored in shell history)
printf 'Tailscale OAuth client secret: ' && read -rs TS_SECRET && echo
printf 'frp token: ' && read -rs FRP_TOKEN && echo

kubectl create secret generic vps-relay-credentials \
    --namespace vps-relay \
    --from-literal=ts-oauth-client-secret="$TS_SECRET" \
    --from-literal=frp-token="$FRP_TOKEN" \
    --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets \
    --controller-namespace kube-system -o yaml > \
    kubernetes-services/additions/vps-relay/templates/vps-relay-secret.yaml

unset TS_SECRET FRP_TOKEN
```

The `vps-relay` namespace does not need to exist yet.

:::{tip}
For cluster rebuilds, export the two values as
`VPS_RELAY_TS_OAUTH_CLIENT_SECRET` and `VPS_RELAY_FRP_TOKEN` alongside the
other external credentials. `scripts/export-external-creds` captures them
from a running cluster, and `just generate-and-seal-all` re-seals them when
both are set (and skips them when neither is).
:::

## Step 5: Configure and enable the relay

Edit `kubernetes-services/values.yaml`:

```yaml
enable_vps_relay: true
vps_relay:
  vps_tailnet_host: 100.x.y.z     # the VPS's tailnet IP or MagicDNS name
  frp_port: 7000
  forwards:
    - name: minecraft
      protocol: tcp
      ports: 30565-30584          # single port or inclusive range
      target: 192.168.1.92        # LAN IP, or an in-cluster Service DNS name
```

Each forward publishes `ports` on the VPS and relays them to the **same port
numbers** on `target`. Because frpc runs inside the cluster, `target` can be
a Service DNS name such as `my-svc.my-namespace.svc.cluster.local`, so new
services do not need a NodePort. `protocol` is `tcp` or `udp` (frp carries
UDP over its TCP tunnel).

Commit and push. ArgoCD creates the `vps-relay` Application and namespace.

## Step 6: Point DNS at the VPS

Create an `A` record for the public name (for example `mc.<domain>`) with
the VPS's public IP and the **DNS only** (grey cloud) proxy status. The
address is static, so no DDNS is needed. Cloudflare's proxy only carries
HTTP(S), so the record must not be proxied.

## Step 7: Verify

1. **Pod** — both containers are running and the tailscale container is
   Ready:

   ```bash
   kubectl get pods -n vps-relay
   kubectl logs -n vps-relay deploy/vps-relay -c tailscale | tail
   ```

2. **Tailnet** — on the VPS, `tailscale status` lists a `vps-relay` node
   tagged `tag:vps-relay`.
3. **frpc** — each forwarded port logs `start proxy success`:

   ```bash
   kubectl logs -n vps-relay deploy/vps-relay -c frpc | grep -c 'start proxy success'
   ```

4. **Public port** — from outside your network (an online port checker, or
   `nc -vz <vps-public-ip> 30565`), a forwarded port is open while its
   target is listening.
5. **Direction** — the VPS cannot open a connection to the relay node. On
   the VPS, `nc -vz -w 5 <relay-tailnet-ip> 22` must time out: the policy
   drops the packets. A prompt `connection refused` means the policy still
   lets the VPS reach the node (see the warning in Step 1).

## Adding a forward

1. Add an entry to `vps_relay.forwards`. Names must be unique.
2. **On the VPS**, add its ports to `allowPorts` in `frps.toml` and restart
   frps, and open them in the firewall.
3. Commit and push. The ConfigMap checksum changes, so the pod restarts with
   the new `frpc.toml`.

:::{important}
Step 2 is a deliberate manual sync point. A forward in git does nothing
until the VPS allows its ports, so a mistaken or malicious change to the
repository cannot publish a new port on its own. frpc logs
`port not allowed` for a forward the VPS has not yet allowed.
:::

## Troubleshooting

### The pod is stuck in `CreateContainerConfigError`

The `vps-relay-credentials` Secret does not exist. The SealedSecret is
missing, or was sealed for another cluster or namespace.

### The tailscale container never becomes Ready

Check its log. `requested tags [tag:vps-relay] are invalid or not permitted`
means the OAuth client does not have the tag, or `tagOwners` does not define
it. An authentication error means the client secret is wrong or was revoked.

### frpc logs `connect to server error`

- `i/o timeout` or `connection refused` through the SOCKS proxy: the
  tailnet policy does not grant `tag:vps-relay` access to the VPS on the frp
  port, frps is not running, or it is bound to a different address.
- `token in login doesn't match`: the sealed `frp-token` differs from
  `FRP_AUTH_TOKEN` on the VPS.

frpc retries on its own, so a relay started before the VPS is ready
recovers without a restart.

### The public port is closed

- Check `allowPorts` and both firewalls on the VPS.
- Check the forward's target from inside the cluster, for example
  `kubectl run -it --rm nc --image=busybox -- nc -vz <target> <port>`.

## Removing the relay

Set `enable_vps_relay: false` and push. ArgoCD prunes the namespace's
resources and the ephemeral tailnet node disappears shortly afterwards.
Then stop frps on the VPS, close its firewall ports, delete the DNS record,
and revoke the OAuth client.
