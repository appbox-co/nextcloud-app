#!/usr/bin/env bash
# Release gate for repo.cylo.net/nextcloud:31.0.4-4, the released 31.0.4-3
# image with one correction in /etc/my_init.d/30_installer.sh: an existing
# installation whose index.php answers 500 no longer stalls the start.
#
# Usage: ./release-gate.sh repo.cylo.net/nextcloud:31.0.4-4   (release)
#        ./release-gate.sh local/nextcloud-trial:31.0.4-4     (trial)
#
# Release mode requires the image to have been built with the php8.3 minimum
# pinned in the Dockerfile (ARG PHP83_MIN_VERSION); trial mode accepts the
# minimum the trial image was built with. Both modes require every CVE id in
# release/required-fixes.txt in the php8.3-common changelog only in release
# mode, and the release tag to be absent from the registry. Trial images are
# never pushed.
#
# Against the 31.0.4-3 base digest it checks: one added layer, identical
# runtime configuration, identical packages, identical files apart from
# /etc/my_init.d/30_installer.sh (base must have the 31.0.4-3 installer, image
# must have this overlay's, and the difference must be exactly
# release/30_installer.sh.diff), identical CLI and FPM module lists,
# php-fpm8.3 -t, nginx -t, a multipart upload with the CLI server, and a PHP
# page plus multipart upload served through nginx and php-fpm8.3.
#
# It then runs release/recreate-regression.sh on Appbox-style host
# directories, three scenarios in parallel:
#   - lifecycle: fresh install; recreate (no upgrade, no repair); restart
#     (the every-start path runs no repair); maintenance mode left on by an
#     interrupted installer run is finished and turned off at the next start;
#     installed newer than the image; maintenance mode set by an administrator
#     survives a recreate and a restart; a restart finishes while index.php
#     answers 500 (31.0.4-3 waited forever there);
#   - upgrade: the database one patch behind the code is upgraded on recreate,
#     occ upgrade running before the repair, and maintenance mode ends off;
#     a database more than one major version behind is left unchanged (no
#     upgrade, no repair, no maintenance mode);
#   - update from 31.0.4-2: its container log holds the passwords (proving the
#     check detects the leak); after the update the new container's log holds
#     none, and Nextcloud is installed, up to date and out of maintenance.
# Every container started from the new image must log no password.
set -euo pipefail

release_ref=repo.cylo.net/nextcloud:31.0.4-4
trial_ref=local/nextcloud-trial:31.0.4-4
# 31.0.4-3, the image this overlay is built on.
base_ref=repo.cylo.net/nextcloud@sha256:2532811b97ef36cb7b92df6678c929f0a35819807ff56593b1e879f213f9c9de
# 31.0.4-2, the version most installations run before this update; its
# installer prints passwords into the container log.
previous_ref=repo.cylo.net/nextcloud@sha256:2fbf3f58f6df25fed7f7842e149a7526fea7f1ebe1b388246967f4f09f38a52b
installer=/etc/my_init.d/30_installer.sh
base_installer_sha256=3246c9e0a0172e7840c3ead27b35b00bb921844fc91b201f845c2db23700efd1
php_source=php8.3
php_cli=php8.3
php_fpm=php-fpm8.3
min_arg=PHP83_MIN_VERSION
compared_paths="/etc/php /etc/my_init.d /app-sources /etc/nginx /etc/service /etc/container_environment /etc/cron.d /etc/ssh/sshd_config /scripts /sbin/my_init"
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
recreate_test=$gate_dir/release/recreate-regression.sh
scenario_dirs=()
cleanup() {
    local dir
    for dir in "${scenario_dirs[@]}"; do
        [ ! -d "$dir" ] || "$recreate_test" "$dir" cleanup "$base_ref" \
            || echo "Remove $dir and its container by hand" >&2
    done
    rm -rf "$work"
}
trap cleanup EXIT

in_image() {
    local ref=$1
    shift
    docker run --rm --network none -v "$gate_dir/release:/release:ro" --entrypoint sh "$ref" "$@"
}

echo "== Image and base ($mode)"
docker image inspect "$base_ref" >/dev/null 2>&1 || docker pull -q "$base_ref" >/dev/null
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")
[ "$platform" = linux/amd64 ] || fail "wrong image platform: $platform"

config_filter='{Env, Cmd, Entrypoint, User, WorkingDir, ExposedPorts, Volumes, StopSignal, Shell, Healthcheck}'
diff -u <(docker image inspect --format '{{json .Config}}' "$base_ref" | jq -S "$config_filter") \
    <(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -S "$config_filter") \
    || fail "runtime configuration differs from the deployed base"
