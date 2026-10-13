# claude-desktop-builder — redistributable packaging for Claude Desktop.
#
# Claude Desktop is proprietary and may not be redistributed, so this package
# never contains it. It ships the build script, the spec and an update
# service: Anthropic's official .deb is downloaded, verified and rebuilt as
# an RPM on the user's own machine, then installed with dnf.

%{!?_unitdir:%global _unitdir /usr/lib/systemd/system}
%{!?_sysusersdir:%global _sysusersdir /usr/lib/sysusers.d}

Name:           claude-desktop-builder
Version:        1.0.0
Release:        1%{?dist}
Summary:        Builds and updates Claude Desktop from Anthropic's official Linux package
License:        MIT
URL:            https://claude.ai/download
Source0:        %{name}-%{version}.tar.gz
Source1:        %{name}.sysusers

BuildArch:      noarch

# Everything build-rpm.sh needs, plus dnf to install what it produces.
Requires:       rpm-build
Requires:       binutils
Requires:       file
Requires:       xz
Requires:       gzip
Requires:       curl
Requires:       gnupg2
Requires:       desktop-file-utils
Requires:       util-linux
Requires:       dnf
Requires(pre):  shadow-utils

%description
Claude Desktop is proprietary software owned by Anthropic and cannot be
redistributed, so it is not in this package. This package provides the tools
to rebuild it locally instead:

  * claude-desktop-update: checks Anthropic's signed apt repository, and when a
    newer release exists downloads the official .deb (GPG signature and
    SHA256 verified), rebuilds it as a native RPM as an unprivileged user,
    and installs it with dnf.
  * claude-desktop-update.timer: runs that check daily once enabled.

After installing, run "sudo claude-desktop-update" once, then optionally
"sudo systemctl enable --now claude-desktop-update.timer".

%prep
%autosetup

%build
# Nothing to compile.

%install
install -Dpm 0755 build-rpm.sh        %{buildroot}%{_libexecdir}/%{name}/build-rpm.sh
install -Dpm 0644 claude-desktop.spec %{buildroot}%{_libexecdir}/%{name}/claude-desktop.spec
install -Dpm 0755 builder/claude-desktop-update %{buildroot}%{_bindir}/claude-desktop-update
install -Dpm 0644 builder/claude-desktop-update.service %{buildroot}%{_unitdir}/claude-desktop-update.service
install -Dpm 0644 builder/claude-desktop-update.timer   %{buildroot}%{_unitdir}/claude-desktop-update.timer
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_sysusersdir}/%{name}.conf
install -dm 0755 %{buildroot}%{_localstatedir}/lib/%{name}

%check
bash -n build-rpm.sh
bash -n builder/claude-desktop-update

%pre
getent group claude-desktop-builder >/dev/null || groupadd -r claude-desktop-builder
getent passwd claude-desktop-builder >/dev/null || \
    useradd -r -g claude-desktop-builder -d %{_localstatedir}/lib/%{name} \
            -s /sbin/nologin -c "Claude Desktop RPM builder" claude-desktop-builder
exit 0

%post
if [ $1 -eq 1 ]; then
    systemctl --no-reload preset claude-desktop-update.timer >/dev/null 2>&1 || :
fi

%preun
if [ $1 -eq 0 ]; then
    systemctl --no-reload disable --now claude-desktop-update.timer >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%files
%license LICENSE
%doc README.md
%{_bindir}/claude-desktop-update
%dir %{_libexecdir}/%{name}
%{_libexecdir}/%{name}/build-rpm.sh
%{_libexecdir}/%{name}/claude-desktop.spec
%{_unitdir}/claude-desktop-update.service
%{_unitdir}/claude-desktop-update.timer
%{_sysusersdir}/%{name}.conf
%attr(0755,claude-desktop-builder,claude-desktop-builder) %dir %{_localstatedir}/lib/%{name}

%changelog
* Mon Oct 12 2026 Ismaël - 1.0.0-1
- First release
