#!/usr/bin/env python3
"""Render the install stick's NoCloud seeds and GRUB menu from hosts.yml.

scripts/make-install-stick runs this; scripts/test-make-install-stick tests
it. It writes, under --out:

  <host>/user-data, <host>/meta-data   one per host with install_profile
  new/user-data, new/meta-data         the interactive "new hardware" entry

and, with --grub-in and --grub-out, the stick's GRUB menu: the ISO's own
grub.cfg with an entry per host (and the new-hardware entry) added in front
of its own entries.

The data comes from host vars in hosts.yml (see docs/how-to/install-stick.md):

  install_profile:     server | desktop (ubuntu-desktop on top of server)
  install_disk_serial: the OS disk's serial (lsblk -o NAME,SERIAL)
  install_disk_model:  optional; the OS disk's model as lsblk shows it

A host with install_profile but no usable install_disk_serial gets no entry:
the build warns and leaves it out.
"""

import argparse
import re
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
GUARD = HERE / "disk-guard.sh"
PROFILES = ("server", "desktop")
NEW = "new"
NEW_HOSTNAME = "new-host"
SERIAL_RE = re.compile(r"^[A-Za-z0-9._-]{6,}$")
HOST_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class Literal(str):
    """A string dumped as a YAML literal block."""


def _literal(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")


yaml.SafeDumper.add_representer(Literal, _literal)


def walk_hosts(group, out):
    """Collect each host's vars from an inventory group, recursively."""
    if not isinstance(group, dict):
        return
    for name, hvars in (group.get("hosts") or {}).items():
        out.setdefault(name, {}).update(hvars or {})
    for child in (group.get("children") or {}).values():
        walk_hosts(child, out)


def inventory_hosts(path):
    inv = yaml.safe_load(Path(path).read_text()) or {}
    hosts = {}
    for group in inv.values():
        walk_hosts(group, hosts)
    return hosts


def install_hosts(hosts):
    """Return ({host: vars} to build, [warnings]); raise on bad data."""
    good, warnings = {}, []
    for name in sorted(hosts):
        hvars = hosts[name]
        if "install_profile" not in hvars:
            continue
        profile = hvars["install_profile"]
        if profile not in PROFILES:
            raise SystemExit(
                f"{name}: install_profile is {profile!r}, not one of {PROFILES}"
            )
        if name == NEW or not HOST_RE.match(name):
            raise SystemExit(f"{name}: not usable as a hostname and stick entry")
        serial = hvars.get("install_disk_serial")
        if not isinstance(serial, str) or not SERIAL_RE.match(serial):
            warnings.append(
                f"{name}: no usable install_disk_serial ({serial!r}) in hosts.yml;"
                " leaving its entry off the stick"
            )
            continue
        model = hvars.get("install_disk_model", "")
        if not isinstance(model, str) or "'" in model or "\n" in model:
            raise SystemExit(f"{name}: install_disk_model must be a plain string")
        good[name] = hvars
    return good, warnings


def read_keys(paths):
    keys = []
    for path in paths:
        text = Path(path).read_text()
        if "PRIVATE KEY" in text:
            raise SystemExit(f"{path} holds a private key: refusing")
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if len(lines) != 1 or not re.match(r"^(ssh-|ecdsa-|sk-)", lines[0]):
            raise SystemExit(f"{path} is not a single SSH public key")
        keys.append(lines[0])
    if not keys:
        raise SystemExit("no SSH public keys given")
    return keys


def target_user_data(hostname, account, keys):
    """The cloud-config the installed system runs on its first boot."""
    data = {
        "users": [
            {
                "name": account,
                "gecos": "Ansible User",
                "groups": ["adm", "sudo"],
                "sudo": ["ALL=(ALL) NOPASSWD:ALL"],
                "shell": "/bin/bash",
                "lock_passwd": True,
                "ssh_authorized_keys": list(keys),
            }
        ],
        "disable_root": True,
        "ssh_pwauth": False,
    }
    return {"hostname": hostname, "preserve_hostname": False, **data}


def guard_command(serial, model):
    head = f"INSTALL_DISK_SERIAL='{serial}'\nINSTALL_DISK_MODEL='{model}'\n"
    return Literal(head + GUARD.read_text())


DESKTOP_LATE = [
    # NetworkManager runs the network on a desktop, as on ws03: replace the
    # installer's networkd config with the one Ubuntu Desktop ships.
    "rm -f /target/etc/netplan/*.yaml",
    "printf 'network:\\n  version: 2\\n  renderer: NetworkManager\\n'"
    " > /target/etc/netplan/01-network-manager-all.yaml",
    "chmod 600 /target/etc/netplan/01-network-manager-all.yaml",
    "curtin in-target -- systemctl set-default graphical.target",
]


def autoinstall(hostname, hvars, account, keys):
    """The autoinstall config for one host, or the new-hardware entry."""
    ai = {
        "version": 1,
        "interactive-sections": [] if hostname else ["network", "storage"],
        "locale": "en_GB.UTF-8",
        "keyboard": {"layout": "gb"},
        "timezone": "Europe/London",
    }
    if hostname:
        serial = hvars["install_disk_serial"]
        ai["early-commands"] = [guard_command(serial, hvars.get("install_disk_model", ""))]
        # The whole disk: a 1 GB ESP and an ext4 root (UEFI).
        ai["storage"] = {
            "layout": {"name": "direct", "match": {"serial": f"*{serial}*"}}
        }
    ai["network"] = {
        "version": 2,
        "ethernets": {"lan": {"match": {"name": "en*"}, "dhcp4": True}},
    }
    ai["ssh"] = {"install-server": True, "allow-pw": False}
    if hvars.get("install_profile") == "desktop":
        ai["packages"] = ["ubuntu-desktop"]
        ai["late-commands"] = list(DESKTOP_LATE)
    # The new-hardware install is named new-host: rename it afterwards.
    ai["user-data"] = target_user_data(hostname or NEW_HOSTNAME, account, keys)
    if hostname:
        # Power off, not reboot: a stick left in would install again.
        ai["shutdown"] = "poweroff"
    return {"autoinstall": ai}


def write_seed(out, name, config):
    seed = out / name
    seed.mkdir(parents=True, exist_ok=True)
    body = yaml.safe_dump(config, sort_keys=False, width=1000)
    (seed / "user-data").write_text("#cloud-config\n" + body)
    (seed / "meta-data").write_text(f"instance-id: install-stick-{name}\n")


def entry_title(name, hvars):
    if name == NEW:
        return "New hardware: interactive install, choose the disk (ansible account)"
    return (
        f"Install {name} ({hvars['install_profile']}): ERASES the disk with"
        f" serial {hvars['install_disk_serial']}"
    )


def render_grub(text, hosts, default):
    """Add the stick's entries to the ISO's grub.cfg."""
    lines = text.splitlines()
    first = next(
        (i for i, line in enumerate(lines) if line.lstrip().startswith("menuentry")),
        None,
    )
    if first is None:
        raise SystemExit("no menuentry in the ISO's grub.cfg")
    end = next(i for i in range(first, len(lines)) if lines[i].strip() == "}")
    block = lines[first : end + 1]
    linux = next((ln for ln in block if ln.strip().startswith("linux")), None)
    initrd = next((ln for ln in block if ln.strip().startswith("initrd")), None)
    if not linux or not initrd:
        raise SystemExit("no linux/initrd lines in the ISO's first menuentry")
    words = linux.split()
    kernel, rest = words[1], " ".join(words[2:])

    head = [ln for ln in lines[:first] if not ln.startswith("set timeout")]
    if default:
        if default not in hosts:
            raise SystemExit(f"--default {default}: no such entry on the stick")
        head[:0] = ["set timeout=10", f"set default=install-{default}"]
    else:
        # No timeout: an entry runs only when someone picks it.
        head[:0] = ["set timeout=-1"]

    entries = ["grub_platform", 'if [ "$grub_platform" = "efi" ]; then']
    for name in [NEW] + sorted(hosts):
        args = "" if name == NEW else "autoinstall "
        args += f"ds=nocloud\\;s=/cdrom/install/{name}/"
        entries += [
            f"menuentry \"{entry_title(name, hosts.get(name))}\" --id install-{name} {{",
            "    set gfxpayload=keep",
            f"    linux  {kernel} {args} {rest}".rstrip(),
            f"    {initrd.strip()}",
            "}",
        ]
    entries.append("fi")
    return "\n".join(head + entries + lines[first:]) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--inventory", required=True, help="hosts.yml")
    ap.add_argument("--group-vars", help="group_vars/all.yml, for ansible_account")
    ap.add_argument("--key", action="append", default=[], help="SSH public key file")
    ap.add_argument("--out", required=True, help="directory for the seeds")
    ap.add_argument("--grub-in", help="the ISO's /boot/grub/grub.cfg")
    ap.add_argument("--grub-out", help="where to write the stick's grub.cfg")
    ap.add_argument("--default", help="host whose entry boots after 10 s")
    args = ap.parse_args()

    keys = read_keys(args.key)
    account = "ansible"
    if args.group_vars:
        gvars = yaml.safe_load(Path(args.group_vars).read_text()) or {}
        account = gvars.get("ansible_account", account)
    hosts, warnings = install_hosts(inventory_hosts(args.inventory))
    for warning in warnings:
        print(f"WARNING: {warning}", file=sys.stderr)
    out = Path(args.out)
    for name, hvars in hosts.items():
        write_seed(out, name, autoinstall(name, hvars, account, keys))
    write_seed(out, NEW, autoinstall(None, {}, account, keys))
    if args.grub_in and args.grub_out:
        grub = render_grub(Path(args.grub_in).read_text(), hosts, args.default)
        Path(args.grub_out).write_text(grub)
    elif args.default:
        raise SystemExit("--default needs --grub-in and --grub-out")
    print("entries: " + " ".join([NEW] + sorted(hosts)))


if __name__ == "__main__":
    main()