docker image inspect --format '{{json .Config.Env}}' "$image_ref" | jq -r '.[]' | grep '^NEXTCLOUD_VER='

docker image inspect --format '{{json .RootFS.Layers}}' "$base_ref" | jq -r '.[]' > "$work/base-layers"
docker image inspect --format '{{json .RootFS.Layers}}' "$image_ref" | jq -r '.[]' > "$work/image-layers"
[ "$(wc -l < "$work/image-layers")" -eq "$(( $(wc -l < "$work/base-layers") + 1 ))" ] \
    || fail "expected exactly one layer on top of the deployed base"
head -n "$(wc -l < "$work/base-layers")" "$work/image-layers" | cmp -s - "$work/base-layers" \
    || fail "image is not built on the deployed base layers"
echo "one layer on top of $base_ref"

echo "== $php_source packages"
pinned_min=$(sed -n "s/^ARG $min_arg=\\([A-Za-z0-9.+~-]*\\)\$/\\1/p" "$gate_dir/Dockerfile")
[ -n "$pinned_min" ] && [ "$(printf '%s\n' "$pinned_min" | wc -l)" -eq 1 ] \
    || fail "could not read one ARG $min_arg from $gate_dir/Dockerfile"
built_min=$(docker image inspect --format '{{index .Config.Labels "net.cylo.php-min-version"}}' "$image_ref")
[ -n "$built_min" ] || fail "image has no net.cylo.php-min-version label"
if [ "$mode" = release ]; then
    [ "$built_min" = "$pinned_min" ] \
        || fail "image was built with $min_arg=$built_min; the pinned release minimum is $pinned_min"
    check_min=$pinned_min
else
    check_min=$built_min
fi
in_image "$image_ref" /release/check-php-packages.sh "$php_source" "$check_min" \
    || fail "$php_source packages do not satisfy the minimum $check_min"
if [ "$mode" = trial ]; then
    if in_image "$image_ref" /release/check-php-packages.sh "$php_source" "$pinned_min" >/dev/null 2>&1; then
        echo "TRIAL: this image already satisfies the release pin $pinned_min"
    else
        echo "TRIAL: this image does not satisfy the release pin $pinned_min, so release mode would refuse it"
    fi
fi

echo "== Required fixes in the $php_source changelog"
fixes=$(sed -e 's/#.*//' "$gate_dir/release/required-fixes.txt" | grep -o 'CVE-[0-9]\{4\}-[0-9]\{4,\}' | sort -u) || true
# shellcheck disable=SC2086
in_image "$image_ref" /release/changelog-fixes.sh "$php_source" $fixes > "$work/fixes" \
    || fail "cannot read the $php_source changelog"
cat "$work/fixes"
[ "$(sed -n 's/^installed //p' "$work/fixes")" = "$(sed -n 's/^changelog //p' "$work/fixes")" ] \
    || fail "the $php_source-common changelog does not match the installed version"
missing=$(sed -n 's/^absent //p' "$work/fixes" | tr '\n' ' ')
if [ "$mode" = release ]; then
    [ -n "$fixes" ] || fail "release/required-fixes.txt lists no CVE ids; add the ids from the Ubuntu security notice"
    [ -z "$missing" ] || fail "the $php_source changelog does not mention: $missing"
elif [ -z "$fixes" ]; then
    echo "TRIAL: release/required-fixes.txt lists no CVE ids, so release mode would refuse"
elif [ -n "$missing" ]; then
    echo "TRIAL: not in this image (expected before Ubuntu publishes the fix): $missing"
fi

echo "== Other packages unchanged"
dpkg_list='dpkg-query -W -f="\${db:Status-Abbrev}|\${binary:Package}|\${source:Package}|\${Version}\n"'
in_image "$base_ref" -c "$dpkg_list" | sort > "$work/base-dpkg"
in_image "$image_ref" -c "$dpkg_list" | sort > "$work/image-dpkg"
diff -u <(awk -F'|' '{print $1 "|" $2}' "$work/base-dpkg") <(awk -F'|' '{print $1 "|" $2}' "$work/image-dpkg") \
    || fail "installed package set differs from the deployed base"
diff -u <(awk -F'|' -v src="$php_source" '$3 != src' "$work/base-dpkg") \
    <(awk -F'|' -v src="$php_source" '$3 != src' "$work/image-dpkg") \
    || fail "packages not built from $php_source changed"
