"""Valve's GameNetworkingSockets (BSD-3), the open-source SteamNetworkingSockets, built from
source when porting and never committed: the Steam runtime's networking (RecompSteam/networking*)
runs on it, so a game reaches Steam servers by IP with Valve's own UDP protocol.

It needs protobuf (3.21, the last without Abseil; BSD-3) and OpenSSL (Apache-2.0) for AES-GCM:
libsodium's AES only runs on x86. All three are static libraries, per platform:
  macos  arm64 + x86_64 (the Mac test clone's libsteam_api.dylib)
  ios    arm64 (the ports)
under toolchain/gamenetworkingsockets/<GNS commit>/<platform>/{include,lib}.

  python3 -m recomp.gamenetworkingsockets macos|ios   build one platform (and say where it is)
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile

from recomp import paths, toolchain

GNS_COMMIT = "d534c19aa760df3fb75fd20db13ba1932b8a5463"  # master, 2026-10-02 (after v1.6.1)
PROTOBUF = "3.21.12"
OPENSSL = "3.5.9"
SOURCES = {
    "gns": (f"https://github.com/ValveSoftware/GameNetworkingSockets/archive/{GNS_COMMIT}.tar.gz",
            f"GameNetworkingSockets-{GNS_COMMIT}"),
    "protobuf": (f"https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-{PROTOBUF}.tar.gz",
                 f"protobuf-{PROTOBUF}"),
    "openssl": (f"https://github.com/openssl/openssl/releases/download/openssl-{OPENSSL}/openssl-{OPENSSL}.tar.gz",
                f"openssl-{OPENSSL}"),
}
IOS_MIN = "13.0"
MACOS_MIN = "11.0"
# Bumped when PATCHES change, so an older build is not reused.
REVISION = 3
ROOT = os.path.join(paths.TOOLCHAIN, "gamenetworkingsockets", f"{GNS_COMMIT[:12]}-{REVISION}")
# Source changes, as (file, original, replacement). The open-source library does not trust
# Valve's certificate authority, so it cannot verify the certificate Steam signs for the
# player (RecompSteam/networking.m) and, without this, never reads it: SetCertificate fails
# with "Cert is for identity 'invalid'". Steam's servers check it against their own roots.
# The certificate is also scoped to the game's app id, which GNS only knows through a setter
# with no public entry point: RecompGNS_SetAppID adds one.
PATCHES = [
    ("src/steamnetworkingsockets/clientlib/csteamnetworkingsockets.cpp",
     "\t\tSpewWarning( \"SetCertificate: We are not currently able to verify our own cert!  %s.  Continuing anyway!\", errMsg );\n",
     "\t\tSpewWarning( \"SetCertificate: We are not currently able to verify our own cert!  %s.  Continuing anyway!\", errMsg );\n"
     "\t\tmsgCert.ParseFromString( msgCertSigned.cert() );  // recomp: read it anyway\n"),
    ("src/steamnetworkingsockets/clientlib/csteamnetworkingsockets.cpp",
     "\tstatic CSteamNetworkingUtils s_utils;\n\treturn &s_utils;\n}\n",
     "\tstatic CSteamNetworkingUtils s_utils;\n\treturn &s_utils;\n}\n\n"
     "// recomp: the app the certificate Steam signs is scoped to\n"
     "STEAMNETWORKINGSOCKETS_INTERFACE void RecompGNS_SetAppID( uint32 nAppID )\n{\n"
     "\tstatic_cast<CSteamNetworkingUtils *>( SteamNetworkingUtils_LibV4() )->SetAppID( nAppID );\n}\n"),
]
LIBS = ["libGameNetworkingSockets_s.a", "libprotobuf-lite.a", "libprotobuf.a", "libssl.a", "libcrypto.a"]


def log(msg):
    print(f"[gns] {msg}", flush=True)


def run(cmd, **kw):
    log("$ " + " ".join(cmd))
    subprocess.run(cmd, check=True, **kw)


def source(name):
    url, top = SOURCES[name]
    src = os.path.join(ROOT, "src")
    dest = os.path.join(src, top)
    if os.path.isdir(dest):
        return dest
    os.makedirs(src, exist_ok=True)
    archive = os.path.join(src, os.path.basename(url))
    toolchain.fetch(url, archive, name)
    with tarfile.open(archive) as t:
        # filter= is Python 3.12+ (and late 3.8-3.11 patches); macOS's own 3.9.6 lacks it.
        if hasattr(tarfile, "data_filter"):
            t.extractall(src, filter="data")
        else:
            t.extractall(src)
    os.remove(archive)
    if name == "gns":
        for rel, old, new in PATCHES:
            path = os.path.join(dest, rel)
            with open(path) as f:
                text = f.read()
            if text.count(old) != 1:
                raise RuntimeError(f"GameNetworkingSockets patch no longer applies to {rel}")
            with open(path, "w") as f:
                f.write(text.replace(old, new))
    return dest


def cmake(src, build, prefix, args):
    run(["cmake", "-S", src, "-B", build, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
         f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", *args])
    run(["cmake", "--build", build])
    run(["cmake", "--install", build])


def platform_args(platform):
    if platform == "ios":
        return ["-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                f"-DCMAKE_OSX_DEPLOYMENT_TARGET={IOS_MIN}"]
    return ["-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MACOS_MIN}"]


def host_protoc():
    """protoc for this Mac, which generates GNS's message code for every platform."""
    prefix = os.path.join(ROOT, "host")
    protoc = os.path.join(prefix, "bin", "protoc")
    if not os.path.exists(protoc):
        cmake(source("protobuf"), os.path.join(ROOT, "obj", "protobuf-host"), prefix,
              ["-Dprotobuf_BUILD_TESTS=OFF", "-Dprotobuf_BUILD_SHARED_LIBS=OFF"])
    return protoc


