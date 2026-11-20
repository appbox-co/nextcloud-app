#!/usr/bin/env bash
# Release gate for repo.cylo.net/nextcloud:35.0.0-7, the released 35.0.0-6
# image with only /etc/my_init.d/30_installer.sh replaced (autoconfig.php
# written with var_export, readiness from the HTTP status and occ, fail
# closed). Adapted from the 35.0.0-6 gate.
#
# Usage: ./release-gate.sh repo.cylo.net/nextcloud:35.0.0-7   (release)
#        ./release-gate.sh local/nextcloud-trial:35.0.0-7     (trial)
#
# Both modes run every test and require the release tag to be absent from the
# registry. Trial images are never pushed.
#
# Against the 35.0.0-6 base it checks:
#   - one added layer and identical runtime configuration;
#   - identical packages, PHP module lists, and file manifests of the compared
#     paths except /etc/my_init.d/30_installer.sh (release/file-changes.txt),
#     whose change is exactly release/30_installer.sh.diff;
#   - php-fpm8.4 -t and nginx -t.
# It then installs Nextcloud with an admin password containing ", \, ', $, a
# backtick, a space and "&amp;": the admin logs in with it, a wrong password is
# refused, the appbox account has it, it never appears in the log, and the
# installation passes the 35.0.0-6 fresh-install checks, setup checks and a
# restart. On host directories mounted as Appbox mounts them it runs:
#   - release/admin-setup.sh rejected: Nextcloud refuses the setup; the
#     installer stops without the installed callback or marker, runs the setup
#     again at the next start, and finishes it once recreated with a valid
#     login;
#   - release/admin-setup.sh recover: 35.0.0-6 broken by the password, then
#     recreated from the new image, which finishes the setup;
#   - the update tests of the 35.0.0-6 gate (release/recreate-regression.sh
#     and release/mysql80-upgrade.sh), with 35.0.0-6 as the base: same image
#     recreated (also with the installed version newer than the image),
#     35.0.0-6, 35.0.0-5 and 35.0.0-4 updated to the new image (no setup check
#     worse for 35.0.0-6), and 31.0.4-2 with MySQL 8.0 upgraded to 35.0.2 in
#     place, stopped or killed, updated, and rolled back.
set -euo pipefail

release_ref=repo.cylo.net/nextcloud:35.0.0-7
trial_ref=local/nextcloud-trial:35.0.0-7
# 35.0.0-6, the image this overlay is built on and the current default.
base_ref=repo.cylo.net/nextcloud@sha256:0e6329de457ffa6e9997d2c6939817bfcbeb99157080bc88475b30b7d2370732
# 35.0.0-5 and 35.0.0-4, still used by running installations.
prev_ref=repo.cylo.net/nextcloud@sha256:7f6f0473f114bba2f5b8d0d57db25002722e0fa45f0389fb281e4b557bcde56a
deployed_ref=repo.cylo.net/nextcloud@sha256:5ffeef884defcb09fd788d04aa2fb6560d4d1c559e49d9691b5ccccab4e819e3
# 31.0.4-2, with Ubuntu's MySQL 8.0.
mysql80_ref=repo.cylo.net/nextcloud@sha256:2fbf3f58f6df25fed7f7842e149a7526fea7f1ebe1b388246967f4f09f38a52b
installer=/etc/my_init.d/30_installer.sh
compared_paths="/etc/my_init.d /app-sources /etc/nginx /etc/service /etc/runit /etc/container_environment /etc/cron.d /etc/ssh/sshd_config /scripts /sources /sbin/my_init /etc/apt /usr/share/keyrings /etc/nextcloud-redis.conf /etc/redis /etc/php /usr/bin/php8.4 /usr/sbin/php-fpm8.4"
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

