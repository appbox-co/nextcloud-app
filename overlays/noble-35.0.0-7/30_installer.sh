#!/bin/bash
# 35.0.0-7: the 35.0.0-6 installer with
#   - config/autoconfig.php written by PHP's var_export from the environment,
#     so an admin password with ', ", \ or $ reaches Nextcloud's setup
#     unchanged. 35.0.0-6 pasted the values into PHP quotes with echo, and a '
#     in the password gave a parse error on every request;
#   - readiness checks that read the HTTP status of index.php and ask occ
#     whether Nextcloud is installed. 35.0.0-6 grepped curl's output for
#     '200', which the HSTS header (max-age=15552000) matched on any page,
#     error pages included;
#   - fail closed: when Nextcloud is not installed, or does not answer, the
#     installer stops its services and exits non-zero, without the installed
#     callback and without /etc/app_installer_completed. my_init then stops
#     the container, Docker starts it again (restart policy unless-stopped)
#     and the installer runs again; a first-time setup that did not finish is
#     run again rather than treated as an update.
# Progress lines start with "appbox-installer:" and never contain secrets.

log() {
    echo "appbox-installer: $*"
}

# config.php sets 'installed' => true once Nextcloud's setup has finished.
installed_re="^[[:space:]]*'installed'[[:space:]]*=>[[:space:]]*true[[:space:]]*,?[[:space:]]*$"

# Stops what this script started and exits non-zero. No installed callback is
# sent, /etc/app_installer_completed is not created and nothing serves the
# site, so a broken setup page is never reported as a finished install.
fail_closed() {
    log "$*"
    log "Nextcloud is not ready; stopping without the installed callback. The next start runs the installer again."
    pkill -9 nginx
    pkill -9 php
    pkill -9 mysql
    pkill -9 redis-server
    exit 1
}

# Writes config/autoconfig.php for Nextcloud's first-time setup. PHP reads the
# values with getenv, so no password is on a command line, and var_export
# writes them as valid PHP strings whatever they contain. Nextcloud's setup
# passes adminlogin and adminpass through htmlspecialchars_decode, so those two
# are stored HTML-escaped and reach the account exactly as chosen. The file is
# checked by reading it back before it replaces any earlier one.
write_autoconfig() {
    local config_dir=/home/appbox/public_html/config
    local tmp
    tmp=$(mktemp "$config_dir/.autoconfig.XXXXXX") || return 1
    if ! php -r '
        $env = [];
        foreach (["DB_NAME", "DB_USER", "DB_PASS", "ADMIN_USER", "ADMIN_PASS"] as $key) {
            $value = getenv($key);
            if ($value === false || !preg_match("//u", $value)) {
                fwrite(STDERR, "appbox-installer: $key is not set or is not valid UTF-8\n");
                exit(1);
            }
            $env[$key] = $value;
        }
        $html = fn (string $value): string => htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE | ENT_HTML401, "UTF-8");
        $autoconfig = [
            "dbtype" => "mysql",
            "dbname" => $env["DB_NAME"],
            "dbuser" => $env["DB_USER"],
            "dbpass" => $env["DB_PASS"],
            "dbhost" => "localhost:3306",
            "dbtableprefix" => "nc_",
            "adminlogin" => $html($env["ADMIN_USER"]),
            "adminpass" => $html($env["ADMIN_PASS"]),
            "directory" => "/storage",
        ];
        echo "<?php\n\$AUTOCONFIG = ", var_export($autoconfig, true), ";\n";
    ' > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! php -r '
        $AUTOCONFIG = [];
        include $argv[1];
        exit(($AUTOCONFIG["dbname"] ?? null) === getenv("DB_NAME")
            && ($AUTOCONFIG["dbuser"] ?? null) === getenv("DB_USER")
            && ($AUTOCONFIG["dbpass"] ?? null) === getenv("DB_PASS")
            && htmlspecialchars_decode($AUTOCONFIG["adminlogin"] ?? "") === getenv("ADMIN_USER")
            && htmlspecialchars_decode($AUTOCONFIG["adminpass"] ?? "") === getenv("ADMIN_PASS") ? 0 : 1);
    ' "$tmp" >/dev/null 2>&1; then
        log "the generated autoconfig.php does not read back as the configured values"
        rm -f "$tmp"
        return 1
    fi
    chown appbox:appbox "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$config_dir/autoconfig.php"
}

