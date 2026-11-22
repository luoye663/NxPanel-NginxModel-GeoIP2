#!/bin/sh
set -eu
umask 077
NXMODULE_COMMON_LOADED=1

digest() (
    if [ "$1" != - ]; then exec < "$1" || exit 1; fi
    checksum=$(sha256sum) || exit 1
    printf '%s\n' "${checksum%% *}"
)
same_content() (
    first_hash=$(digest "$1") && second_hash=$(digest "$2") && [ "$first_hash" = "$second_hash" ]
)
fail() { printf '%s\n' "$*" >&2; exit 10; }
start_time() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{ print $20 }'; }
same_master() {
    [ "$(start_time "$NXMODULE_MASTER_PID")" = "$NXMODULE_MASTER_START" ] &&
        [ "$(readlink -f "/proc/$NXMODULE_MASTER_PID/exe")" = "$NXMODULE_NGINX" ]
}
active_workers() {
    for child in $(cat "/proc/$NXMODULE_MASTER_PID/task/$NXMODULE_MASTER_PID/children"); do
        title=$(tr '\000' ' ' < "/proc/$child/cmdline" 2>/dev/null) || continue
        case "$title" in
            'nginx: worker process is shutting down'*) ;;
            'nginx: worker process'*) printf '%s:%s\n' "$child" "$(start_time "$child")" ;;
        esac
    done
}
reload_workers() {
    same_master || return 1
    baseline=$(active_workers)
    [ -n "$baseline" ] || return 1
    same_master && kill -HUP "$NXMODULE_MASTER_PID" || return 1
    attempts=0
    stable=0
    last=''
    while [ "$attempts" -lt 48 ]; do
        sleep 0.25
        same_master || return 1
        current=$(active_workers)
        ready=1
        [ -n "$current" ] || ready=0
        for worker in $current; do
            if printf '%s\n' "$baseline" | grep -Fqx "$worker"; then ready=0; fi
        done
        if [ "$ready" = 1 ]; then
            if [ "$last" = "$current" ]; then stable=$((stable + 1)); else stable=0; fi
            [ "$stable" -lt 2 ] || return 0
        else
            stable=0
        fi
        last=$current
        attempts=$((attempts + 1))
    done
    return 1
}
safe_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
missing() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
copy_attributes() {
    if cp --help 2>&1 | grep -q -- '--preserve'; then cp --preserve=all "$1" "$2"; else cp -p "$1" "$2"; fi
}
replace_checked() {
    replacing=$1
    expected=$2
    replacement=$3
    safe_file "$replacing" && same_content "$replacing" "$expected" || return 1
    transient=$(mktemp "$(dirname "$replacing")/.nxmodule.XXXXXX") || return 1
    if copy_attributes "$replacing" "$transient" && cat "$replacement" > "$transient" &&
        safe_file "$replacing" && same_content "$replacing" "$expected" && mv -f "$transient" "$replacing"; then
        return 0
    fi
    rm -f "$transient"
    return 1
}
install_private() {
    destination=$1
    payload=$2
    missing "$destination" || return 1
    temporary=$(mktemp "$(dirname "$destination")/.nxmodule.XXXXXX") || return 1
    if cat "$payload" > "$temporary" && ln "$temporary" "$destination"; then
        rm -f "$temporary"
        return 0
    fi
    rm -f "$temporary"
    return 1
}
probe_asset() {
    printf 'load_module "%s";\nerror_log stderr;\npid probe.pid;\nevents {}\nhttp {}\n' "$NXMODULE_ASSET" > "$NXMODULE_WORK/probe.conf"
    "$NXMODULE_NGINX" -t -e stderr -p "$NXMODULE_WORK/" -c "$NXMODULE_WORK/probe.conf" > "$NXMODULE_WORK/probe.log" 2>&1
}
prepare_install() { probe_asset || { cat "$NXMODULE_WORK/probe.log" >&2; return 1; }; }
prepare_uninstall() { :; }

