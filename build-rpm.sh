#!/usr/bin/env bash
#
# build-rpm.sh — rebuild Anthropic's official Claude Desktop .deb as a native
# RPM, on your own machine.
#
# Claude Desktop is proprietary and its terms grant no redistribution right,
# so the RPM is never published: this script fetches the official .deb from
# Anthropic (or uses one you downloaded), checks it, and builds the RPM
# locally with claude-desktop.spec.
#
# Download chain (default): Anthropic's signed apt repository
#   key.asc (fingerprint pinned) -> InRelease (gpgv) -> Packages (SHA256)
#   -> claude-desktop_*.deb (SHA256)
#
# Usage: ./build-rpm.sh [--deb FILE] [--arch x86_64|aarch64] [--release N]
#                       [--outdir DIR] [--keep] [--nocheck] [--nodeps]
#        ./build-rpm.sh --print-latest   (print the newest upstream version, verified, and exit)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="$HERE/claude-desktop.spec"

REPO="${CLAUDE_APT_REPO:-https://downloads.claude.ai/claude-desktop/apt/stable}"
KEY_URL="${CLAUDE_APT_KEY_URL:-https://downloads.claude.ai/claude-desktop/key.asc}"
# Published on https://support.claude.com/en/articles/10065433
KEY_FPR="${CLAUDE_APT_KEY_FPR:-31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE}"

DEB=""
ARCH="$(uname -m)"
RELEASE="1"
OUTDIR="$PWD/build"
KEEP=0
NOCHECK=0
NODEPS=0
PRINT_LATEST=0
WORK=""

die()  { printf '\033[31merreur :\033[0m %s\n' "$*" >&2; exit 1; }
info() { if [ "$PRINT_LATEST" = 1 ]; then printf '==> %s\n' "$*" >&2; else printf '\033[36m==>\033[0m %s\n' "$*"; fi; }
warn() { printf '\033[33mattention :\033[0m %s\n' "$*" >&2; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --deb)     DEB="$(realpath "${2:?--deb attend un chemin}")"; shift 2 ;;
        --arch)    ARCH="${2:?--arch attend x86_64 ou aarch64}"; shift 2 ;;
        --release) RELEASE="${2:?--release attend un nombre}"; shift 2 ;;
        --outdir)  OUTDIR="${2:?--outdir attend un dossier}"; shift 2 ;;
        --keep)    KEEP=1; shift ;;
        --nocheck) NOCHECK=1; shift ;;
        --nodeps)  NODEPS=1; shift ;;
        --print-latest) PRINT_LATEST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         die "option inconnue : $1 (voir --help)" ;;
    esac
done

case "$ARCH" in
    x86_64)  DEB_ARCH=amd64; ELF_RE='x86-64';  PTY_DIR=linux-x64 ;;
    aarch64) DEB_ARCH=arm64; ELF_RE='aarch64'; PTY_DIR=linux-arm64 ;;
    *)       die "architecture non prise en charge : $ARCH (x86_64 ou aarch64)" ;;
esac

for c in ar tar xz file rpmbuild sha256sum find sed awk; do
    command -v "$c" >/dev/null || die "commande manquante : $c (sudo dnf install rpm-build binutils file xz)"
done
command -v desktop-file-validate >/dev/null || [ "$NOCHECK" = 1 ] \
    || die "desktop-file-validate manquant (sudo dnf install desktop-file-utils) ou utilisez --nocheck"
[ -f "$SPEC" ] || die "claude-desktop.spec introuvable : placez-le dans le même dossier que build-rpm.sh ($HERE)"

