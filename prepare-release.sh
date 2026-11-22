#!/usr/bin/env bash
set -euo pipefail

nxpanel=${1:?Specify the NxPanel checkout}
repository=${2:?Specify the GitHub module repository (owner/repo)}
tag=${3:?Specify a new release tag (vMAJOR.MINOR.PATCH)}
stage=${4:-all}
[[ $# -le 4 ]]
[[ "$repository" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$ ]]
[[ "$tag" =~ ^v(0|[1-9][0-9]{0,11})\.(0|[1-9][0-9]{0,11})\.(0|[1-9][0-9]{0,11})$ ]]
root=$(cd -- "$(dirname -- "$0")" && pwd -P)
config=${MODULE_TARGETS_FILE:-$root/publish-targets.json}
go_bin=${GO:-go}

die() { printf '%s\n' "$*" >&2; exit 1; }

validate_config() {
    jq -e '
        def sha: type == "string" and test("^[0-9a-f]{64}$");
        def image: type == "string" and test("^(docker\\.io|ghcr\\.io)/([a-z0-9][a-z0-9_.-]*/)+[a-z0-9][a-z0-9_.-]*@sha256:[0-9a-f]{64}$");
        keys == ["geoip2_sha256", "mmdb_commit", "mmdb_sha256", "targets"] and
        (.geoip2_sha256 | sha) and (.mmdb_sha256 | sha) and (.mmdb_commit | test("^[0-9a-f]{40}$")) and
        (.targets | type == "array" and length > 0 and length <= 128 and length == (unique_by(.name) | length) and all(.[];
            (.name | test("^[a-z][a-z0-9_-]{0,59}$")) and (.arch | IN("amd64", "arm64")) and
            (.runtime | IN("nginx", "openresty")) and (.image | image) and
            (.os | test("^[a-z0-9][a-z0-9_-]{0,23}:[a-z0-9][a-z0-9._-]{0,23}$")) and
            (.runtime_sha256 | sha) and (if has("binary_sha256") then (.binary_sha256 | sha) else true end) and
            (del(.binary_sha256) | if .builder == "host" then
                keys == ["arch", "builder", "image", "name", "os", "package_version", "runtime", "runtime_sha256"] and
                (.os | startswith("alpine:") | not) and (.package_version | test("^[A-Za-z0-9][A-Za-z0-9.+:~_-]{0,127}$"))
            elif .builder == "alpine" then
                keys == ["arch", "builder", "image", "name", "os", "runtime", "runtime_sha256"] and (.os | startswith("alpine:"))
            else false end))) and
        (all(.targets[]; .os != "ubuntu:22.04" or has("binary_sha256")))
    ' "$config" >/dev/null || die "Invalid build target configuration: $config"
}

validate_config
if [[ "$stage" == targets ]]; then
    jq -cer '[.targets[].arch] | unique' "$config"
    exit 0
fi
case "$stage" in all|build|bundle|verify) ;; *) die "Unknown stage: $stage" ;; esac
nxpanel=$(cd -- "$nxpanel" && pwd -P)
[[ -f "$nxpanel/go.mod" ]] || die "Missing NxPanel checkout: $nxpanel"
work=${MODULE_WORK_DIR:-$root/.work}
mkdir -p -- "$work"
work=$(cd -- "$work" && pwd -P)
builds=$work/builds
bundle=$work/bundle
if [[ "$stage" != bundle ]]; then
    case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die 'Unsupported build architecture' ;; esac
fi
geoip_sha=$(jq -er '.geoip2_sha256' "$config")
mmdb_commit=$(jq -er '.mmdb_commit' "$config")
mmdb_sha=$(jq -er '.mmdb_sha256' "$config")
containers=() images=()
scratch=$(mktemp -d "$work/.prepare.XXXXXX")

