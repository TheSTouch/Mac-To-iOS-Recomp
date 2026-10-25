"""Transcode desktop GPU texture formats (BC/DXT) to ASTC, which iOS GPUs sample natively.

Unity's iOS player cannot decode BCn at all, and decompressing to RGBA would cost
4-8x the memory. Every mip level of every image (6 for cubemaps, one per slice for
texture arrays) is decoded and
re-encoded as ASTC 4x4. BC7/BC3/BC5/BC2 blocks and ASTC 4x4 blocks are both 16 bytes,
so the data keeps its size and is rewritten in place in the .resS stream file; only the
texture's format field changes. Smaller sources (BC1, BC4) are stored inline instead.
Crunched DXT textures are unpacked first and keep only their top level.

Asset bundles (UnityFS files, e.g. in StreamingAssets, which is Data/Raw on iOS) get
the same treatment inside the archive, plus their serialized files are retargeted to
iOS, since the player refuses bundles built for another platform. They are rewritten
LZ4-compressed; with a cache folder, each converted bundle is kept there and reused
while the source bundle is unchanged.

Runs in the engine's own virtualenv (UnityPy). Operates on the copy of the game data
inside the Xcode project, never on the installed game.

usage: textures.py <Data dir> [<cache dir>]
"""
import hashlib
import json
import os
import sys
import time

import shutil

import UnityPy
import astc_encoder
import texture2ddecoder
from UnityPy.enums import TextureFormat as TF
from UnityPy.files import SerializedFile
from UnityPy.helpers.ResourceReader import get_resource_data
from UnityPy.streams import EndianBinaryReader

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
TARGET_IOS = 9  # BuildTarget.iOS
with open(__file__, "rb") as _f:
    CONVERTER_VERSION = hashlib.sha1(_f.read()).hexdigest()[:8]

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


# Texture2DArray formats are GraphicsFormat values: BC kind -> decoder (via BC), sRGB.
GF_BC = {96: (TF.DXT1, True), 97: (TF.DXT1, False), 98: (TF.DXT3, True), 99: (TF.DXT3, False),
         100: (TF.DXT5, True), 101: (TF.DXT5, False), 102: (TF.BC4, False), 104: (TF.BC5, False),
         106: (TF.BC6H, False), 108: (TF.BC7, True), 109: (TF.BC7, False)}
GF_ASTC_SRGB, GF_ASTC_UNORM = 129, 130  # GraphicsFormat.RGBA_ASTC4X4_SRGB / _UNorm


def bc_textures(objects, stats):
    """(obj, texture, source format, kind) for every BC texture ("plain", "crunched" or "array");
    counts the compressed formats left as they are."""
    jobs = []
    for obj in objects:
        if obj.type.name == "Texture2DArray":
            tex = obj.read()
            if tex.m_Format in GF_BC and GF_BC[tex.m_Format][0] in BC:
                jobs.append((obj, tex, GF_BC[tex.m_Format][0], "array"))
            continue
        if obj.type.name not in TEXTURE_TYPES:
            continue
        tex = obj.read()
        try:
            fmt = TF(tex.m_TextureFormat)
        except ValueError:
            continue
        if fmt in BC:
            jobs.append((obj, tex, fmt, "plain"))
        elif fmt == TF.DXT5Crunched or fmt == TF.DXT1Crunched:
            jobs.append((obj, tex, TF.DXT5 if fmt == TF.DXT5Crunched else TF.DXT1, "crunched"))
        elif "Crunched" in fmt.name or fmt.name.startswith(("DXT", "BC")):
            stats["skipped"][fmt.name] = stats["skipped"].get(fmt.name, 0) + 1
    return jobs


def image_data(obj, tex):
    sd = tex.m_StreamData
    if sd is not None and sd.path:
        return get_resource_data(sd.path, obj.assets_file, sd.offset, sd.size)
    return tex.image_data


def convert(jobs, write_stream, stats):
    """Transcode each texture to ASTC. write_stream(path, offset, data) stores data that keeps
    its size back in its stream file and returns True; anything else is stored inline."""
    for obj, tex, fmt, kind in jobs:
        if kind == "array":
            raw, images, mips = image_data(obj, tex), tex.m_Depth, tex.m_MipCount or 1
        elif kind == "crunched":
            # Crunch unpacks to the top level only; the converted texture has no mipmaps.
            raw, images, mips = texture2ddecoder.unpack_unity_crunch(bytes(tex.get_image_data())), 1, 1
        else:
            raw, images, mips = tex.get_image_data(), getattr(tex, "m_ImageCount", 1) or 1, tex.m_MipCount or 1
        new = transcode_texture(raw, fmt, tex.m_Width, tex.m_Height, mips, images)
        sd = tex.m_StreamData
        if not (sd is not None and sd.path and sd.size == len(new) and write_stream(sd.path, sd.offset, new)):
            tex.image_data = new
            if sd is not None:
                sd.path, sd.offset, sd.size = "", 0, 0
        if kind == "array":
            tex.m_Format = GF_ASTC_SRGB if GF_BC[tex.m_Format][1] else GF_ASTC_UNORM
            tex.m_DataSize = len(new)
        else:
            tex.m_TextureFormat = TARGET
            tex.m_CompleteImageSize = len(new)
            if kind == "crunched":
                tex.m_MipCount = 1
        tex.save()
        stats["textures"] += 1
        stats["bytes"] += len(new)
        emit("progress", fraction=None, detail=f"Converting textures: {stats['textures']} done")