WORK="$(mktemp -d -t claude-desktop-rpm.XXXXXXXX)"
cleanup() {
    if [ "$KEEP" = 1 ]; then info "arbre de build conservé : $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# ------------------------------------------------------------ download -------
fetch() { curl -fsSL --retry 3 --max-time 900 -o "$2" "$1" || die "téléchargement impossible : $1"; }

fetch_from_repo() {
    command -v curl >/dev/null && command -v gpg >/dev/null && command -v gpgv >/dev/null \
        || die "curl, gpg et gpgv sont nécessaires pour télécharger (ou passez --deb)"
    local d="$WORK/repo"; mkdir -p "$d"
    export GNUPGHOME="$d/gnupg"; mkdir -m 700 "$GNUPGHOME"

    info "clé de signature Anthropic..."
    fetch "$KEY_URL" "$d/key.asc"
    local fpr
    fpr="$(gpg --batch --quiet --show-keys --with-colons "$d/key.asc" | awk -F: '/^fpr:/ {print $10; exit}')"
    [ "$fpr" = "$KEY_FPR" ] || die "empreinte de clé inattendue : $fpr (attendue $KEY_FPR)"
    gpg --batch --quiet --dearmor < "$d/key.asc" > "$d/key.gpg"

    info "index du dépôt (InRelease signé)..."
    fetch "$REPO/dists/stable/InRelease" "$d/InRelease"
    gpgv --keyring "$d/key.gpg" --output "$d/Release" "$d/InRelease" 2>"$d/gpgv.log" \
        || { cat "$d/gpgv.log" >&2; die "signature InRelease invalide"; }

    # Pick the best-compressed Packages index listed under SHA256.
    local idx sum
    for idx in Packages.xz Packages.gz Packages; do
        sum="$(awk -v f="main/binary-$DEB_ARCH/$idx" '
                 /^SHA256:/ {s=1; next} /^[^ ]/ {s=0}
                 s && $3 == f {print $1; exit}' "$d/Release")"
        [ -n "$sum" ] && break
    done
    [ -n "$sum" ] || die "aucun index Packages pour $DEB_ARCH dans le dépôt"
    fetch "$REPO/dists/stable/main/binary-$DEB_ARCH/$idx" "$d/$idx"
    echo "$sum  $d/$idx" | sha256sum -c --quiet - || die "somme SHA256 de $idx invalide"
    case "$idx" in
        *.xz) xz -dc "$d/$idx" > "$d/Packages" ;;
        *.gz) gzip -dc "$d/$idx" > "$d/Packages" ;;
    esac

    # Newest claude-desktop stanza: "version<TAB>filename<TAB>sha256".
    local best
    best="$(awk -v RS= -F'\n' '
        { pkg=ver=fn=sha=""
          for (i=1;i<=NF;i++) {
            if ($i ~ /^Package: /)  pkg=substr($i,10)
            if ($i ~ /^Version: /)  ver=substr($i,10)
            if ($i ~ /^Filename: /) fn=substr($i,11)
            if ($i ~ /^SHA256: /)   sha=substr($i,9) }
          if (pkg=="claude-desktop") print ver "\t" fn "\t" sha }' "$d/Packages" \
        | sort -t$'\t' -k1,1V | tail -1)"
    [ -n "$best" ] || die "claude-desktop absent de l'index $DEB_ARCH"
    local ver fn sha
    IFS=$'\t' read -r ver fn sha <<<"$best"
    info "version disponible : $ver"
    if [ "$PRINT_LATEST" = 1 ]; then echo "$ver"; exit 0; fi
    info "téléchargement de ${fn##*/}..."
    curl -fSL --retry 3 --max-time 1800 --progress-bar -o "$WORK/claude.deb" "$REPO/$fn" \
        || die "téléchargement du .deb impossible"
    echo "$sha  $WORK/claude.deb" | sha256sum -c --quiet - || die "somme SHA256 du .deb invalide"
    info "signature et SHA256 vérifiés"
    unset GNUPGHOME
}

if [ -n "$DEB" ]; then
    [ -f "$DEB" ] || die "fichier introuvable : $DEB"
    info "paquet local : $DEB"
    cp -- "$DEB" "$WORK/claude.deb"
else
    fetch_from_repo
fi
file -b "$WORK/claude.deb" | grep -q '^Debian binary package' || die "ce n'est pas un paquet .deb"

