Name: tarantool-switchover
Version: 1.0.1
Release: 1%{?dist}
Summary: Handy script to perform consistent switch of Master role in Tarantool replicaset
Group: Applications/Databases
License: BSD
URL: https://gitlab.com/ochaton/switchover
Source0:https://gitlab.com/ochaton/switchover/archive/%{version}/%{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: tarantool >= 1.10
BuildRequires: tarantool-devel >= 1.10
BuildRequires: luarocks
Requires: tarantool >= 1.10
%description
Handy script to perform consistent switch of Master role in Tarantool replicaset

%prep
%setup -q -n %{name}-%{version}

%build

%define luapkgdir %{_datadir}/lua/5.1
%install
%make_install

mkdir -p %{buildroot}/%{_bindir}
install -m 0755 %{buildroot}%{luapkgdir}/switchover.lua %{buildroot}/%{_bindir}/switchover
rm -vf %{buildroot}%{luapkgdir}/switchover.lua
rm -rvf %{buildroot}/usr/lib64/luarocks

install -dm 0755 %{buildroot}/etc/switchover
install -pm 0644 switchover.yaml %{buildroot}/etc/switchover/config.yaml.example

%files
%{_bindir}/switchover
%dir %{luapkgdir}
%{luapkgdir}/switchover/*.lua
%{luapkgdir}/argparse.lua
%{luapkgdir}/net/url.lua
%{luapkgdir}/semver.lua
%config(noreplace) /etc/switchover/config.yaml.example
%doc README.md
%{!?_licensedir:%global license %doc}
%license LICENSE

%changelog
* Wed Dec 30 2020 Vladislav Grubov <v.grubov@corp.mail.ru> 1.0.0-1
- Initial version of the RPM spec