def process_file(path, stats):
    try:
        env = UnityPy.load(path)
    except Exception:
        return False  # not a Unity serialized file
    jobs = bc_textures(env.objects, stats)
    if not jobs:
        return False

    streams = {}

    def write_stream(sd_path, offset, data):
        stream = os.path.join(os.path.dirname(path), os.path.basename(sd_path))
        if stream not in streams:
            streams[stream] = open(stream, "r+b")
        streams[stream].seek(offset)
        streams[stream].write(data)
        return True

    convert(jobs, write_stream, stats)
    for f in streams.values():
        f.close()
    # Serialize before opening for write: UnityPy reads unchanged objects lazily from this file.
    data = env.file.save()
    with open(path + ".tmp", "wb") as f:
        f.write(data)
    os.replace(path + ".tmp", path)
    return True


def is_bundle(path):
    with open(path, "rb") as f:
        return f.read(8) == b"UnityFS\0"


def process_bundle(path, stats):
    env = UnityPy.load(path)
    bundle = env.file
    for sf in bundle.files.values():
        if isinstance(sf, SerializedFile):
            sf._m_target_platform = TARGET_IOS
    jobs = bc_textures(env.objects, stats)

    # Streamed image data lives in the bundle's own .resS nodes ("archive:/CAB-x/CAB-x.resS").
    nodes = {}

    def write_stream(sd_path, offset, data):
        name = os.path.basename(sd_path)
        if name not in bundle.files:
            return False
        if name not in nodes:
            nodes[name] = bytearray(bundle.files[name].bytes)
        nodes[name][offset:offset + len(data)] = data
        return True

    convert(jobs, write_stream, stats)
    for name, data in nodes.items():
        node = EndianBinaryReader(bytes(data))
        node.flags = bundle.files[name].flags
        bundle.files[name] = node
    data = bundle.save(packer="lz4")
    with open(path + ".tmp", "wb") as f:
        f.write(data)
    os.replace(path + ".tmp", path)
    return len(jobs)


def cached_bundle(path, cache, stats):
    """process_bundle through the cache: key is the bundle's name, size and mtime (inject copies
    the game's data with copy2, which keeps mtimes) and this converter's own version."""
    st = os.stat(path)
    key = os.path.join(cache, f"{os.path.basename(path)}-{st.st_size}-{int(st.st_mtime)}-{CONVERTER_VERSION}")
    if os.path.exists(key):
        os.remove(path)
        try:
            os.link(key, path)
        except OSError:
            shutil.copyfile(key, path)
        stats["cached"] += 1
        return 0
    converted = process_bundle(path, stats)
    os.makedirs(cache, exist_ok=True)
    shutil.copyfile(path, key + ".tmp")
    os.replace(key + ".tmp", key)
    return converted


def main(data_dir, cache=None):
    start = time.time()
    stats = {"textures": 0, "bytes": 0, "cached": 0, "bundles": 0, "skipped": {}}
    files, bundles = [], []
    for dirpath, _, names in os.walk(data_dir):
        if os.sep + "Managed" in dirpath:
            continue
        for n in sorted(names):
            p = os.path.join(dirpath, n)
            if n.endswith(SKIP_SUFFIXES) or n.endswith(".manifest"):
                continue
            if is_bundle(p):
                bundles.append(p)
            elif os.sep + "Raw" not in dirpath:
                files.append(p)
    changed = 0
    for path in files:
        if process_file(path, stats):
            changed += 1
            print(f"[textures] {os.path.relpath(path, data_dir)}: converted", flush=True)
    for i, path in enumerate(sorted(bundles, key=os.path.getsize)):
        emit("progress", fraction=i / len(bundles), detail=f"Converting asset bundles: {i} of {len(bundles)}")
        n = cached_bundle(path, cache, stats) if cache else process_bundle(path, stats)
        stats["bundles"] += 1
        if n:
            print(f"[textures] {os.path.relpath(path, data_dir)}: bundle, {n} textures", flush=True)
    print(f"[textures] {stats['textures']} textures ({stats['bytes'] / 1e6:.0f} MB) to ASTC 4x4 "
          f"in {changed} files and {stats['bundles']} bundles ({stats['cached']} from cache), "
          f"{time.time() - start:.0f}s", flush=True)
    if stats["skipped"]:
        print(f"[textures] left as they are (no decoder): {stats['skipped']}", flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
