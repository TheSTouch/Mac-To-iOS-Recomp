"""Machine-readable progress for front ends (the Mac app).

When RECOMP_EVENTS=1, each event is printed on its own stdout line as
'@@' + JSON. Humans running the CLI see the ordinary log lines instead.

Kinds: stage {name, state: start|done|failed}, progress {fraction 0-1 or null, detail},
log {line}, hint {text}: a plain-language fix for a failure recognised in tool output.
"""
import json
import os
import re
import sys

ENABLED = os.environ.get("RECOMP_EVENTS") == "1"


def emit(kind, **data):
    if ENABLED:
        sys.stdout.write("@@" + json.dumps(dict(data, kind=kind)) + "\n")
        sys.stdout.flush()


def stage(name, state):
    emit("stage", name=name, state=state)


def progress(fraction, detail=""):
    emit("progress", fraction=fraction, detail=detail)


# Known failures in Unity, xcodebuild and devicectl output, and what to do about them.
HINTS = [
    (r"No valid Unity Editor license|LICENSE SYSTEM.*(no|invalid) .*licen|Licensing.*not activated",
     "Unity has no license on this Mac: open Unity Hub once, sign in and add a free Personal license, then retry."),
    (r"No Account for Team|No signing certificate|requires a development team|No profiles for",
     "Xcode could not sign the app: sign in to your developer account in Xcode > Settings > Accounts, then retry."),
    (r"increased-memory-limit|entitlement.*not supported",
     "Your App ID is missing a capability: let Xcode's automatic signing update it by retrying with your account signed in."),
    (r"device is locked|device was not, or could not be, unlocked|kAMDMobileImageMounterDeviceLocked",
     "Unlock your iPad and keep it awake, then use Retry Install."),
    (r"Developer Mode (is )?(disabled|not enabled|must be enabled)",
     "Turn on Developer Mode on the iPad: Settings > Privacy & Security > Developer Mode, then retry."),
    (r"(Could not|Unable to) (find|connect).*device|device.*(not found|unavailable|disconnected)",
     "The iPad is not reachable: connect it with a cable or put it on the same network, unlocked, then retry."),
    (r"untrusted developer|Untrusted Developer",
     "On the iPad, trust your developer certificate: Settings > General > VPN & Device Management."),
]
_HINTS = [(re.compile(p, re.IGNORECASE), t) for p, t in HINTS]
_sent = set()


def check_hints(line):
    for pat, text in _HINTS:
        if text not in _sent and pat.search(line):
            _sent.add(text)
            emit("hint", text=text)
