FROM mcr.microsoft.com/devcontainers/python:2-3.14

# We are root in a rootless container so don't warn us about this in pip
ENV PIP_ROOT_USER_ACTION=ignore

# get the 'dig' tool
# Remove the Yarn apt source - its GPG key is incompatible with Debian trixie's sqv verifier
RUN rm -f /etc/apt/sources.list.d/yarn.list
RUN apt-get update -y && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    apache2-utils \
    dnsutils

# Install ansible python packages
RUN pip install \
    ansible \
    argcomplete \
    ansible-lint \
    jmespath \
    kubernetes
