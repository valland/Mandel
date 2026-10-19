#!/bin/sh
# Run from a committed checkout, after bootstrap. No developer credentials needed.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)
if [ "${GITHUB_REF_TYPE:-}" = tag ] && [ "${GITHUB_REF_NAME:-}" != "v$VERSION" ]; then
    echo 'Release tag must match build.zig.zon version.' >&2
    exit 1
fi
./tools/package.sh
APP=zig-out/Mandel.app
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ "$BUNDLE_VERSION" = "$VERSION" ] || { echo 'App version and source version differ.' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
mkdir -p dist
# ditto preserves the app bundle metadata and ad-hoc signature.
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Mandel-macos-arm64.zip
WORK=$(mktemp -d /tmp/mandel-release.XXXXXX)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/Mandel/dependencies"
git archive HEAD | tar -xf - -C "$WORK/Mandel"
cp .tools/sources/gmp-6.3.0.tar.xz .tools/sources/mpfr-4.2.2.tar.xz "$WORK/Mandel/dependencies/"
git rev-parse HEAD > "$WORK/Mandel/SOURCE_COMMIT"
tar -czf dist/Mandel-source.tar.gz -C "$WORK" Mandel
(cd dist && shasum -a 256 Mandel-macos-arm64.zip Mandel-source.tar.gz > SHA256SUMS)
printf 'Release files ready in dist/\n'
