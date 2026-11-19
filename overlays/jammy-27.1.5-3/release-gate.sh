#!/usr/bin/env bash
# Release gate for repo.cylo.net/nextcloud:27.1.5-3: repo.cylo.net/nextcloud:27.1.5-2
# with /etc/my_init.d/30_installer.sh no longer running under set -x (which
# printed autoconfig.php, with the admin and database passwords, into the
# container log).
#
# Usage: ./release-gate.sh repo.cylo.net/nextcloud:27.1.5-3   (release)
#        ./release-gate.sh local/nextcloud-trial:27.1.5-3     (trial)
#
# Against the 27.1.5-2 base digest it checks: one added layer, identical
# runtime configuration and labels, identical packages, identical files under
# the compared paths apart from the installer, whose change must be exactly
# release/30_installer.sh.diff, no shell tracing in any /etc/my_init.d script,
# identical CLI and FPM module lists, php-fpm8.1 -t and nginx -t, and the
# 27.1.5-2 restart check (services start after a restart with a fresh /run).
# Both modes require the release tag to be absent from the registry; trial
# images are never pushed.
set -euo pipefail

release_ref=repo.cylo.net/nextcloud:27.1.5-3
trial_ref=local/nextcloud-trial:27.1.5-3
base_ref=repo.cylo.net/nextcloud@sha256:8b47040592cb24bcee764025bdff0674d15ed300c11c7e91a81fbe462092f3a8
added_layers=1
installer=/etc/my_init.d/30_installer.sh
base_installer_sha256=4ff6ed5a04c0e653c02774b0ccea54a59db1bb60bc56e9d4abe2c819197aa7d7
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
    || fail "runtime configuration differs from 27.1.5-2"

docker image inspect --format '{{json .RootFS.Layers}}' "$base_ref" | jq -r '.[]' > "$work/base-layers"
docker image inspect --format '{{json .RootFS.Layers}}' "$image_ref" | jq -r '.[]' > "$work/image-layers"
[ "$(wc -l < "$work/image-layers")" -eq "$(( $(wc -l < "$work/base-layers") + added_layers ))" ] \
    || fail "expected exactly $added_layers layer on top of 27.1.5-2"
head -n "$(wc -l < "$work/base-layers")" "$work/image-layers" | cmp -s - "$work/base-layers" \
    || fail "image is not built on the 27.1.5-2 layers"
echo "$added_layers layer on top of $base_ref"

echo "== Packages unchanged"
dpkg_list='dpkg-query -W -f="\${db:Status-Abbrev}|\${binary:Package}|\${source:Package}|\${Version}\n"'
diff -u <(in_image "$base_ref" -c "$dpkg_list" | sort) <(in_image "$image_ref" -c "$dpkg_list" | sort) \
    || fail "installed packages differ from 27.1.5-2"
echo "packages identical"

echo "== Files unchanged apart from $installer"
# shellcheck disable=SC2086
in_image "$base_ref" /release/file-manifest.sh $compared_paths > "$work/base-files"
# shellcheck disable=SC2086
in_image "$image_ref" /release/file-manifest.sh $compared_paths > "$work/image-files"
diff -u <(grep -v " $installer\$" "$work/base-files") <(grep -v " $installer\$" "$work/image-files") \
    || fail "files under $compared_paths other than $installer differ from 27.1.5-2"
overlay_installer_sha256=$(sha256sum < "$gate_dir/30_installer.sh" | cut -c1-64)
[ "$(grep " $installer\$" "$work/base-files")" = "file 755 root root $base_installer_sha256 $installer" ] \
    || fail "the base $installer is not the one the change was written against"
[ "$(grep " $installer\$" "$work/image-files")" = "file 755 root root $overlay_installer_sha256 $installer" ] \
    || fail "the image $installer is not this overlay's 30_installer.sh"
docker run --rm --network none --entrypoint cat "$base_ref" "$installer" > "$work/base-installer"
docker run --rm --network none --entrypoint cat "$image_ref" "$installer" > "$work/image-installer"
diff -u --label "base$installer" --label "image$installer" "$work/base-installer" "$work/image-installer" \
    > "$work/installer.diff" || true
cmp -s "$work/installer.diff" "$gate_dir/release/30_installer.sh.diff" \
    || { diff -u "$gate_dir/release/30_installer.sh.diff" "$work/installer.diff" || true; \
         fail "the installer change is not exactly release/30_installer.sh.diff"; }
echo "$(( $(wc -l < "$work/image-files") - 1 )) paths identical; $installer replaced as in release/30_installer.sh.diff"

echo "== No shell tracing in the startup scripts"
traced=$(in_image "$image_ref" -c 'grep -lE "^[[:space:]]*set[[:space:]]+(-[a-wyzA-Z]*x|-o[[:space:]]+xtrace)" /etc/my_init.d/* || true')
[ -z "$traced" ] || fail "startup scripts with shell tracing (they print secrets into the container log): $traced"
in_image "$base_ref" -c 'grep -qE "^[[:space:]]*set[[:space:]]+-[a-wyzA-Z]*x" /etc/my_init.d/30_installer.sh' \
    || fail "the tracing check does not detect set -x in the 27.1.5-2 installer"
echo "no /etc/my_init.d script enables shell tracing (the 27.1.5-2 installer does, as expected)"

echo "== PHP modules"
diff -u <(docker run --rm --network none --entrypoint php-fpm8.1 "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint php-fpm8.1 "$image_ref" -m) \
    || fail "php-fpm8.1 module list differs from 27.1.5-2"
diff -u <(docker run --rm --network none --entrypoint php8.1 "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint php8.1 "$image_ref" -m) \
    || fail "php8.1 module list differs from 27.1.5-2"
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
echo "services start after a restart with a fresh /run"

echo "== Registry tag must not exist"
"$gate_dir/release/registry-absent.sh" "$release_ref" \
    || fail "registry precondition for $release_ref not met"

if [ "$mode" = trial ]; then
    echo "TRIAL PASSED: $image_ref ($release_ref absent). Trial images are not pushed."
else
    echo "PASS: $release_ref (27.1.5-2 with the installer's set -x removed, no tracing, restart check, tag absent)"
fi