changed_php=$(awk -F'|' -v src="$php_source" 'NR == FNR { if ($3 == src) old[$2] = $4; next }
    $3 == src && old[$2] != $4 { n++ } END { print n + 0 }' "$work/base-dpkg" "$work/image-dpkg")
echo "$(wc -l < "$work/image-dpkg") packages; $changed_php $php_source packages upgraded, nothing else changed"

echo "== Sources and configuration unchanged; only $installer replaced"
# shellcheck disable=SC2086
in_image "$base_ref" /release/file-manifest.sh $compared_paths > "$work/base-files"
# shellcheck disable=SC2086
in_image "$image_ref" /release/file-manifest.sh $compared_paths > "$work/image-files"
diff -u <(grep -v " $installer\$" "$work/base-files") <(grep -v " $installer\$" "$work/image-files") \
    || fail "files under $compared_paths other than $installer differ from the base"
base_installer_line=$(grep " $installer\$" "$work/base-files") || fail "the base has no $installer"
image_installer_line=$(grep " $installer\$" "$work/image-files") || fail "the image has no $installer"
overlay_installer_sha256=$(sha256sum < "$gate_dir/30_installer.sh" | cut -c1-64)
[ "$base_installer_line" = "file 755 root root $base_installer_sha256 $installer" ] \
    || fail "the base $installer is not the one the fix was written against: $base_installer_line"
[ "$image_installer_line" = "file 755 root root $overlay_installer_sha256 $installer" ] \
    || fail "the image $installer is not this overlay's 30_installer.sh: $image_installer_line"
docker run --rm --network none --entrypoint cat "$base_ref" "$installer" > "$work/base-installer"
docker run --rm --network none --entrypoint cat "$image_ref" "$installer" > "$work/image-installer"
diff -u --label "base$installer" --label "image$installer" "$work/base-installer" "$work/image-installer" \
    > "$work/installer.diff" || true
cmp -s "$work/installer.diff" "$gate_dir/release/30_installer.sh.diff" \
    || { diff -u "$gate_dir/release/30_installer.sh.diff" "$work/installer.diff" || true; \
         fail "the installer change is not exactly release/30_installer.sh.diff"; }
echo "$(( $(wc -l < "$work/image-files") - 1 )) paths identical; $installer replaced (sha256 $overlay_installer_sha256), change as in release/30_installer.sh.diff"

echo "== PHP modules"
diff -u <(docker run --rm --network none --entrypoint "$php_fpm" "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint "$php_fpm" "$image_ref" -m) \
    || fail "$php_fpm module list differs from the deployed base"
diff -u <(docker run --rm --network none --entrypoint "$php_cli" "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint "$php_cli" "$image_ref" -m) \
    || fail "$php_cli module list differs from the deployed base"
echo "CLI and FPM module lists identical"

echo "== FPM and nginx configuration"
docker run --rm --network none --entrypoint "$php_fpm" "$image_ref" -t \
    || fail "$php_fpm configuration test failed"
docker run --rm --network none --entrypoint nginx "$image_ref" -t \
    || fail "nginx configuration test failed"

echo "== Multipart upload"
in_image "$image_ref" /release/multipart-smoke.sh "$php_cli" \
    || fail "multipart upload smoke test failed"

echo "== PHP page and multipart upload through nginx and $php_fpm"
in_image "$image_ref" /release/fpm-smoke.sh "$php_fpm" \
    || fail "nginx and $php_fpm smoke test failed"

echo "== Update regression: installer lifecycle on Appbox host directories"
t=$recreate_test
life_dir=$(mktemp -d /dev/shm/nextcloud-recreate.XXXXXX)
scenario_dirs+=("$life_dir")
upgrade_dir=$(mktemp -d /dev/shm/nextcloud-recreate.XXXXXX)
scenario_dirs+=("$upgrade_dir")
previous_dir=$(mktemp -d /dev/shm/nextcloud-recreate.XXXXXX)
scenario_dirs+=("$previous_dir")
no_repair='log_lacks=^appbox-installer: running occ maintenance:repair'
no_upgrade='log_lacks=^appbox-installer: running occ upgrade'

scenario_lifecycle() {
    local d=$life_dir
    "$t" "$d" install "$image_ref" \
        && "$t" "$d" expect maintenance=false needs_upgrade=false mark=absent secrets=absent \
            'log_has=^appbox-installer: start sequence finished' \
        && "$t" "$d" recreate "$image_ref" \
        && "$t" "$d" expect maintenance=false needs_upgrade=false mark=absent secrets=absent \
            'log_has=^appbox-installer: Nextcloud is up to date' "$no_upgrade" "$no_repair" \
        && "$t" "$d" restart \
        && "$t" "$d" expect maintenance=false mark=absent secrets=absent "$no_upgrade" "$no_repair" \
        && "$t" "$d" index500 on \
        && "$t" "$d" restart \
        && "$t" "$d" expect maintenance=false mark=absent 'log_has=^appbox-installer: start sequence finished' "$no_upgrade" "$no_repair" \
        && "$t" "$d" index500 off \
        && "$t" "$d" maint installer \
        && "$t" "$d" restart \
        && "$t" "$d" expect maintenance=false mark=absent \
            'log_order=^appbox-installer: an earlier installer run did not finish,^appbox-installer: upgrade and repair finished' \
        && "$t" "$d" bump \
        && "$t" "$d" recreate "$image_ref" \
        && "$t" "$d" expect maintenance=false mark=absent "$no_repair" \
        && "$t" "$d" maint admin \
        && "$t" "$d" recreate "$image_ref" \
        && "$t" "$d" expect maintenance=true mark=absent "$no_upgrade" "$no_repair" \
        && "$t" "$d" restart \
        && "$t" "$d" expect maintenance=true mark=absent "$no_upgrade" "$no_repair"
}

scenario_upgrade() {
    local d=$upgrade_dir
    "$t" "$d" install "$image_ref" \
        && "$t" "$d" set-db-version 31.0.3.0 \
        && "$t" "$d" expect needs_upgrade=true maintenance=false \
        && "$t" "$d" recreate "$image_ref" \
        && "$t" "$d" expect maintenance=false needs_upgrade=false db_version=31.0.4.1 mark=absent secrets=absent \
            'log_order=^appbox-installer: running occ upgrade,^appbox-installer: running occ maintenance:repair' \
            'log_has=^appbox-installer: upgrade and repair finished' \
        && "$t" "$d" set-db-version 29.0.0.0 \
        && "$t" "$d" recreate "$image_ref" \
        && "$t" "$d" expect needs_upgrade=true maintenance=false db_version=29.0.0.0 mark=absent \
            'log_has=^appbox-installer: .*more than one major version behind' "$no_upgrade" "$no_repair" \
        && "$t" "$d" restart \
        && "$t" "$d" expect needs_upgrade=true maintenance=false db_version=29.0.0.0 "$no_upgrade" "$no_repair"
}

scenario_from_previous() {
    local d=$previous_dir
    docker image inspect "$previous_ref" >/dev/null 2>&1 || docker pull -q "$previous_ref" >/dev/null
    "$t" "$d" install "$previous_ref" \
        && "$t" "$d" expect secrets=present \
        && "$t" "$d" recreate "$image_ref" \
        && "$t" "$d" expect maintenance=false needs_upgrade=false mark=absent secrets=absent \
            'log_has=^appbox-installer: start sequence finished'
}

scenario_lifecycle > "$work/scenario-lifecycle.log" 2>&1 &
life_pid=$!
scenario_upgrade > "$work/scenario-upgrade.log" 2>&1 &
upgrade_pid=$!
scenario_from_previous > "$work/scenario-from-previous.log" 2>&1 &
previous_pid=$!
life_status=0
wait "$life_pid" || life_status=$?
upgrade_status=0
wait "$upgrade_pid" || upgrade_status=$?
previous_status=0
wait "$previous_pid" || previous_status=$?
for scenario in lifecycle upgrade from-previous; do
    echo "--- $scenario"
    cat "$work/scenario-$scenario.log"
done
[ "$life_status" -eq 0 ] \
    || fail "update regression: lifecycle scenario failed (exit $life_status)"
[ "$upgrade_status" -eq 0 ] \
    || fail "update regression: upgrade scenario failed (exit $upgrade_status)"
[ "$previous_status" -eq 0 ] \
    || fail "update regression: update from 31.0.4-2 failed (exit $previous_status)"
echo "update regression passed: fresh install, recreate and restart without repair, restart with index.php answering 500, interrupted installer maintenance finished, administrator maintenance kept, upgrade before repair, multi-major database left unchanged, 31.0.4-2 password leak detected and absent after the update"

echo "== Registry tag must not exist"
"$gate_dir/release/registry-absent.sh" "$release_ref" \
    || fail "registry precondition for $release_ref not met"

if [ "$mode" = trial ]; then
    echo "TRIAL PASSED: $image_ref ($php_source at the trial minimum $check_min; $release_ref absent). Not releasable: built without the release pin $pinned_min."
else
    echo "PASS: $release_ref ($php_source >= $check_min, only the installer changed, installer lifecycle regression, no passwords in logs, tag absent)"
fi
