"""Fetch a specific Unity editor with iOS support into toolchain/, without installing it.

The official installer packages are verified (Developer ID, Unity Technologies)
and unpacked with pkgutil, so nothing lands in /Applications and no admin rights
are needed.
"""
import os
import shutil
import subprocess
import sys
import time
import urllib.request

from recomp import events, paths

BASE = "https://download.unity3d.com/download_unity"
UNITY_TEAM = "9QW8UQUTAA"


def log(msg):
    print(f"[toolchain] {msg}", flush=True)


def fetch(url, dest, label):
    """Download url to dest, resuming a .part file and reporting progress."""
    if os.path.exists(dest):
        log(f"have {os.path.basename(dest)}")
        return
    log(f"downloading {url}")
    part = dest + ".part"
    have = os.path.getsize(part) if os.path.exists(part) else 0
    req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
    with urllib.request.urlopen(req) as resp, open(part, "ab" if have else "wb") as out:
        if have and resp.status != 206:  # server ignored the range: start over
            out.truncate(0)
            have = 0
        total = have + int(resp.headers.get("Content-Length", 0))
        last = 0.0
        while True:
            block = resp.read(1 << 20)
            if not block:
                break
            out.write(block)
            have += len(block)
            now = time.time()
            if now - last > 0.5:
                events.progress(have / total if total else None,
                                f"Downloading {label}: {have / 1e9:.2f} of {total / 1e9:.2f} GB")
                last = now
    os.rename(part, dest)


def verify(pkg):
    out = subprocess.run(["pkgutil", "--check-signature", pkg], capture_output=True, text=True).stdout
    if "Developer ID Installer: Unity Technologies" not in out or UNITY_TEAM not in out:
        sys.exit(f"{pkg}: not signed by Unity Technologies ({UNITY_TEAM}):\n{out}")


def expand(pkg, scratch):
    shutil.rmtree(scratch, ignore_errors=True)
    subprocess.run(["pkgutil", "--expand-full", pkg, scratch], check=True)
    payloads = [os.path.join(scratch, d, "Payload") for d in os.listdir(scratch)
                if d.endswith(".pkg.tmp") or d.endswith(".pkg")]
    payloads = [p for p in payloads if os.path.isdir(p)]
    if len(payloads) != 1:
        sys.exit(f"{pkg}: expected one payload, found {payloads}")
    return payloads[0]


def installed(version):
    dest = os.path.join(paths.TOOLCHAIN, f"Unity-{version}")
    return os.path.isdir(os.path.join(dest, "Unity.app")) and os.path.isdir(os.path.join(dest, "PlaybackEngines", "iOSSupport"))


def install(version, changeset):
    dest = os.path.join(paths.TOOLCHAIN, f"Unity-{version}")
    if installed(version):
        log(f"Unity {version} already in {dest}")
        return dest
    dl = os.path.join(paths.TOOLCHAIN, "downloads")
    os.makedirs(dl, exist_ok=True)
    editor_pkg = os.path.join(dl, f"Unity-{version}.pkg")
    ios_pkg = os.path.join(dl, f"iOS-Support-{version}.pkg")
    fetch(f"{BASE}/{changeset}/MacEditorInstallerArm64/Unity-{version}.pkg", editor_pkg, f"Unity {version}")
    fetch(f"{BASE}/{changeset}/MacEditorTargetInstaller/UnitySetup-iOS-Support-for-Editor-{version}.pkg", ios_pkg,
          "iOS support")
    events.progress(None, "Verifying Unity's signatures")
    for p in (editor_pkg, ios_pkg):
        verify(p)
    events.progress(None, "Unpacking Unity (this takes a few minutes)")
    shutil.rmtree(dest, ignore_errors=True)
    scratch = os.path.join(paths.TOOLCHAIN, "x")
    shutil.move(os.path.join(expand(editor_pkg, scratch), "Unity"), dest)
    os.makedirs(os.path.join(dest, "PlaybackEngines"), exist_ok=True)
    shutil.move(os.path.join(expand(ios_pkg, scratch), "iOSSupport"), os.path.join(dest, "PlaybackEngines", "iOSSupport"))
    shutil.rmtree(scratch, ignore_errors=True)
    subprocess.run(["xattr", "-dr", "com.apple.quarantine", dest])
    log(f"Unity {version} ready in {dest} (installers kept in {dl}; delete them to reclaim ~5.5 GB)")
    return dest
