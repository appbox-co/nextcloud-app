#!/usr/bin/env bash
# Usage (on the build host): recreate-regression.sh <work dir> <phase> [<image>]
#
# Reproduces an Appbox update of an installed Nextcloud: the container is
# removed and created again with the same host directories mounted where
# Appbox mounts them for app 221 (config, logs, mysql_data, public_html,
# user_data, the /APPBOX_DATA bind and the two /ssl files). The new
# container has no /etc/app_installer_completed, so 30_installer.sh runs
# again against the existing installation.
#
# Phases, run in this order against one work directory:
#   install <image>   fresh install on empty directories; records a baseline
#                     (config.php, status, users, external storage mounts)
#   recreate <image>  stops and removes the container, creates it again from
#                     <image> and compares the installation with the baseline
#   broken-state      after a recreate that lost the installation: checks that
#                     logs/config.php still holds the saved configuration and
#                     that public_html/config/config.php is the empty or
#                     not-installed file Nextcloud leaves behind; the next
#                     recreate must then set that file aside, not move it
#                     over the saved configuration
#   bump              makes the installed Nextcloud report a newer patch
#                     version than the image (installed > image version)
#   cleanup <image>   removes the container and the work directory; <image>
#                     is only used to delete root-owned files
#   restart           restarts the container (no recreate: the installer's
#                     every-start path runs) and waits for the 31.0.4-3
#                     installer's "start sequence finished" line
#   maint admin|installer
#                     turns maintenance mode on, as an administrator would
#                     (admin), or as an interrupted installer run leaves it
#                     (installer: also writes the installer's marker in logs/)
#   index500 on|off   makes index.php answer HTTP 500 (on) like an
#                     installation whose code is several major versions
#                     ahead of its database, or restores it (off)
#   perm-break        gives /storage/gate-wrong-perm (a new file) mode 0600 and
#                     owner root:root, for "expect perm_fixed" after a recreate
#   set-db-version <version>
#                     sets config.php 'version' (the version the database is
#                     at) below the code, so Nextcloud needs an upgrade
#   expect <check>... checks the current container: maintenance=true|false,
#                     needs_upgrade=true|false, db_version=<version>,
#                     mark=present|absent, secrets=absent|present (the admin,
#                     database and MySQL root passwords in docker logs),
#                     log_has=<ERE>, log_lacks=<ERE> and
#                     log_order=<ERE>,<ERE> (first match of one before the
#                     other); log checks read the output since the last
#                     recreate or restart
#
# Exit status: 0 passed; 3 the recreated container lost the installation
# (config.php missing or changed, Nextcloud not installed, the admin user
# missing, or external storage mounts duplicated or missing); 1 any other
# failure. Only test credentials generated here are used.
#
# The work directory is on tmpfs (/dev/shm): MySQL and the Nextcloud install
# are fsync-heavy, and the builder's /tmp disk makes each install take many
# minutes. The installer's behaviour does not depend on the file system.
# Because tmpfs pages written by the container count against its memory
# limit, the test containers get 6 GB instead of Appbox's 4 GB.
set -euo pipefail

usage() {
    echo "usage: $0 <work dir> install|recreate|cleanup <image> | $0 <work dir> bump|broken-state|restart" >&2
    echo "       $0 <work dir> maint admin|installer | set-db-version <version> | expect <check>..." >&2
    exit 1
}

[ "$#" -ge 2 ] || usage
work=$1
phase=$2
image=${3:-}
case "$phase" in
    install|recreate|cleanup|maint|set-db-version|index500) [ -n "$image" ] || usage ;;
    bump|broken-state|restart|perm-break) ;;
    expect) [ "$#" -ge 3 ] || usage ;;
    *) usage ;;
esac
case "$work" in
    /dev/shm/nextcloud-recreate.??????) ;;
    *) echo "work directory must be a mktemp -d /dev/shm/nextcloud-recreate.XXXXXX directory" >&2; exit 1 ;;
esac
[ -d "$work" ] || { echo "missing work directory $work" >&2; exit 1; }

umask 077
vol=$work/vol
config_php=$vol/public_html/config/config.php
saved_config_php=$vol/logs/config.php
installer_mark=$vol/logs/.appbox-installer-maintenance
installed_re="^[[:space:]]*'installed'[[:space:]]*=>[[:space:]]*true"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

