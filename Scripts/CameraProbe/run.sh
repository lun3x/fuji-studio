#!/bin/zsh
set -eu
probe_root="${0:A:h:h:h}"
exec swift run --package-path "$probe_root/Tools/FujiCameraLaptop" FujiCameraLaptop "$@"