begin_operation() {
    [ "$(id -u)" = 0 ] && [ "${NXMODULE_PROTOCOL:-}" = 1 ] || fail 'Unsupported module script context.'
    [ "$(pwd -P)" = "$NXMODULE_WORK" ] && [ "$NXMODULE_FRAGMENT" = "$NXMODULE_STATE/active/$NXMODULE_ID.conf" ] || fail 'Invalid module work directory.'
    same_master && [ "$(digest "$NXMODULE_NGINX")" = "$NXMODULE_BIN_SHA256" ] || fail 'Nginx runtime has changed.'
    safe_file "$NXMODULE_CONF" && [ "$(readlink -f "$NXMODULE_CONF_ALIAS")" = "$NXMODULE_CONF" ] &&
        [ "$(digest "$NXMODULE_CONF")" = "$NXMODULE_CONF_SHA256" ] || fail 'Nginx configuration has changed.'
    safe_file "$NXMODULE_ASSET" && [ "$(digest "$NXMODULE_ASSET")" = "$NXMODULE_ASSET_SHA256" ] || fail 'Invalid module payload.'
    original=$NXMODULE_WORK/main.before
    candidate=$NXMODULE_WORK/main.after
    fragment_original=$NXMODULE_WORK/load.before
    fragment_candidate=$NXMODULE_WORK/load.after
    shared_original=$NXMODULE_WORK/shared.before
    shared_candidate=$NXMODULE_WORK/shared.after
    main_changed=0 fragment_changed=0 shared_changed=0 signalled=0 shared=''
    cp "$NXMODULE_CONF" "$original"
    printf '# NXPANEL-MANAGED-MODULES\ninclude %s/active/*.conf;\n' "$NXMODULE_STATE" > "$NXMODULE_WORK/include.conf"
    printf '# NXPANEL-DYNAMIC-MODULE %s %s\nload_module "%s";\n' "$NXMODULE_BIN_SHA256" "$NXMODULE_SYMBOL" "$NXMODULE_DEST" > "$fragment_candidate"
    trap 'finish "$@"' EXIT
    trap 'exit 20' HUP INT TERM
}
finish() {
    outcome=$?
    trap - EXIT HUP INT TERM
    [ "$outcome" -ne 0 ] || exit 0
    restored=1
    if [ "$main_changed" = 1 ]; then replace_checked "$NXMODULE_CONF" "$candidate" "$original" || restored=0; fi
    if [ "$fragment_changed" = 1 ]; then
        if [ "$NXMODULE_ACTION" = install ]; then
            safe_file "$NXMODULE_FRAGMENT" && same_content "$NXMODULE_FRAGMENT" "$fragment_candidate" && rm "$NXMODULE_FRAGMENT" || restored=0
        else
            install_private "$NXMODULE_FRAGMENT" "$fragment_original" || restored=0
        fi
    fi
    if [ "$shared_changed" = 1 ]; then replace_checked "$shared" "$shared_candidate" "$shared_original" || restored=0; fi
    if [ "$restored" = 1 ] && [ "$signalled" = 1 ]; then
        "$NXMODULE_NGINX" -t "$@" && reload_workers || restored=0
    fi
    if [ "$restored" = 1 ]; then exit 10; fi
    printf '%s\n' 'Nginx configuration restoration could not be confirmed.' >&2
    exit 20
}
validate_and_reload() {
    if ! "$NXMODULE_NGINX" -t "$@"; then fail 'Nginx 配置检查未通过；请检查是否仍引用该模块。'; fi
    same_master || fail 'Nginx 主进程已变化。'
    signalled=1
    reload_workers || fail '未确认 Nginx 新 worker 接管。'
}

install_module() {
    [ "${NXMODULE_ACTION:-}" = install ] || fail 'Wrong module action.'
    begin_operation "$@"
    prepare_install || fail 'Module trial did not pass.'
    same_master && [ "$(digest "$NXMODULE_NGINX")" = "$NXMODULE_BIN_SHA256" ] && same_content "$original" "$NXMODULE_CONF" || fail 'Nginx has changed during preparation.'
    mkdir -p "$(dirname "$NXMODULE_DEST")" "$(dirname "$NXMODULE_FRAGMENT")"
    if missing "$NXMODULE_DEST"; then
        install_private "$NXMODULE_DEST" "$NXMODULE_ASSET" || fail 'Could not stage module.'
    else
        safe_file "$NXMODULE_DEST" && same_content "$NXMODULE_DEST" "$NXMODULE_ASSET" || fail 'Module cache differs from the signed asset.'
    fi
    if ! head -n 2 "$original" | same_content - "$NXMODULE_WORK/include.conf"; then
        if grep -Fxq '# NXPANEL-MANAGED-MODULES' "$original"; then fail 'Unexpected module include marker.'; fi
        cat "$NXMODULE_WORK/include.conf" "$original" > "$candidate"
    fi
    install_private "$NXMODULE_FRAGMENT" "$fragment_candidate" || fail 'Module is already configured.'
    fragment_changed=1
    if [ -f "$candidate" ]; then
        replace_checked "$NXMODULE_CONF" "$original" "$candidate" || fail 'Nginx configuration has changed.'
        main_changed=1
    fi
    validate_and_reload "$@"
}

uninstall_module() {
    [ "${NXMODULE_ACTION:-}" = uninstall ] || fail 'Wrong module action.'
    begin_operation "$@"
    prepare_uninstall || fail 'Module configuration has been modified or cannot be retired.'
    safe_file "$NXMODULE_FRAGMENT" && same_content "$NXMODULE_FRAGMENT" "$fragment_candidate" || fail 'Module load file has changed.'
    cp "$NXMODULE_FRAGMENT" "$fragment_original"
    rm "$NXMODULE_FRAGMENT"
    fragment_changed=1
    if [ -n "$shared" ]; then
        replace_checked "$shared" "$shared_original" "$shared_candidate" || fail 'Shared module configuration has changed.'
        shared_changed=1
    fi
    validate_and_reload "$@"
}
