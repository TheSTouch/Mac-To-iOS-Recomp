"""Where code lives versus where the large files go.

CODE is this checkout (or the app bundle's engine folder). HOME holds the
downloaded Unity editors (toolchain/) and per-game work (build/); it defaults
to CODE and is moved with RECOMP_HOME, e.g. to an external disk.
"""
import os

CODE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.abspath(os.path.expanduser(os.environ.get("RECOMP_HOME", CODE)))
TOOLCHAIN = os.path.join(HOME, "toolchain")
BUILD = os.path.join(HOME, "build")
