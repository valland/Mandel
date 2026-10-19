#!/bin/sh
set -eu
cd "$(dirname "$0")"
exec ./tools/zig build run -Doptimize=ReleaseFast
