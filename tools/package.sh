#!/bin/sh
# Builds dist/album-sync-<version>.zip containing album-sync.lrplugin (release folder name).
set -eu
cd "$(dirname "$0")/.."
src=src/album-sync.lrdevplugin
version=$(sed -n 's/.*VERSION = { major = \([0-9]*\), minor = \([0-9]*\), revision = \([0-9]*\) }.*/\1.\2.\3/p' "$src/Info.lua")
[ -n "$version" ] || { echo "cannot read VERSION from $src/Info.lua" >&2; exit 1; }
rm -rf dist/build
mkdir -p dist/build/album-sync.lrplugin
cp "$src"/*.lua "$src"/*.LICENSE "$src"/*.png dist/build/album-sync.lrplugin/
cp LICENSE README.md THIRD_PARTY.md dist/build/album-sync.lrplugin/
(cd dist/build && rm -f "../album-sync-$version.zip" && zip -qr "../album-sync-$version.zip" album-sync.lrplugin)
rm -rf dist/build
echo "dist/album-sync-$version.zip"
