#!/bin/sh
# Usage (inside the image, after my_init's startup scripts, with a fresh tmpfs
# on /run): run-dirs-check.sh
#
# Checks that the runtime directories exist with the expected owners and that
# the services which need them can create their sockets there: php-fpm8.1 on
# /run/php/php8.1-fpm.sock, mysqld (as appbox) on /run/mysqld/mysqld.sock, and
# sshd's privilege separation directory. Uses throwaway configuration and data
# in /tmp, so it does not depend on the Nextcloud installer.
set -eu

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mount | grep -q ' on /run type tmpfs' || fail "/run is not a fresh tmpfs in this test container"

for spec in /run/php:appbox:appbox:755 /run/mysqld:appbox:appbox:755 /run/sshd:root:root:755; do
    dir=${spec%%:*}
    want=${spec#*:}
    [ -d "$dir" ] || fail "$dir does not exist after startup"
    got=$(stat -c '%U:%G:%a' "$dir")
    [ "$got" = "$want" ] || fail "$dir is $got, expected $want"
    echo "$dir $got"
done

work=$(mktemp -d)
fpm_pid=
mysqld_pid=
cleanup() {
    [ -z "$fpm_pid" ] || kill "$fpm_pid" 2>/dev/null || true
    if [ -n "$mysqld_pid" ]; then
        mysqladmin --socket=/run/mysqld/mysqld.sock -uroot shutdown >/dev/null 2>&1 || kill "$mysqld_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

cat > "$work/fpm.conf" <<EOF
[global]
error_log = $work/fpm.log
daemonize = no

[www]
user = appbox
group = appbox
listen = /run/php/php8.1-fpm.sock
listen.owner = appbox
listen.group = appbox
pm = static
pm.max_children = 1
EOF
php-fpm8.1 --nodaemonize --fpm-config "$work/fpm.conf" &
fpm_pid=$!
i=0
while [ ! -S /run/php/php8.1-fpm.sock ]; do
    i=$((i + 1))
    [ "$i" -le 30 ] || { cat "$work/fpm.log" >&2; fail "php-fpm8.1 did not create /run/php/php8.1-fpm.sock"; }
    sleep 1
done
echo "php-fpm8.1 listening on /run/php/php8.1-fpm.sock"

mkdir -p "$work/db"
chown appbox:appbox "$work/db"
mysqld --no-defaults --user=appbox --datadir="$work/db" --initialize-insecure --log-error="$work/init.log" \
    || { cat "$work/init.log" >&2; fail "mysqld --initialize-insecure failed"; }
mysqld --no-defaults --user=appbox --datadir="$work/db" --socket=/run/mysqld/mysqld.sock \
    --pid-file="$work/db/mysqld.pid" --skip-networking --mysqlx=OFF --log-error="$work/mysqld.log" &
mysqld_pid=$!
i=0
until mysqladmin --socket=/run/mysqld/mysqld.sock -uroot ping >/dev/null 2>&1; do
    i=$((i + 1))
    kill -0 "$mysqld_pid" 2>/dev/null || { tail -n 20 "$work/mysqld.log" >&2; fail "mysqld exited"; }
    [ "$i" -le 120 ] || { tail -n 20 "$work/mysqld.log" >&2; fail "mysqld did not answer on /run/mysqld/mysqld.sock"; }
    sleep 1
done
echo "mysqld answering on /run/mysqld/mysqld.sock as $(stat -c '%U' /run/mysqld/mysqld.sock)"

ssh-keygen -A >/dev/null
/usr/sbin/sshd -t -f /etc/ssh/sshd_config || fail "sshd -t failed"
echo "sshd configuration test passed"
echo "run-dirs-check passed"
