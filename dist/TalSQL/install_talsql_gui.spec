Name:           install_talsql_gui
Version:        1.0
Release:        1%{?dist}
Summary:        Графический установщик Талисман SQL
Group:          Applications/System

License:        MIT
URL:            http://example.com
Source0:        install_talsql.sh
Source1:        install_talsql_gui.sh
Source2:        talsql-installer.desktop
Source3:        Firebird-3.0.6.33328_0_Win32.exe
Source4:        Reinstall_Tal3.1.52.exe
Source5:        bdex64.exe
Source6:        designfr.exe

BuildArch:      noarch
Requires:       yad
Requires:       xterm

%description
Графическая оболочка для установки Талисман SQL через Wine.
Позволяет задать путь к префиксу Wine, сервер и учётные данные
перед началом установки.

%prep
# Файлы не распаковываются, они лежат в SOURCES

%build
# Компиляция не требуется

%install
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/local/share/talsql-installer

install -p -m 755 %{SOURCE0} %{buildroot}/usr/local/bin/install_talsql
install -p -m 755 %{SOURCE1} %{buildroot}/usr/local/bin/install_talsql_gui
install -p -m 644 %{SOURCE2} %{buildroot}/usr/share/applications/talsql-installer.desktop

install -p -m 644 %{SOURCE3} %{buildroot}/usr/local/share/talsql-installer/
install -p -m 644 %{SOURCE4} %{buildroot}/usr/local/share/talsql-installer/
install -p -m 644 %{SOURCE5} %{buildroot}/usr/local/share/talsql-installer/
install -p -m 644 %{SOURCE6} %{buildroot}/usr/local/share/talsql-installer/

%files
/usr/local/bin/install_talsql
/usr/local/bin/install_talsql_gui
/usr/share/applications/talsql-installer.desktop
# Правильное указание директории и файлов
%dir /usr/local/share/talsql-installer
/usr/local/share/talsql-installer/Firebird-3.0.6.33328_0_Win32.exe
/usr/local/share/talsql-installer/Reinstall_Tal3.1.52.exe
/usr/local/share/talsql-installer/bdex64.exe
/usr/local/share/talsql-installer/designfr.exe

%post
update-desktop-database &> /dev/null || :

%postun
update-desktop-database &> /dev/null || :

%changelog
* Thu Jun 25 2026 Your Name <your.email@example.com> - 1.0-1
- Initial RPM release with GUI wrapper
- Добавлен выбор пути к префиксу Wine
- Передача учётных данных через GUI
- Добавлены установочные файлы (*.exe) в пакет
- Файлы устанавливаются в /usr/local/share/talsql-installer/ и используются напрямую