lost() {
    echo "INSTALLATION LOST: $*" >&2
    exit 3
}

say() {
    echo "[recreate-regression $(basename "$work") $phase] $*"
}

if [ "$phase" = install ]; then
    [ ! -e "$vol" ] || fail "$vol already exists"
    mkdir -p "$vol"/config "$vol"/logs "$vol"/mysql_data "$vol"/public_html "$vol"/user_data \
        "$vol"/appbox_data/apps "$vol"/appbox_data/storage "$vol"/ssl
    chmod 755 "$vol" "$vol"/*
    printf 'nextcloud-recreate-%s\n' "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" > "$work/name"
    printf 'gateadmin\n' > "$work/admin_user"
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$work/admin_pass"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$vol/ssl/key.pem" -out "$vol/ssl/cert.pem" \
        -subj "/CN=$(cat "$work/name")" -days 1 >/dev/null 2>&1
    chmod 644 "$vol/ssl/cert.pem" "$vol/ssl/key.pem"
fi

if [ "$phase" = cleanup ]; then
    if [ -f "$work/name" ]; then
        docker rm -f "$(cat "$work/name")" >/dev/null 2>&1 || true
    fi
    if [ -d "$vol" ]; then
        docker run --rm --network none -v "$work:/work" --entrypoint /bin/rm "$image" -rf /work/vol
    fi
    rm -rf "$work"
    exit 0
fi

[ -f "$work/name" ] || fail "no container recorded in $work"
name=$(cat "$work/name")
admin_user=$(cat "$work/admin_user")

occ() {
    docker exec "$name" su -s /bin/sh -c "cd /home/appbox/public_html && php occ $*" appbox
}

start_container() {
    docker run -d --name "$name" --hostname "$name" --init \
        --memory 6g --memory-swap 6g \
        -e "HOSTNAME=$name" -e APP_APEX_CALLBACK=false -e INSTANCE_ID=0 \
        -e PUID=1000 -e PGID=1000 \
        -e "ADMIN_USER=$admin_user" -e "ADMIN_PASS=$(cat "$work/admin_pass")" \
        -v "$vol/config:/home/appbox/config" \
        -v "$vol/ssl/cert.pem:/ssl/cert.pem:ro" \
        -v "$vol/ssl/key.pem:/ssl/key.pem:ro" \
        -v "$vol/logs:/home/appbox/logs" \
        -v "$vol/mysql_data:/home/appbox/mysql" \
        -v "$vol/public_html:/home/appbox/public_html" \
        -v "$vol/user_data/:/storage/" \
        --mount "type=bind,source=$vol/appbox_data,target=/APPBOX_DATA" \
        "$1" >/dev/null
    say "started $name from $1 ($(docker image inspect --format '{{.Id}}' "$1"))"
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

# Nextcloud reports installed:true through occ and through nginx/php-fpm.
wait_for_installed() {
    local attempt
    for attempt in $(seq 1 60); do
        if occ status --output=json 2>/dev/null | jq -e '.installed == true' >/dev/null 2>&1 \
            && docker exec "$name" curl -fsS --max-time 10 http://localhost/status.php 2>/dev/null \
                | jq -e '.installed == true' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

logs_since_start() {
    if [ -s "$work/since" ]; then
        docker logs --since "$(cat "$work/since")" "$name" 2>&1
    else
        docker logs "$name" 2>&1
    fi
}

show_logs() {
    echo "----- last installer output of $name"
    docker logs --tail 60 "$name" 2>&1 | sed 's/^/    /' || true
    echo "-----"
}

# config.php without the keys this test or an upgrade changes on purpose
# ('version' and 'maintenance'), for comparison with the baseline.
config_stable() {
    grep -Ev "^[[:space:]]*'(version|maintenance)'[[:space:]]*=>" "$1"
}

# True when every line of the baseline config.php (apart from 'version' and
# 'maintenance') is still in $1. occ upgrade may add keys ('theme',
# 'loglevel'); a lost or replaced configuration loses baseline lines.
config_kept() {
    [ -z "$(grep -vxFf <(config_stable "$1") <(config_stable "$work/baseline/config.php"))" ]
}

# Lists the configuration keys with their values masked, so a difference can
# be shown without printing secrets.
config_keys() {
    sed -E "s/=>.*/=> .../" "$1"
}

