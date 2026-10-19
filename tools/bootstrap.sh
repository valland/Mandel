#!/bin/sh
# Project-local tools. Native libraries are built in a temporary path because
# GNU libtool does not handle spaces in installation prefixes reliably.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo 'This bootstrap targets Apple Silicon macOS.' >&2; exit 1; }
mkdir -p "$ROOT/.tools/native/lib" "$ROOT/.tools/native/include" "$ROOT/.tools/sources" "$ROOT/.tools/native/licenses"
WORK=$(mktemp -d /tmp/mandel-bootstrap.XXXXXX)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fetch() {
    curl --fail --location "$1" -o "$WORK/$2"
    printf '%s  %s\n' "$3" "$WORK/$2" | shasum -a 256 -c -
}
if [ ! -x "$ROOT/.tools/zig-aarch64-macos-0.17.0/zig" ]; then
    fetch https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz zig.tar.xz b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a
    tar -xf "$WORK/zig.tar.xz" -C "$ROOT/.tools"
fi
    fetch https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz gmp.tar.xz a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
    fetch https://www.mpfr.org/mpfr-4.2.2/mpfr-4.2.2.tar.xz mpfr.tar.xz b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01
    cp "$WORK/gmp.tar.xz" "$ROOT/.tools/sources/gmp-6.3.0.tar.xz"
    cp "$WORK/mpfr.tar.xz" "$ROOT/.tools/sources/mpfr-4.2.2.tar.xz"
    tar -xf "$WORK/gmp.tar.xz" -C "$WORK"
    tar -xf "$WORK/mpfr.tar.xz" -C "$WORK"
    cp "$WORK/gmp-6.3.0/COPYINGv3" "$ROOT/.tools/native/licenses/GPL-3.0.txt"
    cp "$WORK/gmp-6.3.0/COPYING.LESSERv3" "$ROOT/.tools/native/licenses/LGPL-3.0.txt"
if [ ! -f "$ROOT/.tools/native/lib/libmpfr.a" ]; then
    (cd "$WORK/gmp-6.3.0" && ./configure --prefix="$WORK/native" --disable-shared --enable-static && make -j4 && make install)
    (cd "$WORK/mpfr-4.2.2" && ./configure --prefix="$WORK/native" --with-gmp="$WORK/native" --disable-shared --enable-static && make -j4 && make install)
    cp "$WORK/native/lib/libgmp.a" "$WORK/native/lib/libmpfr.a" "$ROOT/.tools/native/lib/"
    cp "$WORK/native/include/gmp.h" "$WORK/native/include/mpfr.h" "$ROOT/.tools/native/include/"
fi
if [ ! -f "$ROOT/vendor/nanoui/build.zig" ]; then
    git clone https://github.com/justrach/nanoui "$ROOT/vendor/nanoui"
    git -C "$ROOT/vendor/nanoui" checkout 0035195c45934691e2f53e7e8c6d83a51002ef3b
fi
printf '\nReady. Run ./run.command from the project folder.\n'
