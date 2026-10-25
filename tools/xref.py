#!/usr/bin/env python3
"""Find arm64 code that references a string or an address in a Mach-O.

  xref.py <binary> --string "text" [--utf16]   functions loading the string's address
  xref.py <binary> --addr 0x1001234            code loading that address (ADRP+ADD/LDR)

Scans __text for ADRP followed (within a few instructions) by ADD/LDR on the same
register. Prints the instruction addresses; disassemble around them with
`otool -tV -p` or lldb. For porting work: find which code checks what.
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from recomp import macho  # noqa: E402


def find_all(data, needle):
    out, o = [], data.find(needle)
    while o != -1:
        out.append(o)
        o = data.find(needle, o + 1)
    return out


def file_to_vm(m, off):
    for name, vmaddr, vmsize, fileoff, filesize in m.segments:
        if fileoff <= off < fileoff + filesize:
            return vmaddr + off - fileoff
    return None


def cfstrings_for(m, targets):
    """Addresses of __cfstring literals (CFSTR / @"...") whose characters are at a target."""
    out = set()
    sect = m.section("__DATA_CONST", "__cfstring") or m.section("__DATA", "__cfstring")
    if not sect:
        return out
    _seg, _s, addr, size, off = sect
    for i in range(size // 32):
        ptr = m.read_pointer(off + 32 * i + 16)
        if ptr in targets:
            out.add(addr + 32 * i)
    return out


def scan(m, targets):
    sect = m.section("__TEXT", "__text")
    _seg, _s, addr, size, off = sect
    text = m.data[off:off + size]
    n = size // 4
    words = struct.unpack_from(f"<{n}I", text)
    hits = []
    for i in range(n):
        w = words[i]
        if (w & 0x9F000000) != 0x90000000:  # ADRP
            continue
        rd = w & 0x1F
        immlo, immhi = (w >> 29) & 3, (w >> 5) & 0x7FFFF
        imm = ((immhi << 2) | immlo) << 12
        if imm & (1 << 32):
            imm -= 1 << 33
        pc = addr + 4 * i
        page = (pc & ~0xFFF) + imm
        for j in range(i + 1, min(i + 24, n)):
            v = words[j]
            if (v & 0xFFC00000) == 0x91000000 and ((v >> 5) & 0x1F) == rd:  # ADD imm
                t = page + ((v >> 10) & 0xFFF)
            elif (v & 0xFFC00000) == 0xF9400000 and ((v >> 5) & 0x1F) == rd:  # LDR x, [rn, imm*8]
                t = page + ((v >> 10) & 0xFFF) * 8
            else:
                if ((v & 0x1F) == rd) and (v & 0x9F000000) != 0x90000000:
                    break  # register overwritten by something else
                continue
            if t in targets:
                hits.append((pc, t))
            break
    return hits


def main():
    p = argparse.ArgumentParser()
    p.add_argument("binary")
    p.add_argument("--string")
    p.add_argument("--utf16", action="store_true")
    p.add_argument("--addr")
    a = p.parse_args()
    m = macho.MachO(a.binary)
    targets = set()
    if a.string:
        needle = a.string.encode("utf-16le") if a.utf16 else a.string.encode()
        for off in find_all(bytes(m.data), needle):
            vm = file_to_vm(m, off)
            if vm:
                targets.add(vm)
        print(f"string at {', '.join(hex(t) for t in sorted(targets)) or 'nowhere'}")
        cf = cfstrings_for(m, targets)
        if cf:
            print(f"CFString literal at {', '.join(hex(t) for t in sorted(cf))}")
            targets |= cf
    if a.addr:
        targets.add(int(a.addr, 16))
    for pc, t in scan(m, targets):
        print(f"{pc:#x} -> {t:#x}")


if __name__ == "__main__":
    main()