record_state() {
    local dir=$1
    mkdir -p "$dir"
    occ status --output=json 2>/dev/null | tail -n 1 > "$dir/status.json"
    if jq -e '.maintenance or .needsDbUpgrade' "$dir/status.json" >/dev/null; then
        # occ cannot list users or mounts in maintenance mode or before an upgrade.
        echo '{}' > "$dir/users.json"
        echo '[]' > "$dir/mounts.json"
        touch "$dir/limited"
    else
        occ user:list --output=json > "$dir/users.json"
        occ files_external:list --output=json > "$dir/mounts.json"
    fi
    jq -r '.versionstring' "$dir/status.json" > "$dir/version"
    jq -r '[.[].mount_point] | sort | join(" ")' "$dir/mounts.json" > "$dir/mount_points"
}

case "$phase" in
install)
    start_container "$image"
    if ! wait_for_installer; then
        show_logs
        fail "fresh install with $image did not finish"
    fi
    wait_for_installed || { show_logs; fail "fresh install with $image does not report installed:true"; }
    [ -s "$config_php" ] || fail "fresh install left no config.php"
    record_state "$work/baseline"
    cp "$config_php" "$work/baseline/config.php"
    cp "$work/baseline/version" "$work/expected_version"
    jq -e --arg u "$admin_user" 'has($u)' "$work/baseline/users.json" >/dev/null \
        || fail "fresh install did not create the admin user"
    [ "$(cat "$work/baseline/mount_points")" = "/apps /storage" ] \
        || fail "fresh install created external storage mounts '$(cat "$work/baseline/mount_points")', expected /apps and /storage"
    say "fresh install: Nextcloud $(cat "$work/baseline/version") installed, admin user present, mounts $(cat "$work/baseline/mount_points"), config.php $(sha256sum < "$config_php" | cut -c1-16)"
    ;;