# -------------------------------------------------------------- unpack -------
info "extraction..."
mkdir -p "$WORK/ctrl" "$WORK/payload"
( cd "$WORK" && ar x claude.deb ) || die "ar ne peut pas lire le .deb"
CTRL_TAR="$(find "$WORK" -maxdepth 1 -name 'control.tar*' -print -quit)"
DATA_TAR="$(find "$WORK" -maxdepth 1 -name 'data.tar*' -print -quit)"
[ -n "$CTRL_TAR" ] && [ -n "$DATA_TAR" ] || die "structure .deb inattendue"
tar -xf "$CTRL_TAR" -C "$WORK/ctrl"
tar -xf "$DATA_TAR" -C "$WORK/payload" --no-same-owner

ctl() { sed -n "s/^$1:[[:space:]]*//p" "$WORK/ctrl/control" | head -1; }
PKG="$(ctl Package)"; UPVER="$(ctl Version)"; PKGARCH="$(ctl Architecture)"
[ "$PKG" = claude-desktop ] || warn "nom de paquet inattendu : $PKG"
[ "$PKGARCH" = "$DEB_ARCH" ] || die "le .deb est $PKGARCH, mais la cible est $ARCH ($DEB_ARCH)"
[ -n "$UPVER" ] || die "Version absente du fichier control"

# Debian "epoch:upstream-revision" -> RPM Epoch, Version, Release.
# The Debian revision leads the Release so an upstream rebuild still upgrades.
EPOCH=""; VER="$UPVER"; DEBREV=""
case "$VER" in *:*) EPOCH="${VER%%:*}"; VER="${VER#*:}" ;; esac
case "$VER" in *-*) DEBREV="${VER##*-}"; VER="${VER%-*}" ;; esac
VER="${VER//-/.}"; DEBREV="${DEBREV//-/.}"
RPMREL="${DEBREV:+$DEBREV.}$RELEASE"
info "claude-desktop $UPVER → RPM ${EPOCH:+$EPOCH:}$VER-$RPMREL ($ARCH)"

APP="$WORK/payload/usr/lib/claude-desktop"
[ -d "$APP" ] || die "structure inattendue : usr/lib/claude-desktop absent du .deb"
[ -x "$APP/claude-desktop" ] || die "binaire usr/lib/claude-desktop/claude-desktop absent"
file -b "$APP/claude-desktop" | grep -q "ELF 64-bit.*$ELF_RE" \
    || die "le binaire principal n'est pas un ELF $ARCH"

# Native modules that make Claude Code work on Linux.
UNP="$APP/resources/app.asar.unpacked/node_modules"
for m in "$UNP/@ant/claude-native/claude-native-binding.node" "$UNP/node-pty/prebuilds/$PTY_DIR/pty.node"; do
    if [ -f "$m" ]; then
        file -b "$m" | grep -q "ELF 64-bit.*$ELF_RE" || die "${m#"$WORK/payload/"} n'est pas un ELF $ARCH"
    else
        warn "module natif absent : ${m#"$WORK/payload/"}"
    fi
done

DESKTOP_FILE="$(find "$WORK/payload/usr/share/applications" -maxdepth 1 -name '*.desktop' -printf '%f\n' 2>/dev/null | head -1)"
[ -n "$DESKTOP_FILE" ] || die "aucun fichier .desktop dans le paquet"

# Bundled shared libraries: excluded from the automatic Requires.
BUNDLED="$(find "$APP" -name '*.so*' -type f -printf '%f\n' | sort -u \
           | tr '+' '.' | paste -sd'|')"
info "bibliothèques embarquées exclues des dépendances : $(echo "$BUNDLED" | tr '|' ' ')"

# Debian Depends, for review: they should all be covered by the spec's
# Requires or by the automatic soname dependencies.
DEPENDS="$(ctl Depends)"

# Maintainer scripts are not carried over; keep a copy for review.
mkdir -p "$OUTDIR/debian-maintscripts-$UPVER"
for s in preinst postinst prerm postrm; do
    [ -f "$WORK/ctrl/$s" ] && cp "$WORK/ctrl/$s" "$OUTDIR/debian-maintscripts-$UPVER/"
