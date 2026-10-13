#!/usr/bin/env bash
# Exercises build-rpm.sh's download path (key fingerprint -> signed InRelease
# -> Packages SHA256 -> .deb SHA256) against a local mock apt repo signed with
# a throwaway key. Usage: test-apt-chain.sh FIXTURE.deb OUTDIR [--tamper]
set -euo pipefail
DEB="$(realpath "$1")"; OUT="$2"; TAMPER="${3:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$(mktemp -d)"; trap 'kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
export GNUPGHOME="$W/gnupg"; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-gen-key 'mock repo <mock@test>' ed25519 sign never
FPR="$(gpg --with-colons --list-keys | awk -F: '/^fpr:/ {print $10; exit}')"
R="$W/www"; mkdir -p "$R/pool" "$R/dists/stable/main/binary-amd64"
cp "$DEB" "$R/pool/claude-desktop_amd64.deb"
gpg --armor --export "$FPR" > "$R/key.asc"
P="$R/dists/stable/main/binary-amd64/Packages"
{ dpkg-deb -f "$DEB"; echo "Filename: pool/claude-desktop_amd64.deb";
  echo "Size: $(stat -c%s "$DEB")"; echo "SHA256: $(sha256sum "$DEB" | cut -d' ' -f1)"; echo; } > "$P"
xz -k "$P"
{ echo "Suite: stable"; echo "Codename: stable"; echo "Architectures: amd64"; echo "Components: main"; echo "SHA256:"
  for f in Packages Packages.xz; do
    echo " $(sha256sum "$R/dists/stable/main/binary-amd64/$f" | cut -d' ' -f1) $(stat -c%s "$R/dists/stable/main/binary-amd64/$f") main/binary-amd64/$f"
  done; } > "$W/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' --clearsign -o "$R/dists/stable/InRelease" "$W/Release"
[ "$TAMPER" = --tamper ] && printf 'x' >> "$R/pool/claude-desktop_amd64.deb"
PORT=$((20000 + RANDOM % 20000))
python3 -m http.server -d "$R" -b 127.0.0.1 "$PORT" >/dev/null 2>&1 & SRV=$!
sleep 1
unset GNUPGHOME
CLAUDE_APT_REPO="http://127.0.0.1:$PORT" CLAUDE_APT_KEY_URL="http://127.0.0.1:$PORT/key.asc" \
CLAUDE_APT_KEY_FPR="$FPR" bash "$HERE/../build-rpm.sh" --outdir "$OUT" --nodeps
