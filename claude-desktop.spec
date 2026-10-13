# claude-desktop.spec — repackage Anthropic's official Claude Desktop .deb as a
# native RPM for Fedora, RHEL/Alma/Rocky 9+ and openSUSE.
#
# This spec is driven by build-rpm.sh, which unpacks the .deb and passes in:
#   upstream_version  version string from the Debian control file
#   rpm_version       same, made RPM-safe ('-' -> '.', epoch removed)
#   rpm_epoch         Debian epoch, if any (optional)
#   rpm_release       release number (default 1)
#   bundled_sonames   'a.so|b.so.1|…' — libraries shipped inside the app dir
#
# The payload is prebuilt Electron: nothing is compiled, stripped or patched.

%global appdir %{_prefix}/lib/claude-desktop

# Prebuilt upstream binaries: no debuginfo, no stripping, no rpath checks.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global __brp_check_rpaths %{nil}
%global _build_id_links none

# Libraries bundled in the app dir must not leak as system-wide Provides,
# and Requires on them must be dropped (they resolve via $ORIGIN, not ld.so).
# Every other soname dependency is generated automatically, so the package
# pulls the right system libraries on any RPM distribution.
%global __provides_exclude_from ^%{appdir}/.*$
%global __requires_exclude ^(%{?bundled_sonames}%{!?bundled_sonames:__none__})[(]

Name:           claude-desktop
%{?rpm_epoch:Epoch: %{rpm_epoch}}
Version:        %{rpm_version}
Release:        %{?rpm_release}%{!?rpm_release:1}%{?dist}
Summary:        Claude Desktop, Anthropic's AI assistant (official Linux build)
License:        LicenseRef-Proprietary
URL:            https://claude.ai/download
Source0:        claude-desktop-%{rpm_version}-payload.tar
Source1:        com.anthropic.claude-desktop.metainfo.xml

ExclusiveArch:  x86_64 aarch64

BuildRequires:  desktop-file-utils

# Mirrors the upstream .deb Depends (checked against 2.31226.1), with the
# Fedora/RHEL package names. Linked libraries are also covered by the
# automatic soname scan; these catch what Electron dlopen()s or execs.
Requires:       gtk3
Requires:       nss
Requires:       libnotify
Requires:       libsecret
Requires:       libXtst
Requires:       libdrm
Requires:       mesa-libgbm
Requires:       at-spi2-core
Requires:       libuuid
Requires:       xdg-utils
Requires:       hicolor-icon-theme
# Screen sharing under Wayland.
Requires:       pipewire-libs
Requires:       xdg-desktop-portal
Recommends:     (xdg-desktop-portal-gtk or xdg-desktop-portal-gnome or xdg-desktop-portal-kde)
# Moving files to the trash (gio comes with glib2, already pulled by gtk3).
Recommends:     (kde-cli-tools or trash-cli or gvfs)
# Tray icon (EPEL on RHEL).
Recommends:     libappindicator-gtk3
# Secret storage for the session token.
Recommends:     (gnome-keyring or kf6-kwallet or keepassxc)
# Cowork's sandbox VM: KVM + QEMU, optional.
Suggests:       (qemu-system-x86-core or qemu-kvm)
Suggests:       edk2-ovmf
Suggests:       virtiofsd

%description
Claude Desktop for Linux, repackaged as a native RPM from Anthropic's
official .deb (upstream version %{upstream_version}).

The application payload under %{appdir} is byte-for-byte the upstream
content, including the Linux-native claude-native and node-pty modules that
Claude Code needs. Only the Debian-specific packaging is replaced: the
AppArmor user-namespace profile (Ubuntu only; Fedora and RHEL use SELinux and
allow unprivileged user namespaces) and the apt repository registration are
not installed. The Chromium setuid sandbox helper is kept at mode 4755.

This package is rebuilt locally from the downloaded .deb and does not update
itself: re-run build-rpm.sh to pick up a new release.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}

%build
# Nothing to build: prebuilt upstream payload.

%install
mkdir -p %{buildroot}
cp -a usr %{buildroot}/

# Debian-only bits that sometimes travel in the payload.
rm -rf %{buildroot}%{_datadir}/lintian \
       %{buildroot}%{_sysconfdir}/apt \
       %{buildroot}%{_sysconfdir}/apparmor.d \
       %{buildroot}%{_sysconfdir}/cron.daily

# Chromium's setuid sandbox helper: unprivileged tar drops the bit.
if [ -f %{buildroot}%{appdir}/chrome-sandbox ]; then
    chmod 4755 %{buildroot}%{appdir}/chrome-sandbox
fi

# Launcher: make sure /usr/bin/claude-desktop exists even if upstream changes
# how it ships it.
if [ ! -e %{buildroot}%{_bindir}/claude-desktop ] && [ ! -L %{buildroot}%{_bindir}/claude-desktop ]; then
    mkdir -p %{buildroot}%{_bindir}
    ln -s ../lib/claude-desktop/claude-desktop %{buildroot}%{_bindir}/claude-desktop
fi

# AppStream metadata so GNOME Software / Discover list the app.
install -Dpm 0644 %{SOURCE1} \
    %{buildroot}%{_datadir}/metainfo/com.anthropic.claude-desktop.metainfo.xml

# Everything outside the app dir is listed file by file, so whatever
# upstream ships (icons, docs, man pages) is packaged without guessing.
( cd %{buildroot}
  find .%{_prefix} -path ".%{appdir}" -prune -o \( -type f -o -type l \) -print \
    | sed 's|^\.||' | sort
  [ -d .%{_docdir}/%{name} ] && echo "%%dir %{_docdir}/%{name}"
) > %{_builddir}/%{name}-%{rpm_version}/extra-files.list

%check
for f in %{buildroot}%{_datadir}/applications/*.desktop; do
    desktop-file-validate "$f"
done
test -x %{buildroot}%{appdir}/claude-desktop
test -e %{buildroot}%{_bindir}/claude-desktop

# Icon caches, the desktop database and the MIME cache are refreshed by file
# triggers on Fedora >= 28 and RHEL >= 8, so no %%post scriptlet is needed.

%files -f extra-files.list
%defattr(-,root,root,-)
%{appdir}

%changelog
* %(LC_ALL=C date '+%a %b %d %Y') build-rpm.sh - %{rpm_version}-%{?rpm_release}%{!?rpm_release:1}
- Repackaged from Anthropic's official claude-desktop %{upstream_version} .deb