done
cp "$WORK/ctrl/control" "$OUTDIR/debian-maintscripts-$UPVER/"

# ------------------------------------------------------------ rpmbuild -------
RB="$WORK/rpmbuild"
mkdir -p "$RB"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}
tar -cf "$RB/SOURCES/claude-desktop-$VER-payload.tar" --owner=root --group=root \
    -C "$WORK/payload" usr
# AppStream metadata, so GNOME Software / Discover list the app.
cat > "$RB/SOURCES/com.anthropic.claude-desktop.metainfo.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>com.anthropic.claude-desktop</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary</project_license>
  <name>Claude</name>
  <summary>Desktop app for Claude, Anthropic's AI assistant</summary>
  <description>
    <p>Claude Desktop brings Claude, Claude Code and Cowork to the Linux desktop.
    This package is rebuilt locally from Anthropic's official .deb.</p>
  </description>
  <developer id="com.anthropic">
    <name>Anthropic</name>
  </developer>
  <launchable type="desktop-id">$DESKTOP_FILE</launchable>
  <url type="homepage">https://claude.ai/download</url>
  <url type="help">https://support.claude.com/</url>
  <content_rating type="oars-1.1"/>
  <releases>
    <release version="$VER" date="$(date +%F)"/>
  </releases>
</component>
XML
cp "$SPEC" "$RB/SPECS/"

info "rpmbuild (charge utile ~500 Mo, compter une à deux minutes)..."
ARGS=(--define "_topdir $RB"
      --define "upstream_version $UPVER"
      --define "rpm_version $VER"
      --define "rpm_release $RPMREL"
      --define "bundled_sonames $BUNDLED"
      --target "$ARCH")
[ -n "$EPOCH" ] && ARGS+=(--define "rpm_epoch $EPOCH")
[ "$NOCHECK" = 1 ] && ARGS+=(--nocheck)
# Only for building on a non-RPM host (e.g. Debian/Ubuntu with the rpm tool).
[ "$NODEPS" = 1 ] && ARGS+=(--nodeps)
# Payload is already compressed binaries: fast zstd beats the default xz.
ARGS+=(--define "_binary_payload w19T.zstdio")

rpmbuild "${ARGS[@]}" -bb "$RB/SPECS/claude-desktop.spec" > "$WORK/rpmbuild.log" 2>&1 \
    || { tail -40 "$WORK/rpmbuild.log" >&2; die "échec de rpmbuild (journal : $WORK/rpmbuild.log, relancez avec --keep)"; }

RPM="$(find "$RB/RPMS" -name '*.rpm' -print -quit)"
[ -n "$RPM" ] || die "rpmbuild n'a produit aucun RPM"
mkdir -p "$OUTDIR"
cp -- "$RPM" "$OUTDIR/"
FINAL="$OUTDIR/$(basename "$RPM")"
cp "$WORK/rpmbuild.log" "$OUTDIR/rpmbuild-$UPVER.log"

# ------------------------------------------------------------- checks --------
MODE="$(rpm -qlvp "$FINAL" 2>/dev/null | awk '/\/chrome-sandbox$/ {print $1}')"
case "$MODE" in
    -rws*) info "chrome-sandbox : bit setuid conservé" ;;
    "")    warn "chrome-sandbox absent du RPM" ;;
    *)     warn "chrome-sandbox en mode $MODE (pas setuid) : Chromium utilisera le bac à sable userns" ;;
esac
if rpm -qpR "$FINAL" 2>/dev/null | grep -Eq "^(${BUNDLED})[(]"; then
    warn "une bibliothèque embarquée apparaît encore dans Requires"
fi

printf '\n\033[32mRPM construit :\033[0m %s\n' "$FINAL"
printf 'Dépendances Debian d'"'"'origine : %s\n' "${DEPENDS:-aucune}"
printf 'Scripts Debian (non repris, pour relecture) : %s\n\n' "$OUTDIR/debian-maintscripts-$UPVER/"
echo "Installation :"
echo "    sudo dnf install $FINAL"