cleanup() {
    if ((${#containers[@]})); then docker rm -f "${containers[@]}" >/dev/null 2>&1 || true; fi
    if ((${#images[@]})); then docker image rm "${images[@]}" >/dev/null 2>&1 || true; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

targets() { jq -ce --arg arch "$1" '.targets[] | select($arch == "" or .arch == $arch)' "$config"; }

read_target() {
    IFS=$'\t' read -r name builder target_arch runtime image runtime_sha <<< "$(jq -er '[.name,.builder,.arch,.runtime,.image,.runtime_sha256] | @tsv' <<< "$1")"
    package=$(jq -r '.package_version // ""' <<< "$1")
    expected=$(jq -r '.binary_sha256 // ""' <<< "$1")
    case "$runtime" in
        nginx) binary=/usr/sbin/nginx ;;
        openresty) binary=/usr/local/openresty/nginx/sbin/nginx ;;
    esac
}

run_target() {
    local operation=$1 output=$2 container verifier entrypoint script
    local -a args=() options=(--platform "linux/$target_arch" --user 0:0)
    if [[ "$operation" == verify ]]; then args+=(--runtime-only); fi
    case "$builder" in
        host)
            entrypoint=/bin/bash
            script=$nxpanel/scripts/build-host-geoip2.sh
            args+=("$runtime" "$package" "$runtime_sha" "$geoip_sha" "$mmdb_commit" "$mmdb_sha" /out "$expected") ;;
        alpine)
            entrypoint=/bin/sh
            script=$root/modules/geoip2/build-alpine.sh
            options+=(--env "NXPANEL_NGINX_BIN=$binary" --env "MODULE_GEOIP2_SHA256=$geoip_sha")
            args+=("$runtime_sha" /out) ;;
    esac
    if [[ "$operation" == build ]]; then
        options+=(--mount "type=bind,source=$output,target=/out")
    fi
    printf '%s %s (%s)\n' "$operation" "$name" "$image" >&2
    container=$(docker create "${options[@]}" --entrypoint "$entrypoint" \
        --mount "type=bind,source=$script,target=/build-geoip2.sh,readonly" "$image" /build-geoip2.sh "${args[@]}")
    containers+=("$container")
    docker start -a "$container"
    [[ $(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' "$container") == 'exited 0' ]]
    if [[ "$operation" == verify ]]; then
        verifier=$(docker commit "$container")
        [[ "$verifier" =~ ^sha256:[0-9a-f]{64}$ ]]
        images+=("$verifier")
        jq -cn --arg arch "$target_arch" --arg binary "$binary" --arg image "$verifier" \
            '{arch:$arch,binary:$binary,image:$image}' >> "$scratch/verifiers.jsonl"
    fi
    docker rm "$container" >/dev/null
    unset 'containers[-1]'
}

check_build() {
    local recipe=$1 output=$2
    [[ -s "$output/ngx_http_geoip2_module.so" ]] || die "Missing module build: $output"
    jq -e --argjson recipe "$recipe" '.os == $recipe.os and .arch == $recipe.arch and .runtime == $recipe.runtime and
        (.binary_sha256 | test("^[0-9a-f]{64}$")) and ($recipe.binary_sha256 == null or .binary_sha256 == $recipe.binary_sha256)' \
        "$output/target.json" >/dev/null || die "Target fingerprint does not match recipe: $output"
}

build() {
    local selected recipe output
    selected=$(targets "$arch") || die "No build targets for $arch"
    while IFS= read -r recipe; do
        read_target "$recipe"
        output=$builds/geoip2/$name
        mkdir -p -- "$builds/geoip2"
        mkdir -- "$output" || die "Choose a new work directory: $output already exists"
        run_target build "$output"
        check_build "$recipe" "$output"
    done <<< "$selected"
}

pack() {
    local selected recipe output
    local -A expected_dirs=()
    [[ ! -e "$bundle" ]] || die "Choose a new work directory: $bundle already exists"
    selected=$(targets "$1") || die 'No targets to package'
    while IFS= read -r recipe; do
        read_target "$recipe"
        output=$builds/geoip2/$name
        check_build "$recipe" "$output"
        expected_dirs["$output/"]=1
    done <<< "$selected"
    for output in "$builds/geoip2/"*/; do
        [[ ${expected_dirs[$output]+found} == found ]] || die "Unexpected build directory: $output"
    done
    sh "$root/modules/geoip2/package-scripts.sh" "$builds/geoip2"
    jq -e --arg repo "$repository" --arg tag "$tag" '
        if length == 1 and .[0].id == "geoip2" then .[0] += {version:$tag,release:{repository:$repo,tag:$tag}}
        else error("expected one GeoIP2 module definition") end' "$root/module-definitions.json" > "$scratch/metadata.json"
    "$go_bin" -C "$nxpanel" run ./cmd/nxpanel-module-catalog -prepare -metadata "$scratch/metadata.json" -input "$builds" -output "$bundle"
    sha256sum "$bundle/candidate.json"
}

verify() {
    local selected recipe verifiers
    [[ -s "$bundle/candidate.json" ]] || die "Missing release bundle: $bundle"
    selected=$(targets "$arch") || die "No verification targets for $arch"
    while IFS= read -r recipe; do
        read_target "$recipe"
        run_target verify ''
    done <<< "$selected"
    verifiers=$(jq -cs '.' "$scratch/verifiers.jsonl")
    (cd -- "$nxpanel" && GO="$go_bin" NXPANEL_MODULE_SMOKE_LOCAL_IMAGES=1 \
        bash scripts/nginx-module-smoke/verify-candidate.sh "$bundle" "$verifiers" "$arch")
}

case "$stage" in
    all) build; pack "$arch" ;;
    build) build ;;
    bundle) pack '' ;;
    verify) verify ;;
esac