test_name="nextcloud-release-gate-$$"
work=$(mktemp -d)
recreate_test=$gate_dir/release/recreate-regression.sh
mysql80_test=$gate_dir/release/mysql80-upgrade.sh
setup_test=$gate_dir/release/admin-setup.sh
scenario_dirs=()
cleanup() {
    docker rm -f "$test_name" >/dev/null 2>&1 || true
    local dir
    for dir in "${scenario_dirs[@]}"; do
        [ ! -d "$dir" ] || "$recreate_test" "$dir" cleanup "$base_ref" \
            || echo "Remove $dir and its container by hand" >&2
        docker ps -aq --filter "label=net.cylo.recreate-regression=$(basename "$dir")" \
            | xargs -r docker rm -f >/dev/null 2>&1 || true
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
for ref in "$base_ref" "$prev_ref" "$deployed_ref" "$mysql80_ref"; do
    docker image inspect "$ref" >/dev/null 2>&1 || docker pull -q "$ref" >/dev/null
done
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")
[ "$platform" = linux/amd64 ] || fail "wrong image platform: $platform"

config_filter='{Env, Cmd, Entrypoint, User, WorkingDir, ExposedPorts, Volumes, StopSignal, Shell, Healthcheck, Labels}'
diff -u <(docker image inspect --format '{{json .Config}}' "$base_ref" | jq -S "$config_filter") \
    <(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -S "$config_filter") \
    || fail "runtime configuration differs from 35.0.0-6"

docker image inspect --format '{{json .RootFS.Layers}}' "$base_ref" | jq -r '.[]' > "$work/base-layers"
docker image inspect --format '{{json .RootFS.Layers}}' "$image_ref" | jq -r '.[]' > "$work/image-layers"
[ "$(wc -l < "$work/image-layers")" -eq "$(( $(wc -l < "$work/base-layers") + 1 ))" ] \
    || fail "expected exactly one layer on top of 35.0.0-6"
head -n "$(wc -l < "$work/base-layers")" "$work/image-layers" | cmp -s - "$work/base-layers" \
    || fail "image is not built on the 35.0.0-6 layers"
echo "one layer on top of $base_ref, same runtime configuration"

echo "== Packages"
dpkg_list='dpkg-query -W -f="\${db:Status-Abbrev}|\${binary:Package}|\${Version}\n"'
diff -u <(in_image "$base_ref" -c "$dpkg_list" | sort) <(in_image "$image_ref" -c "$dpkg_list" | sort) \
    || fail "installed packages differ from 35.0.0-6"
echo "identical to 35.0.0-6"

echo "== Files against 35.0.0-6"
# shellcheck disable=SC2086
in_image "$base_ref" /release/file-manifest.sh $compared_paths > "$work/base-files"
# shellcheck disable=SC2086
in_image "$image_ref" /release/file-manifest.sh $compared_paths > "$work/image-files"
diff "$work/base-files" "$work/image-files" | grep '^[<>]' > "$work/file-changes" || true
diff -u "$gate_dir/release/file-changes.txt" "$work/file-changes" \
    || fail "file changes differ from release/file-changes.txt"
docker run --rm --network none --entrypoint cat "$base_ref" "$installer" > "$work/base-installer"
docker run --rm --network none --entrypoint cat "$image_ref" "$installer" > "$work/image-installer"
cmp -s "$work/image-installer" "$gate_dir/30_installer.sh" \
    || fail "$installer in the image is not overlays/noble-35.0.0-7/30_installer.sh"
diff -u --label "base$installer" --label "image$installer" "$work/base-installer" "$work/image-installer" \
    > "$work/installer.diff" || true
cmp -s "$work/installer.diff" "$gate_dir/release/30_installer.sh.diff" \
    || { diff -u "$gate_dir/release/30_installer.sh.diff" "$work/installer.diff" || true; \
         fail "the installer change is not exactly release/30_installer.sh.diff"; }
docker run --rm --network none --entrypoint bash "$image_ref" -n "$installer" \
    || fail "$installer has a syntax error"
echo "only $installer changed ($(grep -c '^[-+][^-+]' "$work/installer.diff") lines), as recorded"

echo "== PHP modules and configuration tests"
diff -u <(docker run --rm --network none --entrypoint php-fpm8.4 "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint php-fpm8.4 "$image_ref" -m) \
    || fail "php-fpm8.4 module list differs from 35.0.0-6"
diff -u <(docker run --rm --network none --entrypoint php8.4 "$base_ref" -m 2>/dev/null) \
    <(docker run --rm --network none --entrypoint php8.4 "$image_ref" -m 2>/dev/null) \
    || fail "php8.4 module list differs from 35.0.0-6"
docker run --rm --network none --entrypoint php-fpm8.4 "$image_ref" -t \
    || fail "php-fpm8.4 configuration test failed"
docker run --rm --network none --entrypoint nginx "$image_ref" -t \
    || fail "nginx configuration test failed"

echo "== Fresh install with a special-character admin password, and restart"
# Generated per run; the fixed part holds the characters under test.
gate_pass="Gate'\"\\\$HOME \`id\`&amp;<x>\\$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --name "$test_name" --hostname "$test_name" \
    --memory 4g --memory-swap 4g --tmpfs /ssl \
    -e "HOSTNAME=$test_name" -e APP_APEX_CALLBACK=false \
    -e "ADMIN_PASS=$gate_pass" \
    "$image_ref" >/dev/null

# Appbox supplies these files as a mount. Use a short-lived synthetic
# certificate in the disposable container so nginx can validate both sites.
docker exec "$test_name" openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /ssl/key.pem -out /ssl/cert.pem \
    -subj "/CN=$test_name" -days 1 >/dev/null 2>&1

show_logs() {
    echo "----- last installer output of $test_name"
    docker logs --tail 60 "$test_name" 2>&1 | sed 's/^/    /' || true
    echo "-----"
}

wait_for_install() {
    local attempt
    for attempt in $(seq 1 360); do
        if [ "$(docker inspect --format '{{.State.Running}}' "$test_name")" != true ]; then
            echo 'Fresh-install container exited before completion.' >&2
            show_logs
            return 1
        fi
        if docker exec "$test_name" test -f /etc/app_installer_completed; then
            return 0
        fi
        sleep 5
    done
    echo 'Fresh-install container did not complete within 30 minutes.' >&2
    show_logs
    return 1
}

wait_for_health() {
    local attempt
    for attempt in $(seq 1 60); do
        if docker exec "$test_name" /bin/bash -ec '
            curl -fsS --max-time 10 http://localhost/status.php | grep -q "35.0.0"
            su -s /bin/sh -c "cd /home/appbox/public_html && php occ status --output=json" appbox | grep -q "\"installed\":true"
            sv status redis | grep -q "^run: redis"
        ' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    echo 'Nextcloud did not become healthy within 5 minutes after installer completion.' >&2
    return 1
}

check_setup() {
    docker exec "$test_name" su -s /bin/sh -c "cd /home/appbox/public_html && php occ setupchecks --output=json" appbox \
        > "$work/setupchecks.json" || true
    local check severity
    for check in PhpOutdated SupportedDatabase FileLocking MemcacheConfigured PhpModules; do
        severity=$(jq -r --arg c "OCA\\Settings\\SetupChecks\\$check" \
            '[.[] | to_entries[] | select(.key == $c) | .value.severity][0] // "missing"' "$work/setupchecks.json")
        [ "$severity" = success ] || fail "setup check $check reports $severity"
    done
}

# HTTP status of an OCS request as admin with the container's own ADMIN_PASS
# (plus a suffix to make it wrong). The password is not on any command line.
login_status() {
    docker exec -e "GATE_SUFFIX=$1" "$test_name" sh -c \
        'curl -s -o /dev/null -w "%{http_code}" --max-time 60 -u "admin:$ADMIN_PASS$GATE_SUFFIX" \
            -H "OCS-APIRequest: true" "http://localhost/ocs/v2.php/cloud/user?format=json"'
}

check_password() {
    local status
    [ "$(docker exec "$test_name" printenv ADMIN_PASS)" = "$gate_pass" ] \
        || fail "the container's ADMIN_PASS is not the test password"
    status=$(login_status "")
    [ "$status" = 200 ] || fail "admin login with the special-character password returned HTTP $status"
    docker exec "$test_name" perl -e 'my $h = (getpwnam("appbox"))[1]; exit(crypt($ENV{ADMIN_PASS}, $h) eq $h ? 0 : 1)' \
        || fail "the appbox account password is not the admin password"
    if docker logs "$test_name" 2>&1 | grep -qF -- "$gate_pass"; then
        fail "the admin password appears in the container log"
    fi
}

wait_for_install || fail "fresh install did not finish"
wait_for_health || fail "fresh install is not healthy"
check_password
docker exec "$test_name" /bin/bash -ec '
    test ! -e /home/appbox/public_html/config/autoconfig.php
    [ "$(php -r "echo ini_get(\"memory_limit\");")" = 3G ]
    grep -q php-fpm8.4 /etc/service/phpfpm/run
    grep -q php8.4-fpm.sock /home/appbox/config/nginx/sites-enabled/nextcloud.conf
    php-fpm8.4 -tt --fpm-config /home/appbox/config/php-fpm/php-fpm.conf 2>&1 | grep -F "php_admin_value[memory_limit] = 3G" >/dev/null
    nginx -t -c /home/appbox/config/nginx/nginx.conf
    curl -fsS http://localhost/status.php | grep -q "35.0.0"
    [ "$(ps -o user= -C redis-server)" = appbox ]
    [ "$(stat -c "%U %a" /run/redis/redis.sock)" = "appbox 770" ]
    [ "$(redis-cli -s /run/redis/redis.sock config get port | tail -n 1)" = 0 ]
    if grep -q ":18EB " /proc/net/tcp /proc/net/tcp6; then exit 1; fi
    occ() { su -s /bin/sh -c "cd /home/appbox/public_html && php occ $*" appbox; }
    [ "$(occ config:system:get memcache.locking)" = "\\OC\\Memcache\\Redis" ]
    [ "$(occ config:system:get memcache.distributed)" = "\\OC\\Memcache\\Redis" ]
    [ "$(occ config:system:get memcache.local)" = "\\OC\\Memcache\\APCu" ]
    [ "$(occ config:system:get redis host)" = /run/redis/redis.sock ]
    [ "$(occ user:list --output=json | php -r "echo implode(\" \", array_keys(json_decode(stream_get_contents(STDIN), true)));")" = admin ]
    [ "$(occ files_external:list --output=json | php -r "echo implode(\" \", array_column(json_decode(stream_get_contents(STDIN), true), \"mount_point\"));")" = "/apps /storage" ]
' || fail "fresh install checks failed"
check_setup
echo "fresh install: admin logs in with the special-character password, appbox has it, not in the log; autoconfig.php removed; Redis and mounts as in 35.0.0-6; setup checks pass"

docker restart "$test_name" >/dev/null
# Docker clears tmpfs contents on restart; Appbox's real /ssl mount persists.
docker exec "$test_name" openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /ssl/key.pem -out /ssl/cert.pem \
    -subj "/CN=$test_name" -days 1 >/dev/null 2>&1
wait_for_install || fail "installer did not finish after the restart"
wait_for_health || fail "Nextcloud is not healthy after the restart"
check_password
status=$(login_status x)
[ "$status" = 401 ] || fail "admin login with a wrong password returned HTTP $status, expected 401"
check_setup
docker rm -f "$test_name" >/dev/null
echo "restart: healthy, the password still works and a wrong one is refused, setup checks pass"

echo "== Admin setup and update tests on Appbox host directories"
# Created in this shell (not in a $(...) subshell) so that cleanup sees them.
new_dir() {
    local dir
    dir=$(mktemp -d /dev/shm/nextcloud-recreate.XXXXXX)
    scenario_dirs+=("$dir")
    printf -v "$1" '%s' "$dir"
}
new_dir rejected_dir
new_dir recover_dir
new_dir same_dir
new_dir base_dir
new_dir prev_dir
new_dir deployed_dir
new_dir mysql80_dir
new_dir mysql80_kill_dir

setupchecks_of() {
    docker exec "$(cat "$1/name")" su -s /bin/sh -c "cd /home/appbox/public_html && php occ setupchecks --output=json" appbox || true
}

# Nextcloud refuses the setup: fail closed, retried, finished once valid.
scenario_rejected() {
    "$setup_test" "$rejected_dir" rejected "$image_ref"
}

# 35.0.0-6 broken by the password, recreated from the new image.
scenario_recover() {
    "$setup_test" "$recover_dir" recover "$base_ref" "$image_ref"
}

# A fresh install with the new image, recreated from the same image, then
# recreated again with the installed version reporting newer than the image.
scenario_same_image() {
    "$recreate_test" "$same_dir" install "$image_ref" \
        && "$recreate_test" "$same_dir" recreate "$image_ref" \
        && "$recreate_test" "$same_dir" bump \
        && "$recreate_test" "$same_dir" recreate "$image_ref"
}

# The production update: a 35.0.0-6 installation updated to the new image.
# No setup check may get worse; the PHP version, database version, file
# locking and memcache checks must pass. A further recreate must keep
# config.php byte-identical.
scenario_from_base() {
    "$recreate_test" "$base_dir" install "$base_ref" || return 1
    setupchecks_of "$base_dir" > "$base_dir/setupchecks-before.json"
    "$recreate_test" "$base_dir" recreate "$image_ref" || return 1
    setupchecks_of "$base_dir" > "$base_dir/setupchecks-after.json"
    jq -e 'type == "object" and length > 0' "$base_dir/setupchecks-before.json" >/dev/null \
        && jq -e 'type == "object" and length > 0' "$base_dir/setupchecks-after.json" >/dev/null \
        || { echo "FAIL: occ setupchecks did not return results" >&2; return 1; }
    jq -n --slurpfile before "$base_dir/setupchecks-before.json" --slurpfile after "$base_dir/setupchecks-after.json" -r '
        def rank: {"success": 0, "info": 1, "warning": 2, "error": 3}[.] // 3;
        def flat($x): [$x[0][] | to_entries[]] | map({(.key): .value.severity}) | add;
        flat($before) as $b | flat($after) as $a
        | ($a | to_entries[] | select(($b[.key] // "success" | rank) < (.value | rank)) | "WORSE \(.key): \($b[.key] // "absent") -> \(.value)"),
          (["PhpOutdated", "SupportedDatabase", "FileLocking", "MemcacheConfigured"][] as $c
            | "OCA\\Settings\\SetupChecks\\\($c)" as $k
            | if $a[$k] == "success" then "OK \($c): \($b[$k]) -> success" else "NOT PASSING \($c): \($a[$k])" end)' \
        | tee "$base_dir/setupchecks-compare.txt"
    if grep -qE '^(WORSE|NOT PASSING)' "$base_dir/setupchecks-compare.txt"; then
        echo "FAIL: setup checks after updating 35.0.0-6 to the new image" >&2
        return 1
    fi
    "$recreate_test" "$base_dir" recreate "$image_ref"
}

# 35.0.0-5 and 35.0.0-4 installations updated to the new image.
scenario_from_prev() {
    "$recreate_test" "$prev_dir" install "$prev_ref" \
        && "$recreate_test" "$prev_dir" recreate "$image_ref"
}
scenario_from_deployed() {
    "$recreate_test" "$deployed_dir" install "$deployed_ref" \
        && "$recreate_test" "$deployed_dir" recreate "$image_ref"
}

# 31.0.4-2 with MySQL 8.0, Nextcloud upgraded to 35.0.2 in place, stopped
# cleanly, updated to the new image, then taken back to 31.0.4-2.
scenario_mysql80() {
    "$recreate_test" "$mysql80_dir" install "$mysql80_ref" \
        && "$mysql80_test" "$mysql80_dir" nc-upgrade \
        && "$recreate_test" "$mysql80_dir" recreate "$image_ref" \
        && "$mysql80_test" "$mysql80_dir" check-84 "$image_ref" \
        && "$mysql80_test" "$mysql80_dir" rollback "$mysql80_ref"
}

# The same, with MySQL 8.0 killed instead of shut down before the update.
scenario_mysql80_kill() {
    "$recreate_test" "$mysql80_kill_dir" install "$mysql80_ref" \
        && "$mysql80_test" "$mysql80_kill_dir" nc-upgrade \
        && "$mysql80_test" "$mysql80_kill_dir" kill \
        && "$recreate_test" "$mysql80_kill_dir" recreate "$image_ref" \
        && "$mysql80_test" "$mysql80_kill_dir" check-84 "$image_ref"
}

# Each MySQL 8.4 server takes about 14,000 of the host's asynchronous I/O
# contexts (fs.aio-max-nr is 65536), so at most three scenarios run at a time
# and each scenario's container is stopped when it finishes.
scenarios="rejected recover same-image from-base from-prev from-deployed mysql80 mysql80-kill"
failed=
declare -A scenario_dir=([rejected]=$rejected_dir [recover]=$recover_dir [same-image]=$same_dir \
    [from-base]=$base_dir [from-prev]=$prev_dir [from-deployed]=$deployed_dir \
    [mysql80]=$mysql80_dir [mysql80-kill]=$mysql80_kill_dir)
run_batch() {
    local scenario status
    declare -A scenario_pid
    for scenario in "$@"; do
        "scenario_${scenario//-/_}" > "$work/scenario-$scenario.log" 2>&1 &
        scenario_pid[$scenario]=$!
    done
    for scenario in "$@"; do
        status=0
        wait "${scenario_pid[$scenario]}" || status=$?
        echo "--- $scenario (exit $status)"
        grep -vE '^ *- |^[[:space:]]*$|^ +[0-9]+ \[' "$work/scenario-$scenario.log" | tail -n 60
        [ "$status" -eq 0 ] || failed="$failed $scenario"
        # A finished scenario's MySQL must not hold I/O contexts the next
        # batch needs.
        docker ps -q --filter "label=net.cylo.recreate-regression=$(basename "${scenario_dir[$scenario]}")" \
            | xargs -r docker stop -t 60 >/dev/null || true
    done
}
run_batch rejected recover same-image
run_batch from-base from-prev from-deployed
run_batch mysql80 mysql80-kill
[ -z "$failed" ] || fail "tests failed:$failed"
echo "admin setup and update tests passed: $scenarios"

echo "== Registry tag must not exist"
"$gate_dir/release/registry-absent.sh" "$release_ref" \
    || fail "registry precondition for $release_ref not met"

if [ "$mode" = trial ]; then
    echo "TRIAL PASSED: $image_ref (only the installer changed; special-character password, rejected setup, recovery from 35.0.0-6, update tests; $release_ref absent)."
else
    echo "PASS: $release_ref (only the installer changed; special-character password, rejected setup, recovery from 35.0.0-6, restart, setup checks, update tests including MySQL 8.0, tag absent)"
fi
