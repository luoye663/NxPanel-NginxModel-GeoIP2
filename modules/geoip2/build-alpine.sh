#!/bin/sh
set -eu

binary=${NXPANEL_NGINX_BIN:?Expected the actual Nginx or OpenResty binary path}
runtime_only=false
if [ "${1:-}" = --runtime-only ]; then
    runtime_only=true
    shift
fi
runtime_sha=${1:?Supply the verified SHA-256 of the runtime source archive}
output=${2:?Supply an isolated build output directory}
fixture=${3:-}
printf '%s\n' "$runtime_sha" | grep -Eq '^[a-f0-9]{64}$'
. /etc/os-release
test "$ID" = alpine
os=$(printf '%s\n' "$VERSION_ID" | cut -d . -f 1,2)
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) exit 1 ;; esac
digest=$(sha256sum "$binary" | cut -d ' ' -f 1)
if "$runtime_only"; then
    apk add --no-cache libmaxminddb
    test "$(sha256sum "$binary" | cut -d ' ' -f 1)" = "$digest"
    exit 0
fi
test -d "$output"
apk add --no-cache build-base linux-headers libmaxminddb-dev openssl-dev pcre2-dev zlib-dev curl ca-certificates
test "$(sha256sum "$binary" | cut -d ' ' -f 1)" = "$digest"
version_output=$("$binary" -V 2>&1)
release=$(printf '%s\n' "$version_output" | sed -n 's/^nginx version: //p')
options=$(printf '%s\n' "$version_output" | sed -n 's/^configure arguments: //p')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
download() { curl --proto '=https' --proto-redir '=https' -fsSL --max-time 90 --retry 2 "$1" -o "$2"; }
check_sha() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }
download https://codeload.github.com/leev/ngx_http_geoip2_module/tar.gz/refs/tags/3.4 geoip2.tar.gz
check_sha "${MODULE_GEOIP2_SHA256:-ad72fc23348d715a330994984531fab9b3606e160483236737f9a4a6957d9452}" geoip2.tar.gz
tar -xzf geoip2.tar.gz
version=${release#*/}
printf '%s\n' "$version" | grep -Eq '^[0-9]+(\.[0-9]+){2,3}$'
case "$release" in
    nginx/*)
        download "https://nginx.org/download/nginx-${version}.tar.gz" nginx.tar.gz
        check_sha "$runtime_sha" nginx.tar.gz
        tar -xzf nginx.tar.gz
        cd "nginx-${version}"
        ;;
    openresty/*)
        download "https://openresty.org/download/openresty-${version}.tar.gz" openresty.tar.gz
        check_sha "$runtime_sha" openresty.tar.gz
        tar -xzf openresty.tar.gz
        source_dir=
        for candidate in "openresty-${version}"/bundle/nginx-[0-9]*; do
            if [ -x "$candidate/configure" ] && [ -d "$candidate/auto" ]; then
                [ -z "$source_dir" ] || exit 1
                source_dir=$candidate
            fi
        done
        [ -n "$source_dir" ] || exit 1
        cd "$source_dir"
        ;;
    *) printf '%s\n' "Unsupported nginx version: $release" >&2; exit 1 ;;
esac

set --
for option in $options; do
    case "$option" in
        --with-compat|--with-debug|--with-threads|--with-file-aio|--with-http_ssl_module|--with-http_v2_module|--with-http_v3_module|--with-http_realip_module|--with-http_dav_module|--with-http_gzip_static_module|--with-http_gunzip_module|--without-http_gzip_module|--without-http_proxy_module|--without-http_fastcgi_module|--without-http_uwsgi_module|--without-http_scgi_module|--without-http_memcached_module|--without-http-cache|--without-http_upstream_zone_module|--without-pcre)
            set -- "$@" "$option"
            ;;
    esac
done
if [ -n "$fixture" ]; then
    set -- "$@" --add-dynamic-module="$fixture"
fi
./configure "$@" --add-dynamic-module="$work/ngx_http_geoip2_module-3.4"
make -j "$(getconf _NPROCESSORS_ONLN)" modules
module=$work/ngx_http_geoip2_module.so
install -m644 objs/ngx_http_geoip2_module.so "$module"
if [ -n "$fixture" ]; then
    install -m644 objs/ngx_http_nxpanel_fixture_module.so "$work/ngx_http_nxpanel_fixture_module.so"
fi
printf '%s\n' "load_module $module;" "error_log stderr;" "pid $work/nginx.pid;" 'events {}' 'http {}' > "$work/test.conf"
"$binary" -t -c "$work/test.conf"
if [ -n "$fixture" ]; then
    sed "s|$module|$work/ngx_http_nxpanel_fixture_module.so|" "$work/test.conf" > "$work/fixture.conf"
    "$binary" -t -c "$work/fixture.conf"
    install -m644 "$work/ngx_http_nxpanel_fixture_module.so" "$output/"
fi
install -m644 "$module" "$output/"
printf '{"os":"alpine:%s","arch":"%s","runtime":"%s","runtime_version":"%s","binary_sha256":"%s"}\n' \
    "$os" "$arch" "${release%/*}" "$version" "$digest" > "$output/target.json"
