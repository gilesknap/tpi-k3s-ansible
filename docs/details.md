# Ansible Deployment of a K3S cluster to Turing Pi

## Introduction

This repo implements an Ansible Playbook that will deploy a K3S cluster to one or more [Turing Pi's](https://turingpi.com/product/turing-pi-2-5/).

It can stand up a cluster from scratch, including:

- flashing Ubuntu Server 2024.04 to the nodes
- moving the OS to a separate disk (e.g. NVME)
- installing a multi-node K3S cluster (with a single control plane for now)
- deploying multiple services into the cluster.

This project is extensively tested on my own cluster and will reliably re-flash and rebuild it with zero manual intervention. My cluster consists of:

- A Turing Pi 2.5
- 1 x Raspberry Pi CM4 4GB
- 2 x RK1 8GB
- 2 x Intel NUC

But, the intention is for this repo to be generally useful. Bug reports, feature requests and PRs are welcome.

The playbook is fully idempotent. This means that it checks the state of every step it does before execution and does nothing if that state is already achieved. Therefore, you can run the playbook multiple times without causing any harm, e.g.:

- re-running the playbook against a fully deployed cluster will do nothing except check that all is well
- re-running the playbook again after a partial install due to a temporary failure will pick up where it left off
- re-running the playbook after adding an additional Turing Pi or additional node to the cluster will add the new hardware to the cluster (requires editing the inventory file hosts.yml)
- etc.

## Goals

Eventually, I would like to be able to:-

- deploy any services to the cluster that I want
- be able to serve my own web pages from the cluster
- have any data stored on the cluster be backed up
- be able to tear down and rebuild the cluster at will with all applications coming back up with their previous state restored

This makes it much more fun to tinker with a cluster as you can be confident that you can always get back to a known good state.

At time of writing the remaining things to sort out to achieve these goals are:-
- firewall configuration to protect internet facing services
- auto backup and restore of Longhorn volumes to NFS NAS

## Setup the Execution Environment

Ansible requires a control node to execute the playbook. For this purpose you will need a Linux workstation. I expect that a [WSL2 environment](https://learn.microsoft.com/en-us/windows/wsl/install) will also work for Windows users, but I have not tested it. The Linux distribution is not important but will need to be new enough to support `podman` container runtime 4.3 or later.

So as not to contaminate your workstation with the dependencies required to run the playbook, this project uses a developer container as the execution environment. Therefore the only things you will need to install on your workstation are:

- [git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git) - to clone this repo
- [podman](https://podman.io/docs/installation) - to run the developer container
- [vscode](https://code.visualstudio.com/download) - to launch the developer container

Once vscode is installed you will need to configure it to use podman as the container runtime. This is done by installing the [Remote - Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension. Then change `dev.containers.dockerPath` to `podman` in the vscode settings.

I also recommend using zsh. Set `terminal.integrated.defaultProfile.linux` to `zsh` in the vscode settings. This will work because the developer container already has zsh installed. The completion available in zsh helps when learning kubectl and helm commands. Completion for bash is currently broken but I will fix it in a future release.

podman and vscode are an opinionated choice:

- vscode: If you do not want to use vscode you can use the devcontainer with command line only using [The Devcontainer CLI](https://code.visualstudio.com/docs/devcontainers/devcontainer-cli).
- podman: The current setup of the devcontainer requires a rootless container runtime, podman is rootless by default. You could also use rootless docker. I could make the devcontainer support rootful docker in future but IMHO the necessary fiddling with user ids inside of the container is a little ugly.

## Networking

For the playbook to work you will need your turingpi and your workstation in the same subnet and you will require that:

- zero configuration networking is enabled.
- there is a DHCP service on your subnet.

Typically you will have both of the above already. If you can plug in your turingpi to your router, power it up and ping it as follows then you will be good to go.

```
ping turingpi
```

If `turningpi` does not work, also try `turingpi.local`, `turingpi.lan` or `turingpi.broadband `.

If this is not working then there is not a good workaround at the moment. I'd be interested in taking ideas on how to remove this requirement. If you do happen to know the MAC address of your nodes, then you could give them fixed IP addresses in your router's DHCP configuration. Then you could add the names you want to use for the nodes to your workstation's `/etc/hosts` file. But I'm not sure how to determine the MACs without a first boot.

### Warning

I have had issues with the IP addresses changing on node reboot during testing. I suggest that once you have all your nodes up for the first time you allocate them fixed IP addresses in your router's DHCP configuration.

## Port Forwarding in your Router

If you are interested in serving to the internet then you will need your router to forward ports to your cluster. However, I'm leaving this out for now because:

- The security implications mean that we should configure a firewall first - I need to do some research on the best way to do that.
- Our networking approach means that you will not know the IP addresses of your cluster nodes until the first deploy. So port forwarding to IP addresses will have to be done after the first deploy. Also fixing the IP addresses in DHCP will be necessary to make this work.
- It requires a public DNS that routes to your network. Not everyone has this.

## Hardware Setup

Mount in the nodes you want to use in your Turing Pi. Supply power and a network connection to your router.

Insert an SD card for the BMC in the slot underneath the Turing Pi board. This should be at least 8GB in size but does not yet need to be formatted. This is used to store image files for flashing the compute modules.

Now is a good time to clone the repo so you can copy your public key in the next step into it:

```bash
git clone git@github.com:gilesknap/tpi-k3s-ansible.git
cd tpi-k3s-ansible
```

Next you need to set up a keypair and authorize it for each Turing Pi you have. See [setup](docs/setup.md) for details.

Make sure that each turing_pi has its sdcard mounted at `/mnt/sdcard` and formatted as ext4. **TODO**: the playbook should do this step for you.


## Configuration

Before the first run of the Playbook you must adjust the configuration to match your environment.

Now is a good time to launch vscode and start up the developer container. Then you can easily browse and edit the files in the project. Plus this is where you will open a terminal to run the playbook in a later step.

```bash
cd tpi-k3s-ansible
code .
# when prompted select "Reopen in Container"
# Or ctrl-shift-p and select "Remote-Containers: Reopen in Container"
```

### edit ansible/hosts.yml

This file contains the inventory of your cluster. You will need to edit it to match your Turing Pi and nodes. The default file describes my cluster.

For each turing_pi:
- add an entry to the turing_pis group with its DNS name
- create a turingpi_nodes group which describes the nodes in that turing_pi
  - the name of this group must be DNS name of the turing_pi with the suffix `_nodes`

For each node:
- add an entry to the turingpi_nodes group with its desired DNS name - ansible will use cloud-init to set this as the node name on first boot. Zero configuration networking will then allow you to refer to the node by this name.
- say which slot_num the node is in, starting from 1 (slot nearest the coin battery)
- declare the type of node. At present these are supported:
  - pi4 for a pi cm4 module
  - rk1 for a rk1 module
- declare the disk you want the OS installed on using `root_dev`. This should be the device name of the disk as seen by the OS on the node. If you want the OS to stay on the board's eMMC then don't supply a `root_dev` for that node.
  - NVME and RK1 with Ubuntu: `/dev/nvme0n1`
  - Other devices as yet not looked into this. TODO.

### edit ansible/group_vars/all.yml

This file contains variables that are used for all the hosts in the playbook.

Take a look at the commented fields below `EDIT BELOW` and adjust them as needed.

Note that the `lets_encrypt` service is commented out by default. It is fully working but requires that your router port forwards 80 and 443 to the control plane node. I'm not recommending doing this until we have some instructions on setting up a firewall.

## Running the Playbook

Once you have set up your environment and configured the playbook you can run it as follows:

```bash
# Launch a terminal in vscode (inside the devcontainer)
# Menu->Terminal->New Terminal
ansible-playbook pb_all.yml
```


