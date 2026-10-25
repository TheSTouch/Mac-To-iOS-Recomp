#!/bin/sh
# Runs the repo-pinned ILSpy decompiler (tools/dotnet-tools.json) from anywhere.
cd "$(dirname "$0")" && DOTNET_ROLL_FORWARD=Major exec dotnet tool run ilspycmd "$@"
