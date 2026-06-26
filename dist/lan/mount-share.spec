Name:           mount-share
Version:        1.0
Release:        alt1
Summary:        Script for automated SMB share mounting via autofs
License:        MIT
Group:          Networking/Other
URL:            https://tohch.github.io/madalt/#share-sh

Source0:        mount_share.sh

BuildArch:      noarch

Requires:       autofs
Requires:       samba-client
Requires:       bash

%description
A bash script that simplifies mounting SMB/CIFS network shares using autofs.
It handles server discovery, authentication, autofs configuration, and symlink creation.

%prep
# No source extraction needed for a single script

%build
# No compilation needed

%install
mkdir -p %{buildroot}%{_bindir}
install -m 0755 %{SOURCE0} %{buildroot}%{_bindir}/mount_share

%files
%{_bindir}/mount_share

%changelog
* Tue Jun 09 2026 Каданцев Антон Леонидович <kadantsev.anton@yandex.ru> - 1.0-alt1
- Initial package release