# Prints installed, not-installed or unknown (occ gave no usable status).
nextcloud_state() {
    su -s /bin/sh -c "cd /home/appbox/public_html && php occ status --output=json" appbox 2>/dev/null \
        | tail -n 1 \
        | php -r '$s = json_decode(stream_get_contents(STDIN), true);
            echo !is_array($s) || !array_key_exists("installed", $s) ? "unknown" : ($s["installed"] === true ? "installed" : "not-installed");'
}

# Prints the HTTP status of index.php ("000" when there is no answer).
# Redirects are not followed: an installed Nextcloud redirects to
# https://<host>/login, which curl cannot verify inside the container.
index_status() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 900 http://"$HOSTNAME":80/index.php
}

# Waits up to 15 minutes until index.php answers and occ reports Nextcloud
# installed. Returns non-zero when it does not.
#   fresh: the first request runs the setup from autoconfig.php and answers
#     200 or a redirect. A 200 or 500 from a Nextcloud that is still not
#     installed means the setup was rejected (200 is the setup page listing
#     the errors), so it stops at once instead of requesting the setup again.
#     After a 504 the setup may still be running behind nginx's 600-second
#     timeout, so it waits for occ instead of starting a second setup.
#   existing: any answer from PHP will do, 500 and 503 included (an upgrade
#     pending, maintenance mode); no answer, 502 and 504 mean nginx or php-fpm
#     is not ready yet. If occ gives no usable status, an installed config.php
#     counts as installed, so an installation that occ cannot load still
#     starts as it did before.
wait_for_nextcloud() {
    local mode=$1 code state deadline=$((SECONDS + 900))
    while [ "$SECONDS" -lt "$deadline" ]; do
        code=$(index_status)
        case "$mode:$code" in
            fresh:200|fresh:30[1237]|fresh:500|existing:[1-4][0-9][0-9]|existing:50[01356789])
                state=$(nextcloud_state)
                if [ "$state" = installed ]; then
                    log "index.php answered $code; occ reports Nextcloud installed"
                    return 0
                fi
                if [ "$mode" = existing ] && [ "$state" = unknown ] \
                    && grep -Eq "$installed_re" /home/appbox/public_html/config/config.php 2>/dev/null; then
                    log "index.php answered $code; occ gave no status, but config.php is installed"
                    return 0
                fi
                log "index.php answered $code, but Nextcloud is not installed (occ: $state)"
                return 1
                ;;
            fresh:504)
                log "index.php timed out during the setup; waiting for it to finish"
                while [ "$SECONDS" -lt "$deadline" ]; do
                    if [ "$(nextcloud_state)" = installed ]; then
                        log "occ reports Nextcloud installed"
                        return 0
                    fi
                    sleep 10
                done
                ;;
        esac
        printf '.'
        sleep 2
    done
    log "Nextcloud did not answer as installed within 15 minutes (last answer: ${code:-none})"
    return 1
}

if [ ! -f /etc/ssh/ssh_host_rsa_key ] ; then
    ssh-keygen -o -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa -b 4096
fi

if [ ! -f /etc/ssh/ssh_host_ed25519_key ] ; then
    ssh-keygen -o -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519
fi


mkdir -p /run/php
chmod 755 /run/php
chown -R appbox:appbox /run/php
mkdir -p /run/sshd
chmod 755 /run/sshd
mkdir /home/appbox/.ssh
chmod 700 /home/appbox/.ssh
touch /home/appbox/.ssh/authorized_keys
chmod 600 /home/appbox/.ssh/authorized_keys
chmod 770 /home/appbox
chown -R appbox:appbox /home/appbox/.ssh
mkdir -p /run/mysqld
chmod 755 /run/mysqld
chown -R appbox:appbox /run/mysqld

# Change the appbox user shell to /bin/bash
usermod -s /bin/bash appbox

echo "appbox:$ADMIN_PASS" | chpasswd

echo "Setting up SSH Daemon"
mkdir -p /etc/service/sshd
echo "#!/bin/sh
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config" > /etc/service/sshd/run
chmod +x /etc/service/sshd/run
rm -f /etc/service/sshd/down


# MySQL Lock file if the app was forcefully closed.
rm -fr /var/run/mysqld/mysqld.sock.lock

