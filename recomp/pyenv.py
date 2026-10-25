"""A private virtualenv under RECOMP_HOME for steps that need third-party Python packages."""
import os
import subprocess
import sys

from recomp import paths

# Pinned: textures.py relies on UnityPy's object layouts and save behaviour.
REQUIREMENTS = ["UnityPy==1.25.4"]
VENV = os.path.join(paths.HOME, "venv")
STAMP = os.path.join(VENV, "recomp-requirements.txt")


def python():
    """Path to the venv's interpreter, creating or updating the venv when needed."""
    exe = os.path.join(VENV, "bin", "python")
    wanted = "\n".join(REQUIREMENTS)
    have = open(STAMP).read() if os.path.exists(STAMP) else None
    if not os.path.exists(exe) or have != wanted:
        print("[recomp] setting up Python packages (one time)", flush=True)
        if not os.path.exists(exe):
            subprocess.run([sys.executable, "-m", "venv", VENV], check=True)
        subprocess.run([exe, "-m", "pip", "install", "-q", "--disable-pip-version-check", *REQUIREMENTS], check=True)
        with open(STAMP, "w") as f:
            f.write(wanted)
    return exe
