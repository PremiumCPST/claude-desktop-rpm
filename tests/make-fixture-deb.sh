#!/usr/bin/env bash
# Builds a FAKE claude-desktop .deb that mimics the official layout, to test
# build-rpm.sh without downloading the real package. Not the real app.
set -euo pipefail
OUT="${1:-$PWD/claude-desktop_0.0.0-test_amd64.deb}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
R="$W/root"; A="$R/usr/lib/claude-desktop"
mkdir -p "$A/resources/app.asar.unpacked/node_modules/@ant/claude-native" \
         "$A/resources/app.asar.unpacked/node_modules/node-pty/prebuilds/linux-x64" \
         "$R/usr/bin" "$R/usr/share/applications" "$R/usr/share/doc/claude-desktop" \
         "$R/usr/share/lintian/overrides" "$W/DEBIAN"
for s in 16 32 48 128 256 512; do mkdir -p "$R/usr/share/icons/hicolor/${s}x${s}/apps"; done
echo 'int ffmpeg_stub(void){return 0;}' > "$W/ff.c"
gcc -shared -fPIC -Wl,-soname,libffmpeg.so -o "$A/libffmpeg.so" "$W/ff.c"
printf 'int ffmpeg_stub(void);\n#include <stdio.h>\nint main(){puts("fake claude-desktop");return ffmpeg_stub();}\n' > "$W/m.c"
gcc -o "$A/claude-desktop" "$W/m.c" -L"$A" -lffmpeg -Wl,-rpath,'$ORIGIN'
gcc -o "$A/chrome-sandbox" -x c - <<<'int main(){return 0;}'
echo 'int x;' | gcc -shared -fPIC -x c -o "$A/resources/app.asar.unpacked/node_modules/@ant/claude-native/claude-native-binding.node" -
echo 'int y;' | gcc -shared -fPIC -x c -o "$A/resources/app.asar.unpacked/node_modules/node-pty/prebuilds/linux-x64/pty.node" -
head -c 1M /dev/urandom > "$A/resources/app.asar"
chmod 4755 "$A/chrome-sandbox"
ln -s ../lib/claude-desktop/claude-desktop "$R/usr/bin/claude-desktop"
cat > "$R/usr/share/applications/claude-desktop.desktop" <<D
[Desktop Entry]
Name=Claude
Comment=Claude Desktop
Exec=claude-desktop %U
Icon=claude-desktop
Type=Application
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
D
for s in 16 32 48 128 256 512; do printf '\x89PNG\r\n\x1a\n' > "$R/usr/share/icons/hicolor/${s}x${s}/apps/claude-desktop.png"; done
echo "Proprietary (test fixture)" > "$R/usr/share/doc/claude-desktop/copyright"
echo "claude-desktop: setuid-binary" > "$R/usr/share/lintian/overrides/claude-desktop"
cat > "$W/DEBIAN/control" <<C
Package: claude-desktop
Version: 0.0.0-test
Architecture: amd64
Maintainer: test
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libuuid1, libsecret-1-0, libgbm1, libasound2
Description: fake claude desktop for packaging tests
C
printf '#!/bin/sh\n# would install /etc/apparmor.d/claude-desktop and apt source\nexit 0\n' > "$W/DEBIAN/postinst"
chmod 755 "$W/DEBIAN/postinst"
cp -a "$W/DEBIAN" "$R/"
dpkg-deb --root-owner-group -Zxz --build "$R" "$OUT" >/dev/null
echo "$OUT"
