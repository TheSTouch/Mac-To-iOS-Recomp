"""Read and retarget thin arm64 Mach-O files (macOS -> iOS).

A native arm64 Mac binary already holds the right machine code for an iPad; what
stops it loading is metadata. retarget() rewrites that metadata in place:

  - LC_BUILD_VERSION (or LC_VERSION_MIN_MACOSX) says iOS instead of macOS;
  - dylib and rpath load commands are replaced, so Mac-only frameworks resolve
    to shim libraries in the app bundle and /System paths use the iOS layout;
  - chained-fixup imports are rebound to library ordinals of the new list, so a
    symbol iOS lacks (or one a shim must intercept) binds to the shim instead.

The load-command area is rebuilt from scratch, which needs the padding linkers
leave between the commands and the first section; the code signature is left
for codesign to replace.
"""
import struct

MH_MAGIC_64 = 0xFEEDFACF
LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x22 | LC_REQ_DYLD
LC_CODE_SIGNATURE = 0x1D
DYLIB_CMDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB)

PLATFORM_MACOS, PLATFORM_IOS = 1, 2


def _ver(v):
    """'15.0' -> 0x000F0000 (xxxx.yy.zz nibbles)."""
    parts = [int(x) for x in str(v).split(".")] + [0, 0]
    return parts[0] << 16 | parts[1] << 8 | parts[2]


def _uleb(b, i):
    """(value, next index) of the ULEB128 at b[i]."""
    v = shift = 0
    while True:
        byte = b[i]
        i += 1
        v |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return v, i


def _cstr(b, off):
    end = b.index(b"\0", off)
    return b[off:end].decode()


