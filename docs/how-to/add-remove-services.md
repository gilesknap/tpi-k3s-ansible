# Add or remove a service

Every service on the cluster is an ArgoCD `Application` rendered from a
template in `kubernetes-services/templates/`. Adding a service is a matter
of adding a template and, usually, touching a handful of other places that
need to know about it. This page is the checklist, with ntfy (the push
notification service, added recently) as the worked example and Jellyfin
where ntfy has nothing to show.

{doc}`/explanations/architecture/gitops` explains the app-of-apps layout
and how a template becomes running pods. Make the change in a branch and
try it on the cluster as in {doc}`/how-to/work-in-branches`.

## The checklist

| # | Step | Needed when |
|---|------|-------------|
| 1 | [Application template](#the-application-template) in `templates/` | always |
| 2 | [`additions/<service>/`](#the-services-own-manifests) | the service has manifests of its own |
| 3 | [Ingress source](#an-ingress) | it has a web UI or an API |
| 4 | [Chart repository in the AppProject](#a-new-chart-repository) | its chart comes from a repo not used before |
| 5 | [Storage](#storage) | it keeps data |
| 6 | [SealedSecret](#secrets) | it has credentials |
| 7 | [Public hostname](#a-public-hostname) in `cloudflare/` | it should be reachable through the tunnel |
| 8 | [Home page card](#a-card-on-the-home-page) | people open it in a browser |
| 9 | [Backup job](#a-backup-job) | its data is not already on the NAS |
| 10 | [Services reference row](#the-reference-page) | always |

## Add a service

### The Application template

Create `kubernetes-services/templates/<service>.yaml`. This is ntfy's, in
full apart from the ingress annotations:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ntfy
  namespace: argo-cd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: ntfy
  project: kubernetes
  sources:
    - path: ./kubernetes-services/additions/ntfy
      repoURL: {{ .Values.repo_remote }}
      targetRevision: {{ .Values.repo_branch }}
      helm:
        valuesObject:
          cluster_domain: {{ .Values.cluster_domain }}

    - path: ./kubernetes-services/additions/ingress
      repoURL: {{ .Values.repo_remote }}
      targetRevision: {{ .Values.repo_branch }}
      helm:
        valuesObject:
          name: ntfy
          cluster_domain: {{ .Values.cluster_domain }}
          service_name: ntfy
          service_port: 80
          oauth2_proxy: false
          ssl_redirect: {{ if .Values.enable_cloudflare_tunnel }}false{{ else }}true{{ end }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

The parts that matter:

- `project: kubernetes` is the one AppProject, which limits where charts
  may come from (see [below](#a-new-chart-repository)).
- Sources that point at this repo use `.Values.repo_remote` and
  `.Values.repo_branch`, never a literal URL or branch. That is what lets
  `just switch-branch` move the whole cluster onto a branch.
- The finalizer makes ArgoCD delete the service's resources when the
  Application is deleted.
- `prune` and `selfHeal` are on for every application: the cluster is made
  to match git, in both directions.

**Optional services** are wrapped in a switch. Jellyfin's template starts
with `{{- if .Values.enable_jellyfin }}` and ends with `{{- end }}`, with
`enable_jellyfin: true` and a `jellyfin:` block of settings in
`kubernetes-services/values.yaml`. Put the version pins there too, with a
comment saying how to bump them. When choosing a version, take a release
that is at least two weeks old, the rule recorded beside the existing pins.

**A chart from elsewhere** is a source with `chart:` in place of `path:`.
Jellyfin's:

```yaml
    - chart: jellyfin
      repoURL: https://jellyfin.github.io/jellyfin-helm
      targetRevision: {{ $jf.chart_version | quote }}
      helm:
        releaseName: jellyfin
        valuesObject:
          ...
```

Most services here combine the two: an upstream chart, plus sources from
this repo for the ingress and any extra manifests.

### The service's own manifests

Anything the service needs beyond an upstream chart goes in
`kubernetes-services/additions/<service>/`, as plain YAML or as a small
Helm chart, and is named as a source by `path:`. ntfy has no upstream chart
at all, so `additions/ntfy/` is its whole deployment:

```text
kubernetes-services/additions/ntfy/
├── Chart.yaml
├── values.yaml
├── files/alertmanager-cluster.yml
└── templates/
    ├── configmap.yaml
    ├── deployment.yaml
    ├── networkpolicy.yaml
    ├── ntfy-auth-secret.yaml      # the SealedSecret
    ├── service.yaml
    └── templates-configmap.yaml
```

Give every container resource requests and limits, a non-root security
context where the image allows it, and an image tag that is a version, not
`latest`. Pods on amd64-only images need a `nodeSelector` for
`kubernetes.io/arch: amd64`: half the cluster is arm64.

### An ingress

A web UI gets its `Ingress` from the shared chart in
`kubernetes-services/additions/ingress/`, added as one more source (as in
ntfy's template above). It makes an Ingress named `<name>-ingress` for the
host `<name>.gkcluster.org`, served with the wildcard certificate. Its
values:

| Value | Meaning |
|-------|---------|
| `name` | The hostname's first label, and the Ingress's name |
| `cluster_domain` | Always `{{ .Values.cluster_domain }}` |
| `service_name`, `service_port` | The Service to send requests to. Port 443 switches the backend to HTTPS passthrough |
| `oauth2_proxy` | `true` puts the shared oauth2-proxy in front, so only `admin_emails` get in. Use it for anything without a login of its own |
| `ssl_redirect` | Whether nginx redirects HTTP to HTTPS. Copy the `enable_cloudflare_tunnel` expression above: requests arriving through the tunnel are already plain HTTP inside the cluster, and a redirect would loop |
| `basic_auth` | `true` asks for the `admin-auth` password (the Secret must exist in the service's namespace) |
| `extra_annotations` | Any other ingress-nginx annotations. ntfy turns off buffering and lengthens timeouts for its long-lived streams |

A service that signs in through Dex itself (as Grafana and argocd-monitor
do) leaves `oauth2_proxy` off and needs a Dex client instead; see
{doc}`/how-to/oauth-setup`.

A service that should not have a hostname at all, like Jellyfin (reached
on nuc2's own address from the LAN and the tailnet), simply has no ingress
source.

### A new chart repository

The AppProject in `argo-cd/argo-project.yaml` lists every repository an
application may use, in `sourceRepos`. A chart from a repository that is
not on the list fails with `application repo ... is not permitted in
project`. Jellyfin added this line:

```yaml
    - "https://jellyfin.github.io/jellyfin-helm"
```

The AppProject is applied by Ansible, not by ArgoCD, so adding the line
does nothing until this is run from the checkout that has it:

```bash
ansible-playbook pb_all.yml --tags cluster
```

(`just switch-branch <branch>` runs the same tag, so switching to the
branch applies it.) Three traps, all recorded in the `/argocd` skill:

- **OCI charts take a bare URL.** For a chart at
  `ghcr.io/gilesknap/charts/minecraft-dashboard`, both the Application's
  `repoURL` and the `sourceRepos` entry are `ghcr.io/gilesknap/charts`,
  with no `oci://` prefix, and `chart:` is `minecraft-dashboard`. With the
  prefix, ArgoCD drops the chart name from the URL and ghcr answers 403.
- **The error sticks.** After fixing `sourceRepos`, the application can
  stay `Unknown` with the old `InvalidSpecError`. Restarting the
  application controller clears it:
  `kubectl -n argo-cd delete pod argocd-application-controller-0`.
- **Check the version exists** before pinning it, with
  `helm pull oci://ghcr.io/<org>/charts/<chart> --version <ver>`. ArgoCD
  syncs whatever is pushed, so a pin to an unpublished version breaks the
  application until it is published.

### Storage

Decide where the data lives before the first sync
({doc}`/explanations/architecture/storage` has the reasoning).

**No lasting state.** Use an `emptyDir`. ntfy does: its message cache is
short-lived and its users and tokens are rebuilt from the SealedSecret at
every start, so the pod can run on any node.

**The default: `nfs-stable`.** A PersistentVolumeClaim that names no
storage class gets a folder on the NAS at
`/k8s-dynamic/stable/<namespace>/<pvc-name>`. The path depends only on the
claim's namespace and name, so the data is found again after a rebuild, and
the pod can run on any node. Nothing else needs configuring. See
{doc}`/how-to/nfs-stable-paths`. (`nfs-rwx` is the scratch class: a fresh
folder each time, deleted with the claim.)

**A `local-nvme` volume**, for data that should be on a node's own disk
(a busy database, or data next to a device). This pins the workload to one
node, so choose the node on purpose, and never the control plane or its
standby. It needs three things that agree with each other. Jellyfin's:

1. An entry under `local_storage` in `kubernetes-services/values.yaml`,
   which becomes a PersistentVolume pre-bound to the service's claim:

   ```yaml
   local_storage:
     jellyfin:
       node: nuc2
       path: /home/k8s-data/jellyfin
       capacity: 60Gi
       claim_namespace: jellyfin
       claim_name: jellyfin-config
   ```

2. An entry under `k8s_data_dirs` in `group_vars/all.yml` with the same
   `node` and `path`, and the owner the pod runs as. The `k8s_data_dirs`
   role creates the directory:

   ```bash
   ansible-playbook pb_all.yml --tags k8s_data_dirs --limit nuc2
   ```

   Use `/home/k8s-data/<name>` on nuc2 and `/var/lib/k8s-data/<name>` on
   an RK1. Only this role may create anything under those paths.

3. A claim with that exact namespace and name and
   `storageClassName: local-nvme` (Jellyfin's is
   `additions/jellyfin/templates/config-pvc.yaml`; a chart that makes its
   own claim must produce that name), and in the template a `nodeSelector`
   for the same host.
   The PV's node affinity would pin the pod anyway; saying it in the
   template makes it visible.

If the path and the node in steps 1 and 2 differ, the claim stays
`Pending`. {ref}`move-a-local-nvme-pv` covers moving one later.

**Existing directories on the NAS** (a media library, an archive) are
mounted with a static NFS PersistentVolume in the service's `additions/`,
as Jellyfin does for `/bigdisk/media`, read-only
(`additions/jellyfin/templates/media-nfs.yaml`). The directory itself is
created by the `nas` role, or is a dataset of its own there
({doc}`/how-to/nas-setup`).

### Secrets

Credentials are committed only as SealedSecrets
({doc}`/how-to/manage-sealed-secrets`). For a new service:

- Name the file `<something>-secret.yaml`, singular. The gitleaks
  pre-commit hook allows exactly that pattern; `-secrets.yaml` is blocked.
- Seal a real value straight away. A file with placeholder text in
  `encryptedData` fails to decrypt, the Secret is never created, and the
  errors that follow do not point back at the placeholder.
- Add the secret to `scripts/generate-secrets` and
  `scripts/seal-from-json`, so that a rebuild seals it again for the new
  cluster. A value that comes from outside (an API key) is read from an
  environment variable and also added to `scripts/export-external-creds`.
  ntfy did all three, and has its own `just seal-ntfy` for day-to-day
  changes.
- Pods read a Secret at start-up. After re-sealing, restart the pods that
  use it.

### A public hostname

An Ingress alone has no public DNS name. To publish `<name>.gkcluster.org` through the Cloudflare Tunnel,
add one line to `tunnel_services` in `cloudflare/locals.tf`, then plan and
apply: {ref}`cf-add-service`. That one entry is the tunnel route and the
DNS record, and the wildcard Cloudflare Access application then asks every
visitor to log in before the request reaches the cluster.

ntfy is one of the two exceptions that are open at the edge, because a
phone app cannot do a Cloudflare login. Its entry says
`access_bypass = true`, it has a bypass application in `access.tf` and a
rate-limiting rule in `waf.tf`, and its own tokens are the gate
({ref}`cf-access-bypass`). The plan fails if a bypass is added without
that flag.

### A card on the home page

Add a card to the grid in
`kubernetes-services/additions/home/templates/manifests.yaml`:

```html
<a class="card" href="https://ntfy.{{ .Values.cluster_domain }}">
  <h2>ntfy</h2>
  <p>Push notifications for cluster alerts</p>
</a>
```

Add `<span class="badge badge-sso">SSO</span>` to the heading for a
service that signs in through Dex, or `badge-oauth` with the text `OAuth`
for one behind oauth2-proxy. A card for an optional service is wrapped in
its switch (`{{- if .Values.enable_minecraft }}`), and the switch is passed
to the home chart in `templates/home.yaml`.

### A backup job

Data on `nfs-stable` or elsewhere on the NAS is already off the node. Data
on a `local-nvme` volume exists in one place only, so it needs a CronJob
that copies it to `/bigdisk/k8s-cluster/backups/<service>/` on the NAS.
The jobs live in `kubernetes-services/additions/backups/` (Grafana's and
Jellyfin's are the models). Add the destination directory to the `nas` role's
`nas_directories`, owned by the job's uid, and run `pb_nas.yml` first
({doc}`/how-to/nas-setup`). Everything under `backups/` is then picked up
by the nightly encrypted copy to Google Drive with no further change
({ref}`offsite-backup`).

### The reference page

Add a row for the service to the catalogue and the access table in
{doc}`/reference/services` (chart, version, namespace, where it runs, how
it is reached), and write a how-to page if operating it takes more than a
paragraph.

### Ship it

```bash
just check
git push -u origin add-my-service
just switch-branch add-my-service
just status
```

The root application picks up the new template and creates the child
application, which syncs by itself. Then open the pull request
({doc}`/how-to/work-in-branches`).

## Remove a service

1. Delete `kubernetes-services/templates/<service>.yaml` and
   `kubernetes-services/additions/<service>/`. For an optional service,
   setting its `enable_*` switch to `false` has the same effect and keeps
   the code.
2. Remove its home page card, its backup job and any alert rules, its
   `tunnel_services` entry (then `just cf-plan` and `just cf-apply`: this
   removes the route and the DNS record), its entries in the secret
   scripts, and its row in {doc}`/reference/services`.
3. Push and merge as usual.

The root application prunes the child Application, and the child's
finalizer deletes everything the application created: Deployments,
Services, Ingresses, SealedSecrets and their Secrets, and its
PersistentVolumeClaims.

Pruning does not remove everything, mostly on purpose:

| Left behind | Why | To finish the job |
|-------------|-----|-------------------|
| The namespace | `CreateNamespace=true` creates it but ArgoCD does not own it | Harmless when empty; `kubectl delete namespace <name>` if wanted |
| Data on a `local-nvme` volume | The PV has `Retain`, and is defined by the `local_storage` entry, not by the service | Remove the `local_storage` and `k8s_data_dirs` entries. The directory on the node is never deleted by any playbook except `pb_decommission.yml -e wipe_local_data=true`; on an RK1 leave it alone |
| Data on `nfs-stable` | Deleting the claim moves its folder to `archived-<namespace>/<pvc-name>` on the share | Delete the archived folder on the NAS by hand when sure |
| Static NFS directories and backups on the NAS | Nothing automated deletes on the NAS: ArgoCD and the cluster playbooks never touch it, and the `nas` role leaves a directory or dataset removed from its lists | Delete by hand on the NAS when sure |
| Files already on Google Drive | The off-site job only adds; it prunes its own old uploads later, by age | Nothing |
| The `sourceRepos` line | The AppProject is applied by Ansible | Remove the line and run `--tags cluster` |
| The Cloudflare route and DNS record | The edge is not ArgoCD's | The `tunnel_services` change in step 2 |

Data on `nfs-rwx` is the exception to all this: it is deleted with its
claim.

## Version updates

[Renovate](https://docs.renovatebot.com/) watches the chart versions in
`kubernetes-services/templates/` and the image tags under
`kubernetes-services/`, and opens a pull request when a new one is
published (`renovate.json`). Versions pinned in `values.yaml` with a
checksum beside them (age, the Headlamp plugin) are bumped by hand, both
values together.
