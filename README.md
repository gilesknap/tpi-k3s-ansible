# K3S Cluster Commissioning for Turing Pi with Ansible

## Description

An infrastructure as code project to commission a k3s cluster.

Supported hardware:
- One or more Turing Pi v2.5.0 boards
- With compute modules RK1 or CM4
- ANY additional Linux nodes not in a Turing Pi (OS pre-installed)

For more see [Details](docs/details.md).

## Features

- Automated Flashing of the compute modules with latest Ubuntu 24.04 LTS
- Move OS to NVME or other storage device
- Install of a multi-node k3s cluster
- Install services into the cluster
- Ansible execution environment automatically setup in a devcontainer
- Minimal pre-requisites

## Current Software

- Ubuntu 24.04 LTS
- Latest K3S
- Nginx ingress controller
- Let's Encrypt Cert Manager
- K8S Dashboard
- Prometheus and Grafana
- Longhorn

## Planned Software

- Keycloak for centralized authentication
- ArgoCD
- KubeVirt
- NFS PVC auto-provisioner
- Backup of Longhorn volumes to NFS NAS
- anything else that is useful

## Quick start

See [setup](docs/setup.md) to create some keypairs and access the turingpi(s).

- Add an SDCard to your BMC(s) mounted at /mnt/sdcard
- install podman 4.3 or higher, git and vscode
  - set vscode setting `dev.containers.dockerPath` to `podman`
- clone this repo, open in vscode and reopen in devcontainer
- edit the hosts.yml file to match the turingpi's and nodes you have
- also edit group_vars/all.yml especially letsencrypt_email and admin_password
- kick off the ansible playbook:

```bash
cd tpi-k3s-ansible
ansible-playbook pb_ALL.yml -e do_flash=true
```
## Notes

NOTE: All of the ansible playbooks after the initial flashing of the compute modules can be applied to any k3s cluster. Only the initial flashing of the compute modules is specific to the Turing Pi.

Turing Pi is a great platform for a project like this as it provides a BMC interface that allows you to remotely flash and reboot it's compute modules. See the [Turing Pi](https://turingpi.com/) website for more information.

K3S is a lightweight Kubernetes distribution that is easy to install and manage. It is a CNCF certified Kubernetes distribution that I use for all my Kubernetes projects. See the [K3S](https://k3s.io/) website for more information.

Thanks to drunkcoding.net for some great tutorials that helped with putting this together. See the [A Complete Series of Articles on Kubernetes Environment Locally](https://drunkcoding.net/posts/ks-00-series-k8s-setup-local-env-pi-cluster/)

## Some How to's

All these commands are run from the ansible directory to pick up the default hosts.yml file.

### re-flash a single node

limit hosts to the controlling turing pi and the nodes(s) to be re-flashed. Pass in the flash_force variable to force a re-flash.

```bash
# re-flash a single node
ansible-playbook pb_flash_os.yml --limit turingpi,node03 -e flash_force=true
# re-install k3s on one worker node
ansible-playbook pb_k3s.yml --limit node03 -e k3s_force=true
# after a re-flash, your node will be missing longhorn drivers so:
ansible-playbook pb_cluster.yml -e '{ cluster_install_list: [grafana] }'
```

### shut down all nodes

```bash
# shutdown all nodes
ansible all_nodes -a "/sbin/shutdown now" -f 10 --become
# or reboot all nodes
ansible all_nodes -m reboot -f 10 --become
```

### run a single role standalone

```bash
# run the cluster installs only and choose a list of services to (re-)install
ansible localhost -m include_role -a name=cluster -e '{ cluster_install_list: [ingress,dashboard] }'
# test the known_hosts role against all nodes
ansible all_nodes -m include_role -a name=known_hosts
```

### Test  one of the templates

```bash
ansible localhost -m template -a "src=roles/cluster/templates/grafana_values.yaml dest=/tmp/c.yaml" -e ingress_controller_exists=true -e lo
nghorn_installed=true
```

