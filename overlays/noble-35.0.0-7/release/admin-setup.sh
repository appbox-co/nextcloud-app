#!/usr/bin/env bash
# Usage (on the build host): admin-setup.sh <work dir> rejected <image>
#                            admin-setup.sh <work dir> recover <old image> <image>
#
# Tests the first-time admin setup of 30_installer.sh on host directories
# mounted as Appbox mounts them for app 221 (the layout of
# release/recreate-regression.sh, whose cleanup phase removes them). The admin
# password always contains ", \, ', $, a backtick, a space and "&amp;" (which
# Nextcloud's setup would otherwise HTML-decode).
#
#   rejected  Nextcloud's setup is made to refuse the configuration (empty
#             admin login). The installer must stop the container with a
#             non-zero status, without reaching the installed callback (the
#             container runs with APP_APEX_CALLBACK=true and api.cylo.io
#             pointing at an unroutable address, so an attempted callback would
#             keep it running) and without /etc/app_installer_completed; the
#             pending autoconfig.php stays. Started again, it must run the
#             setup again and stop again. Recreated with a valid admin login on
#             the same directories, it must finish the setup: Nextcloud
#             installed, only that admin user, the password accepted and a
#             wrong one refused, autoconfig.php removed, /apps and /storage
#             mounted.
#   recover   <old image> (35.0.0-6) is installed with the password; its
#             unescaped autoconfig.php leaves Nextcloud answering 500 and not
#             installed. The container is then recreated from <image> on the
#             same directories, which must run the setup again and finish it
#             as above.
#
# Exit status: 0 passed, 1 failed. Only test credentials generated here are
# used, and the password is never printed.
set -euo pipefail

usage() {
    echo "usage: $0 <work dir> rejected <image> | $0 <work dir> recover <old image> <image>" >&2
    exit 1
}

[ "$#" -ge 3 ] || usage
work=$1
phase=$2
case "$phase" in
    rejected) [ "$#" -eq 3 ] || usage; image=$3; old_image= ;;
    recover) [ "$#" -eq 4 ] || usage; old_image=$3; image=$4 ;;
    *) usage ;;
esac
case "$work" in
    /dev/shm/nextcloud-recreate.??????) ;;
    *) echo "work directory must be a mktemp -d /dev/shm/nextcloud-recreate.XXXXXX directory" >&2; exit 1 ;;
esac
[ -d "$work" ] || { echo "missing work directory $work" >&2; exit 1; }

umask 077
vol=$work/vol
autoconfig=$vol/public_html/config/autoconfig.php
admin_user=gateadmin
# Generated per run; the fixed part holds the characters under test.
admin_pass="Gate'\"\\\$HOME \`id\`&amp;<x>\\$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

say() {
    echo "[admin-setup $(basename "$work") $phase] $*"
}

[ ! -e "$vol" ] || fail "$vol already exists"
mkdir -p "$vol"/config "$vol"/logs "$vol"/mysql_data "$vol"/public_html "$vol"/user_data \
    "$vol"/appbox_data/apps "$vol"/appbox_data/storage "$vol"/ssl