bump)
    version_file=$vol/public_html/version.php
    current=$(sed -n "s/^[$]OC_VersionString = '\([0-9]*\.[0-9]*\.[0-9]*\)';\$/\1/p" "$version_file")
    case "$current" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) fail "cannot read the installed version from $version_file" ;;
    esac
    bumped=${current%.*}.$(( ${current##*.} + 1 ))
    [ "$(grep -c "^[$]OC_VersionString = '$current';\$" "$version_file")" -eq 1 ] \
        || fail "unexpected \$OC_VersionString lines in $version_file"
    sed -i "s/^[$]OC_VersionString = '$current';\$/\$OC_VersionString = '$bumped';/" "$version_file"
    grep -q "^[$]OC_VersionString = '$bumped';\$" "$version_file" || fail "could not set the installed version"
    printf '%s\n' "$bumped" > "$work/expected_version"
    say "installed version now reports $bumped (image ships $current)"
    ;;

broken-state)
    [ -f "$work/baseline/config.php" ] || fail "run the install phase first"
    cmp -s "$work/baseline/config.php" "$saved_config_php" \
        || fail "logs/config.php is not the configuration saved before the update"
    [ -f "$config_php" ] || fail "public_html/config/config.php does not exist"
    if grep -Eq "$installed_re" "$config_php"; then
        fail "public_html/config/config.php reports an installed Nextcloud"
    fi
    if [ -s "$config_php" ]; then state="a configuration without 'installed' => true"; else state=empty; fi
    touch "$work/expect_set_aside"
    say "logs/config.php holds the saved configuration; public_html/config/config.php is $state"
    ;;

recreate)
    [ -f "$work/baseline/config.php" ] || fail "run the install phase first"
    docker stop -t 60 "$name" >/dev/null
    docker rm "$name" >/dev/null
    say "removed $name; recreating it from $image with the same directories"
    : > "$work/since"
    start_container "$image"
    installer_status=0
    wait_for_installer || installer_status=$?
    docker logs "$name" 2>&1 | grep -E 'Skipping download and upgrade|Installed Nextcloud version|Dockerfile Nextcloud version|Keeping the saved Nextcloud configuration|Restoring the saved Nextcloud configuration' \
        | sed 's/^/    installer: /' || true

    if [ ! -s "$config_php" ]; then
        show_logs
        if [ -s "$saved_config_php" ]; then
            lost "public_html/config/config.php is missing or empty after the update; the configuration was left in logs/config.php"
        fi
        lost "public_html/config/config.php is missing or empty after the update"
    fi
    if ! config_kept "$config_php"; then
        echo "config.php keys before (<) and after (>) the update, values masked:"
        diff <(config_keys "$work/baseline/config.php") <(config_keys "$config_php") || true
        show_logs
        lost "public_html/config/config.php differs from the configuration before the update"
    fi
    say "config.php restored; every baseline setting kept apart from 'version' and 'maintenance' ($(sha256sum < "$config_php" | cut -c1-16))"

    if [ "$installer_status" -ne 0 ]; then
        show_logs
        fail "the installer did not finish after the update"
    fi
    if ! wait_for_installed; then
        show_logs
        lost "Nextcloud does not report installed:true after the update"
    fi
    rm -rf "$work/after"
    record_state "$work/after"
    if [ -f "$work/after/limited" ]; then
        say "Nextcloud is in maintenance mode or needs an upgrade; users and mounts not listed"
    else
        jq -e --arg u "$admin_user" 'has($u)' "$work/after/users.json" >/dev/null \
            || lost "the admin user $admin_user is missing after the update"
        if [ "$(jq 'length' "$work/after/mounts.json")" -ne "$(jq 'length' "$work/baseline/mounts.json")" ] \
            || [ "$(cat "$work/after/mount_points")" != "$(cat "$work/baseline/mount_points")" ]; then
            lost "external storage mounts changed from '$(cat "$work/baseline/mount_points")' to '$(cat "$work/after/mount_points")'"
        fi
    fi
    [ "$(cat "$work/after/version")" = "$(cat "$work/expected_version")" ] \
        || fail "Nextcloud reports $(cat "$work/after/version") after the update, expected $(cat "$work/expected_version")"
    say "after the update: installed:true (occ and status.php), Nextcloud $(cat "$work/after/version"), admin user present, mounts $(cat "$work/after/mount_points")"
    if [ -f "$work/expect_set_aside" ]; then
        set_aside=$(find "$vol/logs" -maxdepth 1 -name 'config.php.not-installed.*' -print -quit)
        [ -n "$set_aside" ] || lost "the not-installed config.php was not set aside in logs/"
        [ ! -e "$saved_config_php" ] || lost "logs/config.php is still there after the restore"
        rm "$work/expect_set_aside"
        say "the not-installed config.php was set aside as logs/$(basename "$set_aside") and the saved configuration restored"
    fi
    ;;

restart)
    finished=$(docker logs "$name" 2>&1 | grep -c '^appbox-installer: start sequence finished' || true)
    date -u +%Y-%m-%dT%H:%M:%SZ > "$work/since"
    sleep 1
    docker restart -t 60 "$name" >/dev/null
    say "restarted $name (finished start sequences so far: $finished)"
    for attempt in $(seq 1 180); do
        now=$(docker logs "$name" 2>&1 | grep -c '^appbox-installer: start sequence finished' || true)
        [ "$now" -gt "$finished" ] && break
        if [ "$(docker inspect --format '{{.State.Running}}' "$name")" != true ]; then
            show_logs
            fail "the container stopped after the restart"
        fi
        [ "$attempt" -lt 180 ] || { show_logs; fail "the start sequence did not finish within 15 minutes of the restart"; }
        sleep 5
    done
    wait_for_installed || { show_logs; fail "Nextcloud does not report installed:true after the restart"; }
    say "restart finished"
    ;;

maint)
    case "$image" in
        admin) occ maintenance:mode --on >/dev/null ;;
        installer) occ maintenance:mode --on >/dev/null; docker exec "$name" su -s /bin/sh -c 'touch /home/appbox/logs/.appbox-installer-maintenance' appbox ;;
        *) usage ;;
    esac
    cp "$config_php" "$work/baseline/config.php"
    say "maintenance mode on ($image)"
    ;;

perm-break)
    docker exec "$name" sh -c 'echo gate > /storage/gate-wrong-perm && chown root:root /storage/gate-wrong-perm && chmod 0600 /storage/gate-wrong-perm'
    say "/storage/gate-wrong-perm is $(docker exec "$name" stat -c '%a %U %G' /storage/gate-wrong-perm)"
    ;;