# Redis serves Nextcloud's file locking and distributed cache. runit starts it
# (/etc/service/redis) only after these my_init.d scripts, so the occ commands
# below need their own instance, started and stopped like mysqld.
start_redis() {
    mkdir -p /run/redis
    chown appbox:appbox /run/redis
    chmod 750 /run/redis
    chpst -u appbox:appbox /usr/bin/redis-server /etc/nextcloud-redis.conf &
    for attempt in $(seq 1 30); do
        [ -S /run/redis/redis.sock ] && return 0
        sleep 1
    done
    echo "Redis did not start." >&2
}

# These files can survive an image change in the Appbox home volume. Keep the
# active FPM service, nginx socket, and both PHP SAPIs on the same release.
printf 'memory_limit = 3G\n' > /etc/php/8.4/fpm/conf.d/99-nextcloud-memory.ini
printf 'memory_limit = 3G\n' > /etc/php/8.4/cli/conf.d/99-nextcloud-memory.ini
pool_config=/home/appbox/config/php-fpm/pool.d/www.conf
if [ ! -f "$pool_config" ]; then
    echo 'PHP-FPM pool configuration is missing.' >&2
    exit 1
fi
# Nextcloud ships a .user.ini that can lower the ordinary FPM ini setting.
# A pool admin value keeps the image's 3G limit effective on every boot.
sed -i '/^[[:space:]]*php_admin_value\[memory_limit\][[:space:]]*=/d' "$pool_config"
printf '\nphp_admin_value[memory_limit] = 3G\n' >> "$pool_config"
if ! /usr/sbin/php-fpm8.4 -t --fpm-config /home/appbox/config/php-fpm/php-fpm.conf; then
    echo 'PHP-FPM pool configuration is invalid.' >&2
    exit 1
fi
if [ -f /etc/service/phpfpm/run ]; then
    sed -i 's/php-fpm8\.[234]/php-fpm8.4/g' /etc/service/phpfpm/run
fi
if [ -f /home/appbox/config/nginx/sites-enabled/nextcloud.conf ]; then
    sed -i 's/php8\.[234]-fpm.sock/php8.4-fpm.sock/g' /home/appbox/config/nginx/sites-enabled/nextcloud.conf
fi

if [ ! -f /etc/app_installer_completed ]; then

    echo "**************************************************************"
    echo "*                                                            *"
    echo "*                 Cylo Base Installer 1.0                    *"
    echo "*                     Installing Apps:                       *"
    echo "*                                                            *"
    echo "**************************************************************"
    echo "Nextcloud"
    echo "**************************************************************"
    echo " "

    if [ -f /home/appbox/public_html/config/config.php ]; then
        mkdir -p /home/appbox/public_html/config/
        if grep -Eq "^[[:space:]]*'installed'[[:space:]]*=>[[:space:]]*true[[:space:]]*,?[[:space:]]*$" /home/appbox/logs/config.php 2>/dev/null \
            && ! grep -Eq "^[[:space:]]*'installed'[[:space:]]*=>[[:space:]]*true[[:space:]]*,?[[:space:]]*$" /home/appbox/public_html/config/config.php; then
            # An earlier start left an empty or not-installed config.php in place
            # of this installation's saved configuration. Keep the saved one.
            echo "Keeping the saved Nextcloud configuration in /home/appbox/logs/config.php"
            mv /home/appbox/public_html/config/config.php /home/appbox/logs/config.php.not-installed."$(date +%Y%m%d%H%M%S)"
        else
            mv /home/appbox/public_html/config/config.php /home/appbox/logs/config.php
        fi
    fi

    ls -la /home/appbox/config
    ls -la /home/appbox/config/php-fpm/

    # Add our own NGINX Config.
    mkdir -p /home/appbox/config/nginx/sites-enabled/
    rm -fr /home/appbox/config/nginx/sites-enabled/default-site.conf
    cp /app-sources/nextcloud.conf /home/appbox/config/nginx/sites-enabled/nextcloud.conf
    sed -i 's/HOSTNAME/'"$HOSTNAME"'/g' /home/appbox/config/nginx/sites-enabled/nextcloud.conf

    # Configure PHP for Nextcloud
echo "memory_limit = 3G
max_execution_time = 300
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.revalidate_freq=1
upload_max_filesize=100G
post_max_size=100G
max_execution_time=3600" > /etc/php/8.4/fpm/conf.d/40-nextcloud.ini