chmod 755 "$vol" "$vol"/*
name="nextcloud-setup-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$name" > "$work/name"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$vol/ssl/key.pem" -out "$vol/ssl/cert.pem" \
    -subj "/CN=$name" -days 1 >/dev/null 2>&1
chmod 644 "$vol/ssl/cert.pem" "$vol/ssl/key.pem"

# start_container <image> <admin login> <APP_APEX_CALLBACK>
start_container() {
    docker run -d --name "$name" --hostname "$name" --init \
        --label "net.cylo.recreate-regression=$(basename "$work")" \
        --memory 6g --memory-swap 6g \
        --add-host api.cylo.io:192.0.2.1 \
        -e "HOSTNAME=$name" -e "APP_APEX_CALLBACK=$3" -e INSTANCE_ID=0 \
        -e PUID=1000 -e PGID=1000 \
        -e "ADMIN_USER=$2" -e "ADMIN_PASS=$admin_pass" \
        -v "$vol/config:/home/appbox/config" \
        -v "$vol/ssl/cert.pem:/ssl/cert.pem:ro" \
        -v "$vol/ssl/key.pem:/ssl/key.pem:ro" \
        -v "$vol/logs:/home/appbox/logs" \
        -v "$vol/mysql_data:/home/appbox/mysql" \
        -v "$vol/public_html:/home/appbox/public_html" \
        -v "$vol/user_data/:/storage/" \
        --mount "type=bind,source=$vol/appbox_data,target=/APPBOX_DATA" \
        "$1" >/dev/null
    say "started $name from $1 (admin login '${2}', callback $3)"
}

show_logs() {
    echo "----- last installer output of $name"
    docker logs --tail 60 "$name" 2>&1 | sed 's/^/    /' || true
    echo "-----"
}

occ() {
    docker exec "$name" su -s /bin/sh -c "cd /home/appbox/public_html && php occ $*" appbox
}

# The password must never reach the container log.
check_log_has_no_password() {
    if docker logs "$name" 2>&1 | grep -qF -- "$admin_pass"; then
        fail "the admin password appears in the container log"
    fi
}

# Waits for the container to stop on its own; fails if it still runs after
# 20 minutes or exits with status 0.
wait_for_stop() {
    local attempt status
    for attempt in $(seq 1 240); do
        if [ "$(docker inspect --format '{{.State.Running}}' "$name")" != true ]; then
            status=$(docker inspect --format '{{.State.ExitCode}}' "$name")
            [ "$status" -ne 0 ] || { show_logs; fail "the container exited with status 0 after a rejected setup"; }
            say "the container stopped with status $status"
            return 0
        fi
        sleep 5
    done
    show_logs
    fail "the container still runs 20 minutes after a rejected setup"
}

check_failed_closed() {
    local starts=$1 count
    if docker logs "$name" 2>&1 | grep -q 'Finishing Install'; then
        show_logs
        fail "the installer reached the installed callback after a rejected setup"
    fi
    if docker cp "$name:/etc/app_installer_completed" - >/dev/null 2>&1; then
        fail "/etc/app_installer_completed exists after a rejected setup"
    fi
    count=$(docker logs "$name" 2>&1 | grep -c 'appbox-installer: the first-time setup did not finish' || true)
    [ "$count" -eq "$starts" ] || { show_logs; fail "expected $starts rejected setup runs in the log, found $count"; }
    docker logs "$name" 2>&1 | grep -q 'but Nextcloud is not installed (occ: not-installed)' \
        || { show_logs; fail "the log does not show Nextcloud reporting itself not installed"; }
    [ -f "$autoconfig" ] || fail "autoconfig.php was removed after a rejected setup; the next start could not run it again"
    [ "$(stat -c '%a' "$autoconfig")" = 640 ] || fail "autoconfig.php has mode $(stat -c '%a' "$autoconfig"), expected 640"
    check_log_has_no_password
}

# 0: installer finished; 1: the container stopped; 2: timed out (30 minutes).
wait_for_installer() {
    local attempt
    for attempt in $(seq 1 360); do
        if [ "$(docker inspect --format '{{.State.Running}}' "$name")" != true ]; then
            say "container stopped before the installer finished"
            return 1
        fi
        if docker exec "$name" test -f /etc/app_installer_completed; then
            return 0
        fi
        sleep 5
    done
    say "installer did not finish within 30 minutes"
    return 2
}

# HTTP status of an OCS request as <user> with the password from the
# container's own ADMIN_PASS (plus a suffix to make it wrong).
login_status() {
    docker exec -e "GATE_LOGIN=$1" -e "GATE_SUFFIX=$2" "$name" sh -c \
        'curl -s -o /dev/null -w "%{http_code}" --max-time 60 -u "$GATE_LOGIN:$ADMIN_PASS$GATE_SUFFIX" \
            -H "OCS-APIRequest: true" "http://localhost/ocs/v2.php/cloud/user?format=json"'
}

check_installed() {
    local attempt users status
    [ "$(docker exec "$name" printenv ADMIN_PASS)" = "$admin_pass" ] \
        || fail "the container's ADMIN_PASS is not the test password"
    for attempt in $(seq 1 60); do
        if occ status --output=json 2>/dev/null | jq -e '.installed == true' >/dev/null 2>&1; then
            break
        fi
        [ "$attempt" -lt 60 ] || { show_logs; fail "Nextcloud does not report installed:true"; }
        sleep 5
    done
    users=$(occ user:list --output=json | jq -c 'keys')
    [ "$users" = "[\"$admin_user\"]" ] || fail "users after the setup are $users, expected [\"$admin_user\"]"
    status=$(login_status "$admin_user" "")
    [ "$status" = 200 ] || fail "the admin login with the chosen password returned HTTP $status"
    status=$(login_status "$admin_user" "x")
    [ "$status" = 401 ] || fail "the admin login with a wrong password returned HTTP $status, expected 401"
    [ ! -e "$autoconfig" ] || fail "autoconfig.php is still there after the setup finished"
    [ "$(occ files_external:list --output=json | jq -r '[.[].mount_point] | sort | join(" ")')" = "/apps /storage" ] \
        || fail "the external storage mounts are not /apps and /storage"
    docker exec "$name" perl -e 'my $h = (getpwnam("appbox"))[1]; exit(crypt($ENV{ADMIN_PASS}, $h) eq $h ? 0 : 1)' \
        || fail "the appbox account password is not the chosen password"
    check_log_has_no_password
    say "Nextcloud installed: only $admin_user, the chosen password works and a wrong one is refused, autoconfig.php removed, mounts /apps /storage, appbox password set"
}

finish_setup_with() {
    docker rm -f "$name" >/dev/null
    start_container "$1" "$admin_user" false
    if ! wait_for_installer; then
        show_logs
        fail "the setup did not finish after the container was recreated from $1"
    fi
    docker logs "$name" 2>&1 | grep -q 'appbox-installer: an earlier first-time setup did not finish; running the setup again' \
        || { show_logs; fail "the recreated container did not run the unfinished first-time setup again"; }
    check_installed
}

case "$phase" in
rejected)
    start_container "$image" "" true
    wait_for_stop
    check_failed_closed 1
    say "rejected setup: stopped with no installed callback, no /etc/app_installer_completed, autoconfig.php kept for the next start"
    docker start "$name" >/dev/null
    wait_for_stop
    check_failed_closed 2
    docker logs "$name" 2>&1 | grep -q 'appbox-installer: an earlier first-time setup did not finish; running the setup again' \
        || { show_logs; fail "the second start did not run the unfinished first-time setup again"; }
    say "second start: ran the setup again and stopped again, still no callback or marker"
    finish_setup_with "$image"
    ;;
recover)
    start_container "$old_image" "$admin_user" false
    state=
    for attempt in $(seq 1 120); do
        code=$(docker exec "$name" curl -s -o /dev/null -w '%{http_code}' --max-time 30 http://localhost/index.php || true)
        installed=$(docker exec "$name" curl -s --max-time 30 http://localhost/status.php 2>/dev/null | jq -r '.installed' 2>/dev/null || true)
        if [ "$code" = 500 ] && [ "$installed" = false ] && [ -f "$autoconfig" ]; then
            state=broken
            break
        fi
        if [ "$installed" = true ]; then
            state=installed
            break
        fi
        sleep 5
    done
    [ "$state" = broken ] || { show_logs; fail "$old_image did not leave the expected broken state (index.php $code, installed $installed)"; }
    say "$old_image with this password: index.php answers 500 and Nextcloud is not installed (the 35.0.0-6 fault)"
    docker stop -t 60 "$name" >/dev/null
    finish_setup_with "$image"
    ;;
esac
