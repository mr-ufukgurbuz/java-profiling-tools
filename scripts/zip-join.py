#!/usr/bin/env python3
"""
zip-join.py - turns an archive split with "zip -s" back into a single file.

Why this is needed:
  GitHub caps files at 100 MB, so the large archives here are split into
  name.z01 / name.z02 / ... / name.zip. Simply 'cat'ing the parts together is
  NOT enough: every central directory entry stores an offset relative to ITS OWN
  disk. In a naively concatenated file the entries from the second part point at
  the wrong place, and unzip says "overlapped components" while jar says
  "invalid LOC header".

This script concatenates the parts AND makes the offsets absolute:
  - every central directory record gets disk number 0 and its true offset
  - the EOCD (End Of Central Directory) is rewritten for a single-disk archive

Usage:
  zip-join.py <last-part.zip> <output.zip>
  (the z01, z02 ... parts must sit in the same directory with the same base name)
"""
import os
import struct
import sys

EOCD_SIG = b"PK\x05\x06"
CEN_SIG = b"PK\x01\x02"
EOCD64_LOC_SIG = b"PK\x06\x07"


def find_parts(last):
    base = last[:-4] if last.lower().endswith(".zip") else last
    parts = []
    i = 1
    while True:
        p = "%s.z%02d" % (base, i)
        if not os.path.exists(p):
            break
        parts.append(p)
        i += 1
    parts.append(last)
    return parts


def concat(parts, out):
    """Writes the parts in order; returns where each disk starts in the output."""
    starts = []
    total = 0
    with open(out, "wb") as o:
        for p in parts:
            starts.append(total)
            with open(p, "rb") as f:
                while True:
                    block = f.read(8 << 20)
                    if not block:
                        break
                    o.write(block)
                    total += len(block)
    return starts, total


def find_eocd(f, size):
    """Locates the EOCD record by scanning backwards from the end."""
    window = min(size, 65536 + 22)
    f.seek(size - window)
    tail = f.read(window)
    pos = tail.rfind(EOCD_SIG)
    if pos < 0:
        raise SystemExit("ERROR: no EOCD found - the archive may be incomplete or corrupt.")
    return size - window + pos, tail[pos:pos + 22]


def fix_offsets(out, disk_starts, total):
    with open(out, "r+b") as f:
        eocd_off, eocd = find_eocd(f, total)

        # Zip64 needs more than this simple fixup; say so plainly.
        f.seek(max(0, eocd_off - 20))
        if EOCD64_LOC_SIG in f.read(20):
            raise SystemExit(
                "ERROR: this archive uses Zip64; this script cannot join it.\n"
                "       Use instead:  zip -s 0 <last-part.zip> --out <output.zip>"
            )

        (_, disk_no, cd_disk, entries_this_disk, entries_total,
         cd_size, cd_off, comment_len) = struct.unpack("<4sHHHHIIH", eocd)

        if disk_no == 0 and cd_disk == 0:
            return 0  # already single-part

        if cd_disk >= len(disk_starts):
            raise SystemExit("ERROR: missing part (central directory is on disk %d)." % cd_disk)

        new_cd = disk_starts[cd_disk] + cd_off

        # --- make every central directory offset absolute ---
        f.seek(new_cd)
        cd = bytearray(f.read(cd_size))
        i = 0
        fixed = 0
        while i + 46 <= len(cd):
            if bytes(cd[i:i + 4]) != CEN_SIG:
                break
            name_len, extra_len, cmt_len = struct.unpack_from("<HHH", cd, i + 28)
            entry_disk = struct.unpack_from("<H", cd, i + 34)[0]
            rel = struct.unpack_from("<I", cd, i + 42)[0]
            if rel == 0xFFFFFFFF or entry_disk == 0xFFFF:
                raise SystemExit(
                    "ERROR: Zip64 offsets present; this script cannot join it.\n"
                    "       Use instead:  zip -s 0 <last-part.zip> --out <output.zip>"
                )
            if entry_disk >= len(disk_starts):
                raise SystemExit("ERROR: entry points at disk %d, which is missing." % entry_disk)
            struct.pack_into("<H", cd, i + 34, 0)
            struct.pack_into("<I", cd, i + 42, disk_starts[entry_disk] + rel)
            fixed += 1
            i += 46 + name_len + extra_len + cmt_len
        f.seek(new_cd)
        f.write(cd)

        # --- rewrite the EOCD as a single-disk archive ---
        f.seek(eocd_off)
        f.write(struct.pack("<4sHHHHIIH", EOCD_SIG, 0, 0,
                            entries_total, entries_total, cd_size, new_cd, comment_len))
        return fixed


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.strip())
    last, out = sys.argv[1], sys.argv[2]
    if not os.path.exists(last):
        raise SystemExit("ERROR: no such file: %s" % last)
    parts = find_parts(last)
    sys.stderr.write(">> joining %d parts -> %s\n" % (len(parts), out))
    disk_starts, total = concat(parts, out)
    n = fix_offsets(out, disk_starts, total)
    sys.stderr.write(">> fixed %d entry offsets, %.1f MB total\n" % (n, total / 1048576.0))


if __name__ == "__main__":
    main()
