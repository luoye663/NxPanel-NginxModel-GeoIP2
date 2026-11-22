#!/usr/bin/env bash
set -euo pipefail

config=${1:?Supply the validated target configuration}
arch=${2:?Supply the build architecture}
path=${3:?Supply an absolute Nginx binary path}
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$path" == /* ]] || die 'Supply an absolute Nginx binary path.'
binary=$(realpath -e "$path")
[[ -f "$binary" && -x "$binary" ]] || die "Not an executable file: $binary"
. /etc/os-release
case "${ID}:${VERSION_ID}" in
    debian:12|debian:12.*) os=debian:12; image=debian:12 ;;
    debian:13|debian:13.*) os=debian:13; image=debian:13 ;;
    ubuntu:22.04|ubuntu:24.04) os="ubuntu:$VERSION_ID"; image=$os ;;
    rocky:9|rocky:9.*) os=rocky:9; image=rockylinux/rockylinux:9 ;;
    *) die "Unsupported local test OS: $ID:$VERSION_ID" ;;
esac

release=$("$binary" -V 2>&1 | sed -n 's/^nginx version: //p')
[[ "$release" =~ ^(nginx|openresty)/[0-9]+(\.[0-9]+){2,3}$ ]] || die 'Could not identify the Nginx or OpenResty version.'
runtime=${release%/*}
if [[ "$os" == debian:13 && "$runtime" == openresty ]]; then
    die 'Debian 13 has no official OpenResty trixie repository; use Nginx for this target.'
fi
if [[ "$os" == rocky:9 ]]; then
    info=$(rpm -qf --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' "$binary")
    IFS=$'\t' read -r owner package_version <<< "$info"
    [[ "$owner" == "$runtime" ]] || die "Expected $binary to belong to the official $runtime package."
else
    info=$(dpkg-query -S "$binary")
    [[ "$info" == "$runtime: $binary" || "$info" == "$runtime:$arch: $binary" ]] || die "Expected $binary to belong to the official $runtime package."
    package_version=$(dpkg-query -W -f='${Version}' "$runtime")
fi
[[ "$package_version" =~ ^[A-Za-z0-9][A-Za-z0-9.+:~_-]{0,127}$ ]] || die "Invalid $runtime package version."
digest=$(sha256sum "$binary" | cut -d ' ' -f 1)

match=$(jq -c --arg os "$os" --arg arch "$arch" --arg runtime "$runtime" --arg package "$package_version" --arg digest "$digest" '
    [.targets[] | select(.builder == "host" and .os == $os and .arch == $arch and .runtime == $runtime and
        .package_version == $package and (.binary_sha256 == null or .binary_sha256 == $digest))] |
    if length == 1 then .[0] else null end' "$config")
runtime_sha=${MODULE_RUNTIME_SHA256:-}
if [[ "$match" != null ]]; then
    image=$(jq -er '.image' <<< "$match")
    runtime_sha=${runtime_sha:-$(jq -er '.runtime_sha256' <<< "$match")}
fi
[[ "$runtime_sha" =~ ^[a-f0-9]{64}$ ]] || die "Set MODULE_RUNTIME_SHA256 to the verified official source archive checksum for $release."

jq -cn --arg os "$os" --arg arch "$arch" --arg runtime "$runtime" --arg image "$image" \
    --arg package "$package_version" --arg runtime_sha "$runtime_sha" --arg digest "$digest" \
    '{name:"local-host",builder:"host",os:$os,arch:$arch,runtime:$runtime,image:$image,package_version:$package,
        runtime_sha256:$runtime_sha,binary_sha256:$digest}'
