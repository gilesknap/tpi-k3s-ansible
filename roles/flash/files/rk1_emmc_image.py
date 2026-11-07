#!/usr/bin/env python3
"""Build the eMMC staging image for a Turing Pi RK1.

The RK1 has no SPI flash, so U-Boot lives in the eMMC's raw area: the
Rockchip boot ROM loads u-boot-rockchip.bin from LBA 64 (32 KiB), and it
ends near 9.5 MiB. Ubuntu's official preinstalled server image puts its
EFI system partition at 1 MiB, which overlaps it. This script writes
Armbian's mainline u-boot-rockchip.bin at LBA 64 and copies the image's
partitions byte for byte to start at 16 MiB, keeping their numbers,
types, GUIDs, attributes and names, and the disk GUID. Nothing inside any
filesystem changes.

The output is deterministic: the same two inputs always give the same
image, so its sha256 can be pinned. Python's standard library only (no
sfdisk), so it runs on any controller that runs Ansible.

usage: rk1_emmc_image.py --ubuntu-xz IMG.xz --uboot-deb DEB
           --uboot-member PATH --uboot-sha256 HEX --output OUT.img
Prints a JSON summary (output sha256 and partition layout) on stdout.
"""

import argparse
import hashlib
import io
import json
import lzma
import os
import struct
import sys
import tarfile
import zlib

SECTOR = 512
UBOOT_LBA = 64
GPT_SIG = b"EFI PART"
CHUNK = 1 << 20
ZEROS = bytes(CHUNK)
ALIGN = 2048  # 1 MiB in sectors


def fail(msg):
    sys.exit(f"rk1_emmc_image: {msg}")


def deb_member(deb_path, member):
    """Return the bytes of one file inside a .deb (an ar archive)."""
    with open(deb_path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            fail(f"{deb_path} is not a .deb (ar) archive")
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                fail(f"{deb_path} has no data.tar member")
            name = hdr[:16].decode().strip().rstrip("/")
            size = int(hdr[48:58].decode().strip())
            data = f.read(size)
            f.read(size % 2)
            if name.startswith("data.tar"):
                break
    want = member.lstrip("./")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
        for info in tar:
            if info.isfile() and info.name.lstrip("./") == want:
                return tar.extractfile(info).read()
    fail(f"{member} is not in {deb_path}")


def parse_gpt(head):
    """Parse the primary GPT from the first sectors of a disk image."""
    hdr = head[SECTOR : 2 * SECTOR]
    if hdr[:8] != GPT_SIG:
        fail("source image has no primary GPT")
    hsize = struct.unpack_from("<I", hdr, 12)[0]
    check = bytearray(hdr[:hsize])
    check[16:20] = bytes(4)
    if zlib.crc32(check) != struct.unpack_from("<I", hdr, 16)[0]:
        fail("source GPT header CRC mismatch")
    entries_lba, count, esize = struct.unpack_from("<QII", hdr, 72)
    table = head[entries_lba * SECTOR : entries_lba * SECTOR + count * esize]
    if zlib.crc32(table) != struct.unpack_from("<I", hdr, 88)[0]:
        fail("source GPT entries CRC mismatch")
    parts = []
    for i in range(count):
        e = table[i * esize : (i + 1) * esize]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        parts.append({"index": i, "first": first, "last": last})
    return hdr[:hsize], table, esize, sorted(parts, key=lambda p: p["first"])


def gpt_header(template, my_lba, alt_lba, last_usable, entries_lba, table):
    h = bytearray(template)
    struct.pack_into("<QQQQ", h, 24, my_lba, alt_lba, 34, last_usable)
    struct.pack_into("<Q", h, 72, entries_lba)
    struct.pack_into("<I", h, 88, zlib.crc32(table))
    struct.pack_into("<I", h, 16, 0)
    struct.pack_into("<I", h, 16, zlib.crc32(h))
    return bytes(h) + bytes(SECTOR - len(h))


def protective_mbr(total):
    mbr = bytearray(SECTOR)
    # one 0xEE partition from LBA 1 over the whole disk, CHS fields saturated
    mbr[446:462] = struct.pack(
        "<B3sB3sII", 0, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1, min(total - 1, 0xFFFFFFFF)
    )
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def write_sparse(out, offset, data):
    """Write data at offset, leaving all-zero 1 MiB chunks as holes."""
    for i in range(0, len(data), CHUNK):
        chunk = data[i : i + CHUNK]
        if chunk != ZEROS[: len(chunk)]:
            out.seek(offset + i)
            out.write(chunk)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ubuntu-xz", required=True)
    ap.add_argument("--uboot-deb", required=True)
    ap.add_argument("--uboot-member", required=True)
    ap.add_argument("--uboot-sha256", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--start-mib", type=int, default=16)
    args = ap.parse_args()

    uboot = deb_member(args.uboot_deb, args.uboot_member)
    if hashlib.sha256(uboot).hexdigest() != args.uboot_sha256.lower():
        fail(f"{args.uboot_member} sha256 is {hashlib.sha256(uboot).hexdigest()}")
    start = args.start_mib * 1024 * 1024 // SECTOR
    if UBOOT_LBA * SECTOR + len(uboot) > start * SECTOR:
        fail("U-Boot overlaps the first partition")

    src = lzma.open(args.ubuntu_xz, "rb")
    head = src.read(34 * SECTOR)
    template, table, esize, parts = parse_gpt(head)

    # Lay the partitions out from `start` in disk order, each 1 MiB aligned.
    table = bytearray(table)
    pos = start
    for p in parts:
        size = p["last"] - p["first"] + 1
        p["new_first"] = pos
        struct.pack_into("<QQ", table, p["index"] * esize + 32, pos, pos + size - 1)
        pos = (pos + size + ALIGN - 1) // ALIGN * ALIGN
    total = pos + ALIGN
    table = bytes(table)
    entry_sectors = len(table) // SECTOR
    if 2 + entry_sectors > UBOOT_LBA:
        fail("GPT entries overlap U-Boot")

    with open(args.output, "wb") as out:
        out.truncate(total * SECTOR)
        out.write(protective_mbr(total))
        out.write(gpt_header(template, 1, total - 1, total - 34, 2, table))
        out.write(table)
        out.seek(UBOOT_LBA * SECTOR)
        out.write(uboot)
        # Stream the source: it is xz, so read it in order, once.
        offset = len(head)
        for p in parts:
            begin, end = p["first"] * SECTOR, (p["last"] + 1) * SECTOR
            while offset < begin:
                offset += len(src.read(min(CHUNK, begin - offset)))
            dest = p["new_first"] * SECTOR
            while offset < end:
                data = src.read(min(CHUNK, end - offset))
                if not data:
                    fail("source image is truncated")
                write_sparse(out, dest + offset - begin, data)
                offset += len(data)
        backup_entries = total - 1 - entry_sectors
        out.seek(backup_entries * SECTOR)
        out.write(table)
        out.write(gpt_header(template, total - 1, 1, total - 34, backup_entries, table))
        out.flush()
        os.fsync(out.fileno())

    digest = hashlib.sha256()
    with open(args.output, "rb") as f:
        while block := f.read(16 * CHUNK):
            digest.update(block)
    print(
        json.dumps(
            {
                "sha256": digest.hexdigest(),
                "size": total * SECTOR,
                "partitions": [
                    {"number": p["index"] + 1, "start": p["new_first"], "sectors": p["last"] - p["first"] + 1}
                    for p in parts
                ],
            }
        )
    )


if __name__ == "__main__":
    main()
