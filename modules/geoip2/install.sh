#!/bin/sh
if [ "${NXMODULE_COMMON_LOADED:-}" != 1 ]; then . "$(dirname "$0")/lifecycle.sh"; fi

apt_trusted() {
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::https::Timeout=20 -o Acquire::http::Timeout=20 \
        -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false \
        -o APT::Get::AllowUnauthenticated=false "$@"
}
prepare_install() {
    if probe_asset; then return 0; fi
    if ! grep -Eq 'libmaxminddb\.so[^ ]*: (cannot open shared object file: )?No such file|Error loading shared library libmaxminddb\.so' "$NXMODULE_WORK/probe.log"; then
        cat "$NXMODULE_WORK/probe.log" >&2
        return 1
    fi
    case "$NXMODULE_OS" in
        debian:*|ubuntu:*)
            if ! apt_trusted install -y --no-install-recommends --no-remove libmaxminddb0; then
                apt_trusted -o APT::Update::Error-Mode=any update &&
                    apt_trusted install -y --no-install-recommends --no-remove libmaxminddb0 || return 1
            fi ;;
        rocky:*) dnf -y --setopt=gpgcheck=1 --setopt='*.gpgcheck=1' --setopt=timeout=20 install libmaxminddb || return 1 ;;
        alpine:*) apk --no-cache --no-progress add libmaxminddb || return 1 ;;
        *) printf 'Missing libmaxminddb on %s; install it from a trusted system repository.\n' "$NXMODULE_OS" >&2; return 1 ;;
    esac
    probe_asset || { cat "$NXMODULE_WORK/probe.log" >&2; return 1; }
}

install_module "$@"
