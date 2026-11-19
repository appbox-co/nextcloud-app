#!/usr/bin/env bash
# Release gate for repo.cylo.net/nextcloud:27.1.5-2: repo.cylo.net/nextcloud:27.1.5-1
# plus /etc/my_init.d/05_runtime_dirs.sh, which recreates /run/php, /run/mysqld
# and /run/sshd at every container start.
#
# Usage: ./release-gate.sh repo.cylo.net/nextcloud:27.1.5-2   (release)
#        ./release-gate.sh local/nextcloud-trial:27.1.5-2     (trial)
#
# Against the 27.1.5-1 base digest it checks: one added layer, identical
# runtime configuration and labels, identical packages, identical files under
# the compared paths apart from the added script, and identical CLI and FPM
# module lists. It runs php-fpm8.1 -t and nginx -t, then the restart
# regression: my_init's startup scripts in a container with a fresh tmpfs on
# /run (as Appbox runs it), followed by php-fpm8.1 creating its socket, appbox
# creating a socket in /run/mysqld (the image has no mysqld; /scripts/mysql.sh
# installs it on first container start) and sshd -t. The same regression must fail on the
# 27.1.5-1 base, which proves it detects the outage. Both modes require the
# release tag to be absent from the registry; trial images are never pushed.
set -euo pipefail

release_ref=repo.cylo.net/nextcloud:27.1.5-2
trial_ref=local/nextcloud-trial:27.1.5-2
base_ref=repo.cylo.net/nextcloud@sha256:9de39c1b3f81fae18f3067766d4b77e01e581367449fba0c409a0d526568208a
added_layers=1
added_script=/etc/my_init.d/05_runtime_dirs.sh
compared_paths="/etc/php /etc/my_init.d /app-sources /etc/nginx /etc/service /etc/container_environment /etc/cron.d /etc/ssh/sshd_config /scripts /sbin/my_init /sources"
gate_dir=$(cd "$(dirname "$0")" && pwd)

usage() {
    echo "Usage: $0 $release_ref  (or $trial_ref for a trial build)" >&2
    exit 2
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || usage
case "$1" in
    "$release_ref") mode=release ;;
    "$trial_ref") mode=trial ;;
    *) usage ;;
esac
image_ref=$1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

in_image() {
    local ref=$1
    shift
    docker run --rm --network none -v "$gate_dir/release:/release:ro" --entrypoint sh "$ref" "$@"
}

echo "== Image and base ($mode)"
docker image inspect "$base_ref" >/dev/null 2>&1 || docker pull -q "$base_ref" >/dev/null
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")
[ "$platform" = linux/amd64 ] || fail "wrong image platform: $platform"

config_filter='{Env, Cmd, Entrypoint, User, WorkingDir, ExposedPorts, Volumes, StopSignal, Shell, Healthcheck, Labels}'
diff -u <(docker image inspect --format '{{json .Config}}' "$base_ref" | jq -S "$config_filter") \
    <(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -S "$config_filter") \
    || fail "runtime configuration differs from 27.1.5-1"

docker image inspect --format '{{json .RootFS.Layers}}' "$base_ref" | jq -r '.[]' > "$work/base-layers"
docker image inspect --format '{{json .RootFS.Layers}}' "$image_ref" | jq -r '.[]' > "$work/image-layers"
[ "$(wc -l < "$work/image-layers")" -eq "$(( $(wc -l < "$work/base-layers") + added_layers ))" ] \
    || fail "expected exactly $added_layers layer on top of 27.1.5-1"
head -n "$(wc -l < "$work/base-layers")" "$work/image-layers" | cmp -s - "$work/base-layers" \
    || fail "image is not built on the 27.1.5-1 layers"
echo "$added_layers layer on top of $base_ref"

echo "== Packages unchanged"
dpkg_list='dpkg-query -W -f="\${db:Status-Abbrev}|\${binary:Package}|\${source:Package}|\${Version}\n"'
diff -u <(in_image "$base_ref" -c "$dpkg_list" | sort) <(in_image "$image_ref" -c "$dpkg_list" | sort) \
    || fail "installed packages differ from 27.1.5-1"
echo "packages identical"

echo "== Files unchanged apart from $added_script"
# shellcheck disable=SC2086
in_image "$base_ref" /release/file-manifest.sh $compared_paths > "$work/base-files"
# shellcheck disable=SC2086
in_image "$image_ref" /release/file-manifest.sh $compared_paths > "$work/image-files"
script_hash=$(sha256sum < "$gate_dir/05_runtime_dirs.sh" | cut -c1-64)
printf 'file 755 root root %s %s\n' "$script_hash" "$added_script" > "$work/expected-added"
diff "$work/base-files" "$work/image-files" | sed -n 's/^> //p' > "$work/added" || true
diff "$work/base-files" "$work/image-files" | sed -n 's/^< //p' > "$work/removed" || true
[ ! -s "$work/removed" ] || { cat "$work/removed" >&2; fail "files changed or removed compared with 27.1.5-1"; }
diff -u "$work/expected-added" "$work/added" \
    || fail "the only added path must be $added_script with the checked-in contents"
echo "$(wc -l < "$work/base-files") paths identical; added $added_script"

echo "== PHP modules"
diff -u <(docker run --rm --network none --entrypoint php-fpm8.1 "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint php-fpm8.1 "$image_ref" -m) \
    || fail "php-fpm8.1 module list differs from 27.1.5-1"
diff -u <(docker run --rm --network none --entrypoint php8.1 "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint php8.1 "$image_ref" -m) \
    || fail "php8.1 module list differs from 27.1.5-1"
echo "CLI and FPM module lists identical"

echo "== FPM and nginx configuration"
docker run --rm --network none --entrypoint php-fpm8.1 "$image_ref" -t \
    || fail "php-fpm8.1 configuration test failed"
docker run --rm --network none --entrypoint nginx "$image_ref" -t \
    || fail "nginx configuration test failed"

echo "== Restart with a fresh /run"
# Run my_init's real startup sequence with only the runtime-directory script
# (the installer needs Appbox's environment and network), on a fresh tmpfs
# /run like an Appbox container restart, then check the services can start.
restart_case() {
    docker run --rm --network none --tmpfs /run:rw,nosuid,nodev,mode=1777 \
        -v "$gate_dir/release:/release:ro" --entrypoint sh "$1" -c '
        set -eu
        mkdir -p /tmp/my_init.d.saved
        mv /etc/my_init.d/* /tmp/my_init.d.saved/
        if [ -f /tmp/my_init.d.saved/05_runtime_dirs.sh ]; then
            cp /tmp/my_init.d.saved/05_runtime_dirs.sh /etc/my_init.d/
        fi
        exec /sbin/my_init --skip-runit -- sh /release/run-dirs-check.sh
    '
}
restart_case "$image_ref" || fail "services cannot start after a restart with a fresh /run"
if restart_case "$base_ref" > "$work/base-restart" 2>&1; then
    cat "$work/base-restart" >&2
    fail "the restart check also passes on 27.1.5-1, so it does not detect the outage"
fi
echo "27.1.5-1 fails the same check as expected: $(grep -m1 'FAIL:' "$work/base-restart" || tail -n 1 "$work/base-restart")"

echo "== Registry tag must not exist"
"$gate_dir/release/registry-absent.sh" "$release_ref" \
    || fail "registry precondition for $release_ref not met"

if [ "$mode" = trial ]; then
    echo "TRIAL PASSED: $image_ref ($release_ref absent). Trial images are not pushed."
else
    echo "PASS: $release_ref (27.1.5-1 plus $added_script, restart regression verified, tag absent)"
fi