def openssl(platform, prefix):
    if os.path.exists(os.path.join(prefix, "lib", "libcrypto.a")):
        return
    targets = {"ios": [("ios64-xcrun", None)],
               "macos": [("darwin64-arm64-cc", "arm64"), ("darwin64-x86_64-cc", "x86_64")]}[platform]
    built = []
    for target, arch in targets:
        work = os.path.join(ROOT, "obj", f"openssl-{platform}-{arch or 'arm64'}")
        shutil.rmtree(work, ignore_errors=True)
        shutil.copytree(source("openssl"), work)
        minflag = f"-mios-version-min={IOS_MIN}" if platform == "ios" else f"-mmacosx-version-min={MACOS_MIN}"
        run(["./Configure", target, "no-shared", "no-tests", "no-docs", "no-apps", "no-engine", "no-module",
             minflag, f"--prefix={prefix}", "--libdir=lib"], cwd=work)
        run(["make", f"-j{os.cpu_count()}", "build_libs"], cwd=work)
        built.append(work)
    os.makedirs(os.path.join(prefix, "lib"), exist_ok=True)
    for lib in ("libssl.a", "libcrypto.a"):
        run(["lipo", "-create", *[os.path.join(w, lib) for w in built], "-output", os.path.join(prefix, "lib", lib)])
    shutil.rmtree(os.path.join(prefix, "include", "openssl"), ignore_errors=True)
    shutil.copytree(os.path.join(built[0], "include", "openssl"), os.path.join(prefix, "include", "openssl"))