index500)
    index_php=$vol/public_html/index.php
    case "$image" in
        on)
            [ ! -e "$index_php.gate-saved" ] || fail "index.php is already replaced"
            docker exec "$name" su -s /bin/sh -c 'cd /home/appbox/public_html && cp -p index.php index.php.gate-saved && printf "%s\n" "<?php http_response_code(500); echo \"gate: simulated 500\";" > index.php' appbox
            code=$(docker exec "$name" curl -s -o /dev/null -w '%{http_code}' "http://$name:80/index.php")
            [ "$code" = 500 ] || fail "index.php answers $code, expected 500"
            ;;
        off)
            docker exec "$name" su -s /bin/sh -c 'cd /home/appbox/public_html && mv -f index.php.gate-saved index.php' appbox
            ;;
        *) usage ;;
    esac
    say "index.php 500: $image"
    ;;

set-db-version)
    case "$image" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;; *) fail "bad version $image" ;; esac
    occ config:system:set version --value "$image" >/dev/null
    cp "$config_php" "$work/baseline/config.php"
    say "config.php 'version' set to $image"
    ;;

expect)
    shift 2
    status_json=$(occ status --output=json 2>/dev/null | tail -n 1)
    # Saved once: grep -q or -m1 reading docker logs through a pipe stops early
    # and, under pipefail, the SIGPIPE to docker logs fails the check.
    logs_since_start > "$work/start.log"
    for check in "$@"; do
        key=${check%%=*}
        want=${check#*=}
        case "$key" in
            maintenance|needs_upgrade)
                field=maintenance
                [ "$key" = needs_upgrade ] && field=needsDbUpgrade
                got=$(printf '%s' "$status_json" | jq -r ".$field")
                [ "$got" = "$want" ] || { show_logs; fail "expected $key=$want, got $got"; }
                ;;
            db_version)
                got=$(docker exec "$name" php -r 'include "/home/appbox/public_html/config/config.php"; echo $CONFIG["version"];' 2>/dev/null)
                [ "$got" = "$want" ] || { show_logs; fail "expected config.php version $want, got $got"; }
                ;;
            perm_fixed)
                got=$(docker exec "$name" stat -c '%a %U %G' /storage/gate-wrong-perm)
                [ "$got" = "770 appbox appbox" ] || fail "/storage/gate-wrong-perm is $got after the recreate, expected 770 appbox appbox"
                ;;
            mark)
                if [ -e "$installer_mark" ]; then got=present; else got=absent; fi
                [ "$got" = "$want" ] || { show_logs; fail "expected the installer marker to be $want, it is $got"; }
                ;;
            secrets)
                # Counts only; the secrets themselves are never printed. Empty
                # values are skipped (an empty pattern would match every line).
                { cat "$work/admin_pass"; echo
                  docker exec "$name" printenv DB_PASS || true
                  docker exec "$name" printenv MYSQL_ROOT_PASSWORD || true
                } | grep -v '^$' > "$work/secret-patterns"
                [ "$(wc -l < "$work/secret-patterns")" -ge 1 ] || fail "no secrets to look for"
                leaks=$( { docker logs "$name" 2>&1 || true; } | grep -cFf "$work/secret-patterns" || true)
                rm -f "$work/secret-patterns"
                if [ "$leaks" -gt 0 ]; then got=present; else got=absent; fi
                [ "$got" = "$want" ] || fail "expected secrets in docker logs to be $want; $leaks log lines contain one"
                ;;
            log_has)
                grep -Eq -- "$want" "$work/start.log" || { show_logs; fail "the log since the last start has no line matching: $want"; }
                ;;
            log_lacks)
                if grep -Eq -- "$want" "$work/start.log"; then
                    grep -E -- "$want" "$work/start.log" | head -n 3 | sed 's/^/    /'
                    fail "the log since the last start has a line matching: $want"
                fi
                ;;
            log_order)
                first=${want%%,*}
                second=${want#*,}
                n1=$(grep -nE -m1 -- "$first" "$work/start.log" | cut -d: -f1 || true)
                n2=$(grep -nE -m1 -- "$second" "$work/start.log" | cut -d: -f1 || true)
                [ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" -lt "$n2" ] \
                    || { show_logs; fail "expected '$first' (line ${n1:-none}) before '$second' (line ${n2:-none})"; }
                ;;
            *) fail "unknown check $check" ;;
        esac
        say "ok: $check"
    done
    ;;
esac
