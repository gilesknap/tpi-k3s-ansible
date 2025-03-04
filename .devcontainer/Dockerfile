FROM mcr.microsoft.com/devcontainers/python:1-3.12-bullseye

# We are root in a rootless container so don't warn us about this in pip
ENV PIP_ROOT_USER_ACTION=ignore

# get the 'dig' tool
RUN apt-get update -y && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    dnsutils

# Install ansible python packages
RUN pip install \
    ansible \
    argcomplete \
    ansible-lint \
    jmespath \
    kubernetes
