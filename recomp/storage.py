"""Will the game fit on the iPhone or iPad? Checked before a port and again before the install.

devicectl tells the device's capacity but not its free space, so the free space comes from
libimobiledevice's ideviceinfo (Homebrew: libimobiledevice). Without it, or when the device
does not answer, the check is skipped and the install reports a full device itself.

The installer stages the whole app before it moves it in place, so the device needs the app's
full size free even when an older build of the game is installed.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

from recomp import events

# A port is the Mac game's content in an iOS bundle: Stray's came out the same size,
# Timberborn's 4% larger (IL2CPP code). The margin covers that and the device's own use.
PORT_GROWTH = 1.08


def size_of(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p):
                total += os.path.getsize(p)
    return total


def gb(n):
    return f"{n / 1e9:.1f} GB"


def _details(device):
    """devicectl's identifier for the device -> (its UDID, which ideviceinfo takes, and its
    kind, "iPhone" or "iPad"), or (None, "device")."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "details.json")
        try:
            subprocess.run(["xcrun", "devicectl", "device", "info", "details", "--device", device,
                            "--json-output", out], capture_output=True, timeout=60)
            with open(out) as f:
                hw = json.load(f)["result"]["hardwareProperties"]
            return hw["udid"], hw.get("deviceType") or "device"
        except (OSError, subprocess.TimeoutExpired, KeyError, ValueError):
            return None, "device"


def free_space(udid):
    """Bytes free on the device, or None when it cannot be told."""
    tool = shutil.which("ideviceinfo")
    if not tool or not udid:
        return None
    for net in ([], ["-n"]):  # over the cable first, then over the network
        try:
            out = subprocess.run([tool, "-u", udid, *net, "-q", "com.apple.disk_usage", "-k", "AmountDataAvailable"],
                                 capture_output=True, text=True, timeout=30).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            continue
        if out.isdigit():
            return int(out)
    return None


def check(device, need, what):
    """Stop with a plain-language message when the device has less than `need` bytes free."""
    udid, kind = _details(device)
    free = free_space(udid)
    if free is None:
        print(f"[recomp] could not read the {kind}'s free space (needs ideviceinfo: brew install libimobiledevice); "
              "skipping the space check", flush=True)
        return
    print(f"[recomp] {kind} storage: {gb(free)} free, {what} needs {gb(need)}", flush=True)
    if free < need:
        text = (f"The {kind} needs {gb(need)} free for {what} and has {gb(free)}: delete apps or files "
                f"(Settings > General > {kind} Storage), then retry.")
        events.emit("hint", text=text)
        sys.exit(f"Not enough space on the {kind}: {gb(need)} needed, {gb(free)} free.")


def check_port(device, game_app):
    """Before building: estimate the iOS app from the Mac game, so a full device fails in seconds."""
    check(device, int(size_of(game_app) * PORT_GROWTH), "this game")


def check_install(device, built_app):
    check(device, size_of(built_app), "this game")
