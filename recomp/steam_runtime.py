"""The Steam runtime every port carries, as each route builds it: the Steam client core from
Kettle (recomp/vendor/kettle, a git submodule pinned to a tag: the session, sign-in, protobuf
codec and Steam Cloud protocol) with the Steamworks API built on it here in
recomp/native/RecompSteam (the flat API, stats, user, apps, start, the cloud sync, matchmaking,
networking). recomp/native/RecompSteam/deprecated/ holds our old copy of the core, never built.
"""
import os
import sys

from recomp import paths

OURS = os.path.join(paths.CODE, "recomp", "native", "RecompSteam")
KETTLE = os.path.join(paths.CODE, "recomp", "vendor", "kettle", "Sources", "KettleExperimental")
# Kettle's public headers, then its folder (RecompSteamInternal.h, KettleFeatures.h).
INCLUDE = [OURS, os.path.join(KETTLE, "include"), KETTLE]
# Kettle's default parts (sign-in, Cloud, tickets) plus concurrent play
# (RecompSteam_SetConcurrentPlay). KETTLE_EXPERIMENTAL_CONFIGURED stays undefined: it would
# turn the defaults off.
DEFINES = ["-DKETTLE_CONCURRENT_PLAY=1"]


def _check():
    if not os.path.isfile(os.path.join(KETTLE, "KettleFeatures.h")):
        sys.exit("recomp/vendor/kettle is empty: run `git submodule update --init recomp/vendor/kettle`")


def _files(exts):
    _check()
    found = []
    for d in INCLUDE:
        found += [os.path.join(d, n) for n in os.listdir(d)
                  if os.path.isfile(os.path.join(d, n)) and n.endswith(exts)]
    return sorted(found, key=os.path.basename)


def sources():
    """Every C and Objective-C file of the runtime (top level of each folder: cli/ is the
    Terminal tool, deprecated/ is not built)."""
    return _files((".c", ".m", ".mm"))


def files():
    """sources() and the headers, for routes that copy the runtime into one folder."""
    return _files((".c", ".m", ".mm", ".h"))


def flags():
    """The compiler flags every file of the runtime is built with."""
    return DEFINES + [x for d in INCLUDE for x in ("-I", d)]