echo "env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp" >> /home/appbox/config/php-fpm/pool.d/www.conf

    mkdir -p /storage

    UPGRADE=true
    SKIP_UPGRADE=false
    if [ ! -f /home/appbox/public_html/index.php ]; then
        UPGRADE=false
    elif [ -f /home/appbox/public_html/config/autoconfig.php ] \
        && ! grep -Eq "$installed_re" /home/appbox/logs/config.php 2>/dev/null; then
        # Nextcloud deletes autoconfig.php when its setup succeeds, and an
        # existing installation's config.php is now in logs/config.php. With
        # autoconfig.php still here and no installed configuration saved, an
        # earlier first-time setup did not finish: run it again.
        log "an earlier first-time setup did not finish; running the setup again"
        UPGRADE=false
    fi

    # Function to compare semantic versions
    # Returns 0 if v1 > v2, 1 if v1 = v2, 2 if v1 < v2
    version_compare() {
        local v1=$1
        local v2=$2

        # Split versions into arrays
        IFS='.' read -ra V1_PARTS <<< "$v1"
        IFS='.' read -ra V2_PARTS <<< "$v2"

        # Compare each part
        for i in 0 1 2; do
            local part1=${V1_PARTS[$i]:-0}
            local part2=${V2_PARTS[$i]:-0}

            if (( part1 > part2 )); then
                return 0
            elif (( part1 < part2 )); then
                return 2
            fi
        done

        return 1
    }

    # Check if installed version is higher than the version we're deploying
    # This can happen when users upgrade from the Nextcloud frontend
    if [ -f /home/appbox/public_html/version.php ]; then
        # Extract version from version.php (e.g., $OC_VersionString = '31.0.4';)
        INSTALLED_VER=$(grep -oP "\\\$OC_VersionString\s*=\s*'\K[0-9]+\.[0-9]+\.[0-9]+" /home/appbox/public_html/version.php)

        if [ -n "$INSTALLED_VER" ]; then
            echo "Installed Nextcloud version: $INSTALLED_VER"
            echo "Dockerfile Nextcloud version: $NEXTCLOUD_VER"

            version_compare "$INSTALLED_VER" "$NEXTCLOUD_VER"
            COMPARE_RESULT=$?

            if [ $COMPARE_RESULT -eq 0 ] || [ $COMPARE_RESULT -eq 1 ]; then
                echo "Installed version ($INSTALLED_VER) is >= Dockerfile version ($NEXTCLOUD_VER). Skipping download and upgrade."
                SKIP_UPGRADE=true
            fi
        fi
    fi

    # download app (skip if installed version is already higher)
    if [ "$SKIP_UPGRADE" = false ]; then
        cd /home/appbox/public_html
        /app-sources/verify-nextcloud-archive.sh "$NEXTCLOUD_VER" || exit 1
        cd /home/appbox/public_html
        unzip -o /app-sources/nextcloud-"${NEXTCLOUD_VER}".zip || exit 1
        cp -R nextcloud/* .
        cp -R nextcloud/.* .
        rm -fr nextcloud/
    fi

    if [[ $UPGRADE == "true" ]]; then
        # An existing installation never reads autoconfig.php; do not leave the
        # admin and database passwords in it.
        rm -f /home/appbox/public_html/config/autoconfig.php
    else
        write_autoconfig || fail_closed "could not write autoconfig.php for the first-time setup"
    fi

    if [ ! -f /storage/.ocdata ]; then
        touch /storage/.ocdata
    fi

    chown -R appbox:appbox /home/appbox/public_html

    find /storage -not \( -path */apps/* -prune \) -not \( -path */apps/ -prune \) -exec chmod 0770 {} \;
    find /storage -not \( -path */apps/* -prune \) -not \( -path */apps/ -prune \) -exec chown appbox:appbox {} \;

    #This is an existing installation: an upgrade, or a recreate with the same
    #Nextcloud version (the download above is skipped if the installed version
    #is already the same or higher, and occ upgrade then has nothing to do)
    if [[ $UPGRADE == "true" ]]; then
        # Put the saved configuration back before nginx and php-fpm start, so
        # no request can reach the setup page of an installed Nextcloud.
        if [ -s /home/appbox/logs/config.php ] && [ ! -s /home/appbox/public_html/config/config.php ]; then
            echo "Restoring the saved Nextcloud configuration"
            mv /home/appbox/logs/config.php /home/appbox/public_html/config/config.php
            chown appbox:appbox /home/appbox/public_html/config/config.php
        fi
        /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
        start_redis
        /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.4 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
        sleep 10

        while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
        do
            sleep 3
            echo "waiting for mysql ..."
        done

        if [ -f /home/appbox/logs/config.php ]; then
            mv /home/appbox/logs/config.php /home/appbox/public_html/config/config.php
            chown -R appbox:appbox /home/appbox/public_html/config/config.php
        fi

        # Make sure config.php exists and Nextcloud is installed
        wait_for_nextcloud existing || fail_closed "the existing installation is not ready before its upgrade"

        su -c "cd /home/appbox/public_html; php occ --no-interaction upgrade" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-columns" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction config:app:set files max_chunk_size --value 52428800" -s /bin/sh appbox

        pkill -9 mysql
        pkill -9 nginx
        pkill -9 php
        pkill -9 redis-server
        rm -fr /run/mysqld/mysqld.sock
    else
        /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
        start_redis
        /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.4 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
        sleep 10

        while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
        do
            sleep 3
            echo "waiting for mysql ..."
        done

        # The first request runs Nextcloud's setup from autoconfig.php.
        wait_for_nextcloud fresh || fail_closed "the first-time setup did not finish"

        su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction app:update --all" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction app:enable files_external" -s /bin/sh appbox
        # Add the /apps and /storage mounts only when the database does not
        # already have them, and enable sharing on the ids Nextcloud reports
        # rather than assuming 1 and 2.
        for mount in apps storage; do
            mount_id=$(su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:list --output=json" -s /bin/sh appbox \
                | php -r '$m = json_decode(stream_get_contents(STDIN), true); foreach (is_array($m) ? $m : [] as $s) { if (($s["mount_point"] ?? "") === "/" . $argv[1]) { echo $s["mount_id"]; break; } }' -- "$mount")
            if [ -z "$mount_id" ]; then
                mount_id=$(su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:create $mount local null::null --config datadir=/APPBOX_DATA/$mount/" -s /bin/sh appbox \
                    | sed -n 's/^Storage created with id \([0-9][0-9]*\)$/\1/p')
            fi
            if [ -n "$mount_id" ]; then
                su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:option $mount_id enable_sharing true" -s /bin/sh appbox
            else
                echo "Could not create the /$mount external storage mount." >&2
            fi
        done
        su -c "cd /home/appbox/public_html; php occ --no-interaction config:app:set files max_chunk_size --value 52428800" -s /bin/sh appbox

        pkill -9 mysql
        pkill -9 nginx
        pkill -9 php
        pkill -9 redis-server
    fi
fi

/usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
start_redis
/usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.4 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
sleep 10

while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
do
    sleep 3
    echo "waiting for mysql ..."
done

wait_for_nextcloud existing || fail_closed "Nextcloud did not start as an installed instance"

# Check if the MIME type mapping for .mjs already exists
if ! grep -q "text/javascript js mjs;" "/home/appbox/config/nginx/nginx.conf"; then
    # Use sed to insert the types block after the include directive
    sed -i '/include \/etc\/nginx\/mime.types;/a\
types {\
    text/javascript js mjs;\
}' "/home/appbox/config/nginx/nginx.conf"
    echo "Added MIME type mapping for .mjs to /home/appbox/config/nginx/nginx.conf."
else
    echo "MIME type mapping for .mjs already exists in /home/appbox/config/nginx/nginx.conf."
fi

# To fix https://github.com/nextcloud/desktop/issues/1130
if ! grep -q 'overwriteprotocol' /home/appbox/public_html/config/config.php; then
    sed -i "/\$CONFIG/a \ \ 'overwriteprotocol' => 'https'," /home/appbox/public_html/config/config.php
fi

if ! grep -q 'memcache' /home/appbox/public_html/config/config.php; then
    sed -i "/\$CONFIG/a \ \ 'memcache.local' => '\\\OC\\\Memcache\\\APCu'," /home/appbox/public_html/config/config.php
fi

# Redis (/etc/service/redis) handles transactional file locking and the
# distributed cache. Each entry is added only when it is missing, so a value
# an administrator has set is kept.
if ! grep -Eq "^[[:space:]]*'redis'[[:space:]]*=>" /home/appbox/public_html/config/config.php; then
    sed -i "/\$CONFIG/a \ \ 'redis' => array('host' => '/run/redis/redis.sock', 'port' => 0)," /home/appbox/public_html/config/config.php
fi
if ! grep -q "'memcache.locking'" /home/appbox/public_html/config/config.php; then
    sed -i "/\$CONFIG/a \ \ 'memcache.locking' => '\\\OC\\\Memcache\\\Redis'," /home/appbox/public_html/config/config.php
fi
if ! grep -q "'memcache.distributed'" /home/appbox/public_html/config/config.php; then
    sed -i "/\$CONFIG/a \ \ 'memcache.distributed' => '\\\OC\\\Memcache\\\Redis'," /home/appbox/public_html/config/config.php
fi

if ! grep -q 'maintenance_window_start' /home/appbox/public_html/config/config.php; then
    # 'maintenance_window_start' => 1,
    # Set maintenance window to a random time of day between 0-6
    RANDOM_TIME=$(shuf -i 0-6 -n 1)
    sed -i "/\$CONFIG/a \ \ 'maintenance_window_start' => $RANDOM_TIME," /home/appbox/public_html/config/config.php
fi

su -c "cd /home/appbox/public_html; php occ maintenance:repair --include-expensive" -s /bin/sh appbox

pkill -9 mysql
pkill -9 nginx
pkill -9 php
pkill -9 redis-server

echo "                                   .''.       "
echo "       .''.      .        *''*    :_\/_:     . "
echo "      :_\/_:   _\(/_  .:.*_\/_*   : /\ :  .'.:.'."
echo "  .''.: /\ :   ./)\   ':'* /\ * :  '..'.  -=:o:=-"
echo " :_\/_:'.:::.    ' *''*    * '.\'/.' _\(/_'.':'.'"
echo " : /\ : :::::     *_\/_*     -= o =-  /)\    '  *"
echo "  '..'  ':::'     * /\ *     .'/.\'.   '"
echo "      *            *..*         :"

echo "Finishing Install"
# Finish Install
if [ "${APP_APEX_CALLBACK}" = true ]; then
    until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
        do
        sleep 5
    done
fi

# set cronjob
crontab /app-sources/crontab
touch /etc/app_installer_completed


#####
# May need to change ~/public_html/lib/private/Updater.php
# cp ~/public_html/lib/private/Updater.php ~/
# edit file as below
# Exception: Updates between multiple major versions and downgrades are unsupported.
# https://help.nextcloud.com/t/cannot-manually-upgrade-from-11-0-3/13054/4
# Table 'nextcloud.nc_flow_operations_scope' doesn't exist:
# then mv ~/public_html/apps/workflowengine/appinfo/database.xml ~/
# su -c "cd /home/appbox/public_html; php occ --no-interaction upgrade" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-columns" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction app:update --all" -s /bin/sh appbox
#
# mv ~/database.xml ~/public_html/apps/workflowengine/appinfo/database.xml
# cp ~/Updater.php ~/public_html/lib/private/Updater.php
# su -c "cd /home/appbox/public_html; php occ maintenance:mode --off" -s /bin/sh appbox
#
# Table 'nextcloud.nc_filecache_extended' doesn't exist: https://github.com/nextcloud/server/issues/15698
# mysql -p
# use nextcloud
# CREATE TABLE `nc_filecache_extended` (
#   `fileid` bigint(20) unsigned NOT NULL,
#   `metadata_etag` varchar(40) COLLATE utf8mb4_bin DEFAULT NULL,
#   `creation_time` bigint(20) NOT NULL DEFAULT '0',
#   `upload_time` bigint(20) NOT NULL DEFAULT '0',
#   UNIQUE KEY `fce_fileid_idx` (`fileid`),
#   KEY `fce_ctime_idx` (`creation_time`),
#   KEY `fce_utime_idx` (`upload_time`)
# ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
#
# If high memory or segfault:
# echo "apc.enable_cli=1" >> /etc/php/8.4/cli/conf.d/20-apcu.ini
# If end up in an upgrade loop
# delete affected apps from /home/appbox/public_html/apps/
# and restore from a fresh unzipped nextcloud.zip
# upgrade should then complete
