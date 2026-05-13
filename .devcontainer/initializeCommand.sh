#!/bin/bash

# custom initialization goes here - runs outside of the dev container
# just before the container is launched but after the container is created

echo "initializeCommand for devcontainerID ${1}"
set -xe

# make the config folder for the shared bash-config feature
mkdir -p ${HOME}/.config/bash-config

# ensure local container users can access X11 server (for rootful containers)
xhost +SI:localuser:$(id -un)

# ensure the mounted files/folders exist before the container is launched
touch ${HOME}/.ansible_vault_password
mkdir -p ${HOME}/.claude ${HOME}/.config/terminal-config
