#!/usr/bin/env bash
# Builds the claude-desktop-builder source RPM, ready for
# "rpmbuild --rebuild claude-desktop-builder-*.src.rpm".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(dirname "$HERE")"
VER="$(sed -n 's/^Version:[[:space:]]*//p' "$HERE/claude-desktop-builder.spec")"
OUT="${1:-$PWD}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/claude-desktop-builder-$VER/builder" "$W/SOURCES"
cp "$TOP"/{build-rpm.sh,claude-desktop.spec,README.md,LICENSE} "$W/claude-desktop-builder-$VER/"
cp "$HERE"/{claude-desktop-update,claude-desktop-update.service,claude-desktop-update.timer,claude-desktop-builder.sysusers} \
   "$W/claude-desktop-builder-$VER/builder/"
cp "$HERE/claude-desktop-builder.sysusers" "$W/SOURCES/"
tar -czf "$W/SOURCES/claude-desktop-builder-$VER.tar.gz" -C "$W" --owner=root --group=root "claude-desktop-builder-$VER"
rpmbuild --define "_topdir $W" --define "_sourcedir $W/SOURCES" --define "_srcrpmdir $OUT" \
    -bs "$HERE/claude-desktop-builder.spec"