class MachO:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = bytearray(f.read())
        magic, cpu, _sub, self.filetype, ncmds, sizeofcmds, self.flags, _ = struct.unpack_from("<8I", self.data, 0)
        if magic != MH_MAGIC_64:
            raise ValueError(f"{path}: not a thin 64-bit Mach-O (fat binaries must be thinned first)")
        if cpu != 0x0100000C:
            raise ValueError(f"{path}: not arm64")
        self.cmds = []  # [cmd, bytes]
        off = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", self.data, off)
            self.cmds.append([cmd, bytes(self.data[off:off + size])])
            off += size
        self.segments, self.sections = [], []
        for cmd, b in self.cmds:
            if cmd == LC_SEGMENT_64:
                name = b[8:24].rstrip(b"\0").decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", b, 24)
                self.segments.append((name, vmaddr, vmsize, fileoff, filesize))
                nsects = struct.unpack_from("<I", b, 64)[0]
                for i in range(nsects):
                    s = 72 + i * 80
                    sect = b[s:s + 16].rstrip(b"\0").decode()
                    addr, size, offset = struct.unpack_from("<QQI", b, s + 32)
                    self.sections.append((name, sect, addr, size, offset))

    # --- queries -----------------------------------------------------------

    def first_section_offset(self):
        offs = [s[4] for s in self.sections if s[4]]
        return min(offs) if offs else len(self.data)

    def base(self):
        return next(s[1] for s in self.segments if s[0] == "__TEXT")

    def dylibs(self):
        """Ordered (cmd, path) of library load commands; ordinal = index + 1."""
        return [(c, _cstr(b, struct.unpack_from("<I", b, 8)[0])) for c, b in self.cmds if c in DYLIB_CMDS]

    def rpaths(self):
        return [_cstr(b, struct.unpack_from("<I", b, 8)[0]) for c, b in self.cmds if c == LC_RPATH]

    def install_name(self):
        for c, b in self.cmds:
            if c == LC_ID_DYLIB:
                return _cstr(b, struct.unpack_from("<I", b, 8)[0])
        return None

    def platform(self):
        for c, b in self.cmds:
            if c == LC_BUILD_VERSION:
                return struct.unpack_from("<I", b, 8)[0]
            if c == LC_VERSION_MIN_MACOSX:
                return PLATFORM_MACOS
        return None

    def section(self, seg, sect):
        for s in self.sections:
            if s[0] == seg and s[1] == sect:
                return s
        return None

    def vm_to_file(self, addr):
        for name, vmaddr, vmsize, fileoff, filesize in self.segments:
            if vmaddr <= addr < vmaddr + filesize:
                return fileoff + addr - vmaddr
        raise ValueError(f"address {addr:#x} not in file")

    def _fixups(self):
        for c, b in self.cmds:
            if c == LC_DYLD_CHAINED_FIXUPS:
                return struct.unpack_from("<II", b, 8)
        return None

    def imports(self):
        """Chained-fixup imports: list of (index, lib_ordinal, weak, name, entry_offset, format)."""
        fx = self._fixups()
        if not fx:
            return []
        off, _size = fx
        d = self.data
        _ver_, _starts, imports_off, symbols_off, count, fmt, _compr = struct.unpack_from("<7I", d, off)
        out = []
        for i in range(count):
            if fmt == 1:  # DYLD_CHAINED_IMPORT
                e = off + imports_off + 4 * i
                v = struct.unpack_from("<I", d, e)[0]
                lib, weak, name_off = v & 0xFF, (v >> 8) & 1, v >> 9
            elif fmt == 2:  # DYLD_CHAINED_IMPORT_ADDEND
                e = off + imports_off + 8 * i
                v = struct.unpack_from("<I", d, e)[0]
                lib, weak, name_off = v & 0xFF, (v >> 8) & 1, v >> 9
            elif fmt == 3:  # DYLD_CHAINED_IMPORT_ADDEND64
                e = off + imports_off + 16 * i
                v = struct.unpack_from("<Q", d, e)[0]
                lib, weak, name_off = v & 0xFFFF, (v >> 16) & 1, v >> 32
            else:
                raise ValueError(f"unknown chained import format {fmt}")
            out.append((i, lib, weak, _cstr(d, off + symbols_off + name_off), e, fmt))
        return out

    def bound_imports(self):
        """Imports of an older-format file (LC_DYLD_INFO bind opcodes): set of (lib_ordinal, name).

        Reads the regular and lazy bind streams; weak binds go by name alone. For
        files with chained fixups, imports() has the same and more.
        """
        info = next((b for c, b in self.cmds if c in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY)), None)
        if not info:
            return {(lib, name) for _i, lib, _w, name, _e, _f in self.imports()}
        _rb, _rs, bind_off, bind_size, _wo, _ws, lazy_off, lazy_size = struct.unpack_from("<8I", info, 8)
        out = set()
        for off, size in ((bind_off, bind_size), (lazy_off, lazy_size)):
            d, i, end = self.data, off, off + size
            lib, name = 0, None
            while i < end:
                op, imm = d[i] & 0xF0, d[i] & 0x0F
                i += 1
                if op == 0x10:  # SET_DYLIB_ORDINAL_IMM
                    lib = imm
                elif op == 0x20:  # SET_DYLIB_ORDINAL_ULEB
                    lib, i = _uleb(d, i)
                elif op == 0x30:  # SET_DYLIB_SPECIAL_IMM (0, -1, -2...)
                    lib = -imm if imm else 0
                elif op == 0x40:  # SET_SYMBOL_TRAILING_FLAGS_IMM
                    end_name = d.index(b"\0", i)
                    name = d[i:end_name].decode()
                    i = end_name + 1
                elif op in (0x60, 0x70, 0xA0):  # SET_ADDEND_SLEB, SET_SEGMENT_AND_OFFSET_ULEB, ADD_ADDR_ULEB
                    _v, i = _uleb(d, i)
                elif op in (0x90, 0xB0):  # DO_BIND, DO_BIND_ADD_ADDR_IMM_SCALED
                    if name and lib > 0:
                        out.add((lib, name))
                elif op == 0x80:  # DO_BIND_ADD_ADDR_ULEB
                    if name and lib > 0:
                        out.add((lib, name))
                    _v, i = _uleb(d, i)
                elif op == 0xC0:  # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
                    if name and lib > 0:
                        out.add((lib, name))
                    _v, i = _uleb(d, i)
                    _v, i = _uleb(d, i)
                # 0x00 DONE (ends one lazy entry), 0x50 SET_TYPE_IMM: nothing to read
        return out

    def read_pointer(self, file_off):
        """Resolve a chained-fixup pointer slot to a vm address (rebases only)."""
        v = struct.unpack_from("<Q", self.data, file_off)[0]
        if v >> 63:
            return None  # bind
        return self.base() + (v & 0xFFFFFFFFF)  # DYLD_CHAINED_PTR_64_OFFSET target

    def selectors(self):
        """Selector names referenced from __objc_selrefs."""
        s = self.section("__DATA", "__objc_selrefs")
        if not s:
            return []
        out = []
        for i in range(s[3] // 8):
            addr = self.read_pointer(s[4] + 8 * i)
            if addr is not None:
                out.append(_cstr(self.data, self.vm_to_file(addr)))
        return out

    # --- edits -------------------------------------------------------------

    def remap_imports(self, fn):
        """Rebind imports: fn(name, old ordinal, weak) -> new ordinal (1-based library index).

        Special ordinals (self, main executable, flat and weak lookup) are left alone.
        """
        for _i, lib, weak, name, e, fmt in self.imports():
            if lib == 0 or (fmt in (1, 2) and lib >= 0xF0) or (fmt == 3 and lib >= 0xFFF0):
                continue
            new = fn(name, lib, weak)
            if new == lib:
                continue
            if fmt in (1, 2):
                if not 0 < new < 0xF0:
                    raise ValueError(f"library ordinal {new} out of range")
                v = struct.unpack_from("<I", self.data, e)[0]
                struct.pack_into("<I", self.data, e, (v & ~0xFF) | new)
            else:
                v = struct.unpack_from("<Q", self.data, e)[0]
                struct.pack_into("<Q", self.data, e, (v & ~0xFFFF) | new)

    def retarget(self, minos="16.0", sdk="26.0", dylibs=None, rpaths=None, install_name=None, platform=PLATFORM_IOS):
        """Mark the file as iOS and rewrite library load commands.

        dylibs: replacement list of (cmd, path) library load commands, in ordinal
        order (None keeps them; call remap_imports to match); rpaths: replacement
        LC_RPATH list (None keeps them); install_name: new LC_ID_DYLIB; platform:
        PLATFORM_IOS, or 7 for the iOS simulator.
        """
        new = []
        seen_build = False
        placed = False
        for cmd, b in self.cmds:
            if cmd == LC_BUILD_VERSION:
                ntools = struct.unpack_from("<I", b, 20)[0]
                b = struct.pack("<6I", cmd, 24 + 8 * ntools, platform, _ver(minos), _ver(sdk), ntools) + b[24:24 + 8 * ntools]
                seen_build = True
            elif cmd == LC_VERSION_MIN_MACOSX:
                cmd, b = LC_BUILD_VERSION, struct.pack("<6I", LC_BUILD_VERSION, 24, platform, _ver(minos), _ver(sdk), 0)
                seen_build = True
            elif cmd == LC_ID_DYLIB and install_name:
                b = _str_cmd(cmd, install_name, b[12:24])
            elif cmd in DYLIB_CMDS and dylibs is not None:
                if not placed:
                    placed = True
                    for c, path in dylibs:
                        new.append([c, _str_cmd(c, path, struct.pack("<III", 2, 0x10000, 0))])
                continue
            elif cmd == LC_RPATH and rpaths is not None:
                continue
            new.append([cmd, b])
        if dylibs is not None and not placed:
            for c, path in dylibs:
                new.append([c, _str_cmd(c, path, struct.pack("<III", 2, 0x10000, 0))])
        for p in rpaths or ():
            new.append([LC_RPATH, _str_cmd(LC_RPATH, p, b"")])
        if not seen_build:
            new.append([LC_BUILD_VERSION, struct.pack("<6I", LC_BUILD_VERSION, 24, platform, _ver(minos), _ver(sdk), 0)])
        self._write_cmds(new)

    def _write_cmds(self, cmds):
        blob = b"".join(b for _c, b in cmds)
        old = struct.unpack_from("<I", self.data, 20)[0]
        limit = self.first_section_offset() - 32
        if len(blob) > limit:
            raise ValueError(f"{self.path}: load commands need {len(blob)} bytes, only {limit} available")
        struct.pack_into("<II", self.data, 16, len(cmds), len(blob))
        self.data[32:32 + max(old, len(blob))] = blob + b"\0" * max(0, old - len(blob))
        self.cmds = cmds

    def patch_bytes(self, old, new, count=1):
        """Replace exact byte strings (same length); fails unless exactly `count` occurrences."""
        if len(old) != len(new):
            raise ValueError("patch must keep the length")
        found = self.data.count(old)
        if found != count:
            raise ValueError(f"{self.path}: expected {count} of {old!r}, found {found}")
        self.data = bytearray(bytes(self.data).replace(old, new))

    def save(self, path=None):
        with open(path or self.path, "wb") as f:
            f.write(self.data)


def _str_cmd(cmd, s, fixed):
    """A load command holding one string (dylib or rpath); fixed = bytes between offset and string."""
    raw = s.encode() + b"\0"
    head = 8 + 4 + len(fixed)
    size = (head + len(raw) + 7) & ~7
    return struct.pack("<III", cmd, size, head) + fixed + raw + b"\0" * (size - head - len(raw))