def build(platform):
    """The static libraries and headers for platform ("macos" or "ios"); built once."""
    prefix = os.path.join(ROOT, platform)
    if all(os.path.exists(os.path.join(prefix, "lib", n)) for n in LIBS):
        return prefix
    protoc = host_protoc()
    if not os.path.exists(os.path.join(prefix, "lib", "libprotobuf.a")):
        cmake(source("protobuf"), os.path.join(ROOT, "obj", f"protobuf-{platform}"), prefix,
              platform_args(platform) + ["-Dprotobuf_BUILD_TESTS=OFF", "-Dprotobuf_BUILD_SHARED_LIBS=OFF",
                                         "-Dprotobuf_BUILD_PROTOC_BINARIES=OFF", "-Dprotobuf_WITH_ZLIB=OFF"])
    openssl(platform, prefix)
    cmake(source("gns"), os.path.join(ROOT, "obj", f"gns-{platform}"), prefix,
          platform_args(platform) + [
              "-DBUILD_STATIC_LIB=ON", "-DBUILD_SHARED_LIB=OFF", "-DBUILD_EXAMPLES=OFF", "-DBUILD_TESTS=OFF",
              "-DUSE_CRYPTO=OpenSSL", f"-DOPENSSL_ROOT_DIR={prefix}", "-DOPENSSL_USE_STATIC_LIBS=ON",
              f"-DProtobuf_DIR={prefix}/lib/cmake/protobuf", "-DProtobuf_USE_STATIC_LIBS=ON",
              f"-DProtobuf_PROTOC_EXECUTABLE={protoc}", f"-DCMAKE_FIND_ROOT_PATH={prefix}"])
    missing = [n for n in LIBS if not os.path.exists(os.path.join(prefix, "lib", n))]
    if missing:
        raise RuntimeError(f"GameNetworkingSockets {platform}: no {', '.join(missing)} after the build")
    return prefix


def libraries(platform):
    prefix = build(platform)
    return [os.path.join(prefix, "lib", n) for n in LIBS]


def exports(platform):
    """The C functions the GNS library defines (its flat API: SteamAPI_ISteamNetworkingSockets_*,
    SteamAPI_SteamNetworkingIPAddr_*, ...), so no generated stub stands in for them."""
    lib = os.path.join(build(platform), "lib", "libGameNetworkingSockets_s.a")
    out = subprocess.run(["nm", "-gUj", "-arch", "arm64", lib], capture_output=True, text=True, check=True).stdout
    return sorted({s[1:] for s in out.split() if s.startswith("_") and not s.startswith("__Z")})


def networking_exports():
    """The flat functions RecompSteam/networking.m defines when built with RECOMP_GNS."""
    from recomp import iossdk
    src = os.path.join(paths.CODE, "recomp", "native", "RecompSteam", "networking.m")
    obj = os.path.join(ROOT, "obj", "networking.o")
    os.makedirs(os.path.dirname(obj), exist_ok=True)
    subprocess.run(["xcrun", "-sdk", "iphoneos", "clang", "-arch", "arm64", f"-mios-version-min={IOS_MIN}",
                    "-isysroot", iossdk.sdk_path(), "-fobjc-arc", "-fmodules", "-w", "-DRECOMP_GNS",
                    "-c", src, "-o", obj], check=True)
    out = subprocess.run(["nm", "-gUj", obj], capture_output=True, text=True, check=True).stdout
    return sorted(s[1:] for s in out.split() if s.startswith("_SteamAPI_"))


def install(native, work, log):
    """Put the iOS libraries among the shell's iOS plug-ins and return an overrides file for
    asmtool naming every function they and networking.m define (so no stub stands in for
    them), or None when GNS cannot be built (the game then has no Steam networking)."""
    try:
        libs = libraries("ios")
        names = sorted(set(exports("ios")) | set(networking_exports()))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as e:
        log(f"GameNetworkingSockets: {e}; no Steam networking in this port")
        return None
    from recomp import unity_ios
    for lib in libs:
        shutil.copy2(lib, native)
        with open(os.path.join(native, os.path.basename(lib) + ".meta"), "w") as f:
            f.write(unity_ios.native_meta(os.path.basename(lib)))
    path = os.path.join(work, "recomp_gns_exports.c")
    with open(path, "w") as f:
        f.write(f"// GameNetworkingSockets ({GNS_COMMIT[:12]}) and RecompSteam/networking.m are linked; they define:\n")
        for n in names:
            f.write(f"//   {n}()\n")
    log(f"GameNetworkingSockets {GNS_COMMIT[:12]}: linked, {len(names)} functions")
    return path


def enable(native):
    """networking.m, as the Steam runtime copied it, built with RECOMP_GNS."""
    from recomp import unity_ios
    with open(os.path.join(native, "networking.m.meta"), "w") as f:
        f.write(unity_ios.native_meta("networking.m", "-fobjc-arc -DRECOMP_GNS"))


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("macos", "ios"):
        sys.exit(__doc__)
    print(build(sys.argv[1]))
