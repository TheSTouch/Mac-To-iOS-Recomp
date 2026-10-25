"""Fetch a specific Unity editor with iOS support into toolchain/, without installing it.

The official installer packages are verified (Developer ID, Unity Technologies)
and unpacked with pkgutil, so nothing lands in /Applications and no admin rights
are needed.
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = "https://download.unity3d.com/download_unity"
UNITY_TEAM = "9QW8UQUTAA"


def log(msg):
    print(f"[toolchain] {msg}", flush=True)


def fetch(url, dest):
    if os.path.exists(dest):
        log(f"have {os.path.basename(dest)}")
        return
    log(f"downloading {url}")
    subprocess.run(["curl", "-fSL", "-C", "-", "-o", dest + ".part", url], check=True)
    os.rename(dest + ".part", dest)


def verify(pkg):
    out = subprocess.run(["pkgutil", "--check-signature", pkg], capture_output=True, text=True).stdout
    if f"Developer ID Installer: Unity Technologies" not in out or UNITY_TEAM not in out:
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


def install(version, changeset):
    dest = os.path.join(ROOT, "toolchain", f"Unity-{version}")
    if os.path.isdir(os.path.join(dest, "Unity.app")) and os.path.isdir(os.path.join(dest, "PlaybackEngines", "iOSSupport")):
        log(f"Unity {version} already in {dest}")
        return dest
    dl = os.path.join(ROOT, "toolchain", "downloads")
    os.makedirs(dl, exist_ok=True)
    editor_pkg = os.path.join(dl, f"Unity-{version}.pkg")
    ios_pkg = os.path.join(dl, f"iOS-Support-{version}.pkg")
    fetch(f"{BASE}/{changeset}/MacEditorInstallerArm64/Unity-{version}.pkg", editor_pkg)
    fetch(f"{BASE}/{changeset}/MacEditorTargetInstaller/UnitySetup-iOS-Support-for-Editor-{version}.pkg", ios_pkg)
    for p in (editor_pkg, ios_pkg):
        verify(p)
    shutil.rmtree(dest, ignore_errors=True)
    scratch = os.path.join(ROOT, "toolchain", "x")
    shutil.move(os.path.join(expand(editor_pkg, scratch), "Unity"), dest)
    os.makedirs(os.path.join(dest, "PlaybackEngines"), exist_ok=True)
    shutil.move(os.path.join(expand(ios_pkg, scratch), "iOSSupport"), os.path.join(dest, "PlaybackEngines", "iOSSupport"))
    shutil.rmtree(scratch, ignore_errors=True)
    subprocess.run(["xattr", "-dr", "com.apple.quarantine", dest])
    log(f"Unity {version} ready in {dest} (installers kept in {dl}; delete them to reclaim ~5.5 GB)")
    return dest
