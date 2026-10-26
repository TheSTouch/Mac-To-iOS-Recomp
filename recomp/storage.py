"""Will the game fit on the iPad? Checked before a port and again before the install.

devicectl tells the device's capacity but not its free space, so the free space comes from
libimobiledevice's ideviceinfo (Homebrew: libimobiledevice). Without it, or when the iPad
does not answer, the check is skipped and the install reports a full iPad itself.

The installer stages the whole app before it moves it in place, so the iPad needs the app's
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
# Timberborn's 4% larger (IL2CPP code). The margin covers that and the iPad's own use.
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


def _udid(device):
    """devicectl's identifier for the device -> its UDID, which ideviceinfo takes."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "details.json")
        try:
            subprocess.run(["xcrun", "devicectl", "device", "info", "details", "--device", device,
                            "--json-output", out], capture_output=True, timeout=60)
            with open(out) as f:
                return json.load(f)["result"]["hardwareProperties"]["udid"]
        except (OSError, subprocess.TimeoutExpired, KeyError, ValueError):
            return None


def free_space(device):
    """Bytes free on the device, or None when it cannot be told."""
    tool = shutil.which("ideviceinfo")
    udid = tool and _udid(device)
    if not udid:
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
    free = free_space(device)
    if free is None:
        print("[recomp] could not read the iPad's free space (needs ideviceinfo: brew install libimobiledevice); "
              "skipping the space check", flush=True)
        return
    print(f"[recomp] iPad storage: {gb(free)} free, {what} needs {gb(need)}", flush=True)
    if free < need:
        text = (f"The iPad needs {gb(need)} free for {what} and has {gb(free)}: delete apps or files "
                f"(Settings > General > iPad Storage), then retry.")
        events.emit("hint", text=text)
        sys.exit(f"Not enough space on the iPad: {gb(need)} needed, {gb(free)} free.")


def check_port(device, game_app):
    """Before building: estimate the iOS app from the Mac game, so a full iPad fails in seconds."""
    check(device, int(size_of(game_app) * PORT_GROWTH), "this game")


def check_install(device, built_app):
    check(device, size_of(built_app), "this game")
