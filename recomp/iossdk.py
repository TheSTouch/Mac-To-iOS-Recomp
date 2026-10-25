"""What the iOS SDK exports, read from its text-based stubs (.tbd).

Used to decide where each import of a Mac binary binds on iOS: to the iOS
library that exports it, or to a shim when no iOS library does.
"""
import json
import os
import re
import subprocess

_SECTION = re.compile(r"(symbols|weak-symbols|thread-local-symbols|objc-classes|objc-eh-types|objc-ivars):\s*\[([^\]]*)\]", re.S)
_PREFIX = {"objc-classes": ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"), "objc-eh-types": ("_OBJC_EHTYPE_$_",),
           "objc-ivars": ("_OBJC_IVAR_$_",)}


def sdk_path():
    return subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True,
                          check=True).stdout.strip()


def sdk_version():
    return subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], capture_output=True, text=True,
                          check=True).stdout.strip()


def _parse(path):
    """(install names in the file, exported symbols of all of them)."""
    text = open(path, errors="ignore").read()
    names = re.findall(r"install-name:\s*'?([^'\n]+)'?", text)
    syms = set()
    for kind, body in _SECTION.findall(text):
        for s in body.split(","):
            s = s.strip().strip("'\"")
            if not s:
                continue
            for p in _PREFIX.get(kind, ("",)):
                syms.add(p + s)
    return names, syms


def index(cache_dir):
    """{library install name: set of symbols}, for public frameworks and /usr/lib.

    A framework's entry covers everything its .tbd re-exports, so binding to the
    umbrella (UIKit, AudioToolbox) finds symbols that live in sub-libraries.
    """
    sdk = sdk_path()
    cache = os.path.join(cache_dir, f"ios-sdk-{sdk_version()}.json")
    if os.path.exists(cache):
        with open(cache) as f:
            return {k: set(v) for k, v in json.load(f).items()}
    out = {}
    fw_root = os.path.join(sdk, "System/Library/Frameworks")
    for fw in sorted(os.listdir(fw_root)):
        name = fw[:-len(".framework")]
        for tbd in (os.path.join(fw_root, fw, name + ".tbd"), os.path.join(fw_root, fw, "Versions/A", name + ".tbd")):
            if os.path.exists(tbd):
                names, syms = _parse(tbd)
                main = next((n for n in names if n.endswith("/" + name)), names[0] if names else None)
                if main:
                    out[main] = syms
                break
    lib_root = os.path.join(sdk, "usr/lib")
    for n in sorted(os.listdir(lib_root)):
        if n.endswith(".tbd") and not os.path.islink(os.path.join(lib_root, n)):
            names, syms = _parse(os.path.join(lib_root, n))
            if names:
                out[names[0]] = syms
    os.makedirs(cache_dir, exist_ok=True)
    with open(cache, "w") as f:
        json.dump({k: sorted(v) for k, v in out.items()}, f)
    return out


def framework_path(idx, mac_path):
    """iOS install name for a macOS library path, or None if iOS has no such library."""
    m = re.match(r"/System/Library/Frameworks/(\w+)\.framework/", mac_path)
    if m:
        name = m.group(1)
        for k in idx:
            if re.match(rf"/System/Library/Frameworks/{name}\.framework/(Versions/\w/)?{name}$", k):
                return k
        return None
    if mac_path.startswith("/usr/lib/"):
        return mac_path if mac_path in idx else None
    return None
