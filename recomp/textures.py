"""Transcode desktop GPU texture formats (BC/DXT) to ASTC, which iOS GPUs sample natively.

Unity's iOS player cannot decode BCn at all, and decompressing to RGBA would cost
4-8x the memory. Every mip level of every image (6 for cubemaps) is decoded and
re-encoded as ASTC 4x4. BC7/BC3/BC5/BC2 blocks and ASTC 4x4 blocks are both 16 bytes,
so the data keeps its size and is rewritten in place in the .resS stream file; only the
texture's format field changes. Smaller sources (BC1, BC4) are stored inline instead.

Runs in the engine's own virtualenv (UnityPy). Operates on the copy of the game data
inside the Xcode project, never on the installed game.

usage: textures.py <Data dir>
"""
import json
import os
import sys
import time

import UnityPy
import astc_encoder
import texture2ddecoder
from UnityPy.enums import TextureFormat as TF

# Source format -> (decoder, bytes per 4x4 block)
BC = {
    TF.DXT1: (texture2ddecoder.decode_bc1, 8),
    TF.DXT3: (texture2ddecoder.decode_bc2, 16) if hasattr(texture2ddecoder, "decode_bc2") else None,
    TF.DXT5: (texture2ddecoder.decode_bc3, 16),
    TF.BC4: (texture2ddecoder.decode_bc4, 8),
    TF.BC5: (texture2ddecoder.decode_bc5, 16),
    TF.BC6H: (texture2ddecoder.decode_bc6, 16),
    TF.BC7: (texture2ddecoder.decode_bc7, 16),
}
BC = {k: v for k, v in BC.items() if v}
TARGET = TF.ASTC_RGB_4x4  # TextureFormat.ASTC_4x4 (48) in current Unity
TEXTURE_TYPES = {"Texture2D", "Cubemap"}
SKIP_SUFFIXES = (".resS", ".resource", ".json", ".config", ".dat", ".info")

_context = None


def emit(kind, **data):
    if os.environ.get("RECOMP_EVENTS") == "1":
        print("@@" + json.dumps(dict(data, kind=kind)), flush=True)


def astc_context():
    """One encoder for the whole run; astcenc spreads each image over all cores."""
    global _context
    if _context is None:
        cfg = astc_encoder.ASTCConfig(astc_encoder.ASTCProfile.LDR, 4, 4, 1, 60.0)  # between "fast" and "medium"
        _context = astc_encoder.ASTCContext(cfg, os.cpu_count() or 4)
    return _context


def mip_sizes(w, h, mips, block_bytes):
    sizes = []
    for _ in range(max(mips, 1)):
        sizes.append((w, h, ((w + 3) // 4) * ((h + 3) // 4) * block_bytes))
        w, h = max(1, w // 2), max(1, h // 2)
    return sizes


def bgra_to_rgba(buf):
    b = bytearray(buf)
    b[0::4], b[2::4] = b[2::4], b[0::4]
    return bytes(b)


def transcode_level(src, w, h, decode):
    rgba = bgra_to_rgba(decode(src, w, h))
    img = astc_encoder.ASTCImage(astc_encoder.ASTCType.U8, w, h, 1, rgba)
    return astc_context().compress(img, astc_encoder.ASTCSwizzle.from_str("RGBA"))


def transcode_texture(raw, fmt, w, h, mips, images):
    decode, block = BC[fmt]
    levels = mip_sizes(w, h, mips, block)
    per_image = sum(s for _, _, s in levels)
    out, pos = bytearray(), 0
    for _ in range(images):
        for lw, lh, size in levels:
            out += transcode_level(raw[pos:pos + size], lw, lh, decode)
            pos += size
    if pos > len(raw) or len(raw) < per_image * images:
        raise ValueError(f"image data is {len(raw)} bytes, expected {per_image * images}")
    return bytes(out)


def process_file(path, stats):
    try:
        env = UnityPy.load(path)
    except Exception:
        return False  # not a Unity serialized file
    jobs = []
    for obj in env.objects:
        if obj.type.name not in TEXTURE_TYPES:
            continue
        tex = obj.read()
        try:
            fmt = TF(tex.m_TextureFormat)
        except ValueError:
            continue
        if fmt in BC:
            jobs.append((obj, tex, fmt))
    if not jobs:
        return False

    streams = {}
    for obj, tex, fmt in jobs:
        raw = tex.get_image_data()
        images = getattr(tex, "m_ImageCount", 1) or 1
        new = transcode_texture(raw, fmt, tex.m_Width, tex.m_Height, tex.m_MipCount or 1, images)
        sd = tex.m_StreamData
        if sd is not None and sd.path and sd.size == len(new):
            stream = os.path.join(os.path.dirname(path), os.path.basename(sd.path))
            if stream not in streams:
                streams[stream] = open(stream, "r+b")
            f = streams[stream]
            f.seek(sd.offset)
            f.write(new)
        else:
            tex.image_data = new
            tex.m_CompleteImageSize = len(new)
            if sd is not None:
                sd.path, sd.offset, sd.size = "", 0, 0
        tex.m_TextureFormat = TARGET
        tex.save()
        stats["textures"] += 1
        stats["bytes"] += len(new)
        emit("progress", fraction=None, detail=f"Converting textures: {stats['textures']} done")
    for f in streams.values():
        f.close()
    # Serialize before opening for write: UnityPy reads unchanged objects lazily from this file.
    data = env.file.save()
    with open(path + ".tmp", "wb") as f:
        f.write(data)
    os.replace(path + ".tmp", path)
    return True


def main(data_dir):
    start = time.time()
    stats = {"textures": 0, "bytes": 0}
    files = []
    for dirpath, _, names in os.walk(data_dir):
        if os.sep + "Raw" in dirpath or os.sep + "Managed" in dirpath:
            continue
        files += [os.path.join(dirpath, n) for n in sorted(names) if not n.endswith(SKIP_SUFFIXES)]
    changed = 0
    for path in files:
        if process_file(path, stats):
            changed += 1
            print(f"[textures] {os.path.relpath(path, data_dir)}: converted", flush=True)
    print(f"[textures] {stats['textures']} textures ({stats['bytes'] / 1e6:.0f} MB) to ASTC 4x4 "
          f"in {changed} files, {time.time() - start:.0f}s", flush=True)


if __name__ == "__main__":
    main(sys.argv[1])
