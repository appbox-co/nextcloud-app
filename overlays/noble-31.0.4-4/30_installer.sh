#!/bin/bash
# No shell tracing: 31.0.4-2 ran under set -x, which printed the appbox
# password (chpasswd) and the autoconfig passwords into the container log.
# Progress lines start with "appbox-installer:" and never contain secrets.

log() {
    echo "appbox-installer: $*"
}

occ_appbox() {
    su -s /bin/sh -c "cd /home/appbox/public_html && php occ $*" appbox
}

# Set while this installer has Nextcloud in maintenance mode for an upgrade or
# repair it runs. It lives in the persistent logs volume, so a run that is cut
# short (container stopped or restarted mid-upgrade) is finished at the next
# start instead of leaving maintenance mode on. Maintenance mode that this
# installer did not set (an administrator's, or an older failed upgrade's) is
# left alone.
INSTALLER_MAINT_MARK=/home/appbox/logs/.appbox-installer-maintenance

# Sets NC_MAINTENANCE and NC_NEEDS_UPGRADE to 1 or 0 from occ status.
read_status() {
    local json
    json=$(occ_appbox status --output=json 2>/dev/null | tail -n 1)
    NC_MAINTENANCE=$(printf '%s' "$json" | php -r '$s = json_decode(stream_get_contents(STDIN), true); echo empty($s["maintenance"]) ? 0 : 1;' 2>/dev/null)
    NC_NEEDS_UPGRADE=$(printf '%s' "$json" | php -r '$s = json_decode(stream_get_contents(STDIN), true); echo empty($s["needsDbUpgrade"]) ? 0 : 1;' 2>/dev/null)
}

# Waits until nginx and php-fpm answer index.php. Redirects are not followed:
# an installed Nextcloud redirects to https://<host>/login, which curl cannot
# verify inside the container. A fresh install waits for 200 or a redirect
# (the first request installs Nextcloud from autoconfig.php). For an existing
# installation any answer from PHP will do, including 500 (an installation
# whose code is several major versions ahead of its database) and 503
# (maintenance mode or an upgrade pending); only no answer, 502 and 504 mean
# nginx or php-fpm is not ready yet. 31.0.4-3 accepted only 200, redirects,
# 401, 403 and 503, so such installations waited here forever.
wait_for_web() {
    local code
    while :; do
        code=$(curl -s -o /dev/null -w '%{http_code}' http://"$HOSTNAME":80/index.php)
        case "$1:$code" in
            fresh:200|fresh:30[1237]) return 0 ;;
            existing:000|existing:502|existing:504) ;;
            existing:[1-5][0-9][0-9]) return 0 ;;
        esac
        printf '.'
        sleep 1
    done
}

# Prints the 'version' stored in a config.php (the version the database is at).
stored_version() {
    php -r 'error_reporting(0); $CONFIG = []; include $argv[1]; echo $CONFIG["version"] ?? "";' "$1" 2>/dev/null
}

# True when the database version stored in config.php is more than one major
# version behind the installed code. occ upgrade refuses such a jump, and
# repair against the old schema fails, so the installer leaves it alone.
version_gap() {
    local stored code
    stored=$(stored_version /home/appbox/public_html/config/config.php)
    code=$(php -r 'include "/home/appbox/public_html/version.php"; echo $OC_Version[0];' 2>/dev/null)
    case "${stored%%.*}/$code" in *[!0-9/]*|/*|*/) return 1 ;; esac
    [ "${stored%%.*}" -lt $((code - 1)) ]
}

# Runs the pending upgrade and the repair while this installer owns
# maintenance mode, and turns maintenance mode off only when both succeed.
finish_installer_maintenance() {
    local rc
    read_status
    if [ "$NC_MAINTENANCE" = 1 ]; then
        occ_appbox maintenance:mode --off
    fi
    if [ "$NC_NEEDS_UPGRADE" = 1 ]; then
        log "running occ upgrade"
        occ_appbox --no-interaction upgrade
        rc=$?
        if [ "$rc" -ne 0 ]; then
            log "occ upgrade failed (exit $rc); it is tried again at the next start"
            return 1
        fi
        log "occ upgrade finished"
    fi
    log "running occ maintenance:repair --include-expensive"
    occ_appbox --no-interaction maintenance:repair --include-expensive
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "occ maintenance:repair failed (exit $rc); it is tried again at the next start"
        return 1
    fi
    read_status
    if [ "$NC_MAINTENANCE" = 1 ]; then
        occ_appbox maintenance:mode --off
    fi
    rm -f "$INSTALLER_MAINT_MARK"
    log "upgrade and repair finished; maintenance mode is off"
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
max_execution_time=3600" > /etc/php/8.3/fpm/conf.d/40-nextcloud.ini

if ! grep -q '^env\[HOSTNAME\]' /home/appbox/config/php-fpm/pool.d/www.conf; then
echo "env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp" >> /home/appbox/config/php-fpm/pool.d/www.conf
fi

    mkdir -p /storage

    UPGRADE=true
    SKIP_UPGRADE=false
    if [ ! -f /home/appbox/public_html/index.php ]; then
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

    # Updates across more than one major version are unsupported: do not put
    # new code over a database that is further behind than that.
    if [ "$SKIP_UPGRADE" = false ] && [ -f /home/appbox/logs/config.php ]; then
        STORED_VER=$(stored_version /home/appbox/logs/config.php)
        case "${STORED_VER%%.*}" in
            ''|*[!0-9]*) ;;
            *)
                if [ "${STORED_VER%%.*}" -lt $((${NEXTCLOUD_VER%%.*} - 1)) ]; then
                    log "the database is at Nextcloud $STORED_VER, more than one major version behind $NEXTCLOUD_VER; not downloading $NEXTCLOUD_VER"
                    SKIP_UPGRADE=true
                fi
                ;;
        esac
    fi

    # download app (skip if installed version is already higher)
    if [ "$SKIP_UPGRADE" = false ]; then
        cd /home/appbox/public_html
        curl -o nextcloud.zip -L https://download.nextcloud.com/server/releases/nextcloud-"${NEXTCLOUD_VER}".zip
        unzip -o nextcloud.zip
        cp -R nextcloud/* .
        cp -R nextcloud/.* .
        rm -f nextcloud.zip
        rm -fr nextcloud/
    fi

    if [[ $UPGRADE == "true" ]]; then
        # An existing installation never reads autoconfig.php; do not leave the
        # admin and database passwords in it.
        rm -f /home/appbox/public_html/config/autoconfig.php
    else
echo "<?php
\$AUTOCONFIG = array(
  'dbtype'        => 'mysql',
  'dbname'        => '${DB_NAME}',
  'dbuser'        => '${DB_USER}',
  'dbpass'        => '${DB_PASS}',
  'dbhost'        => 'localhost:3306',
  'dbtableprefix' => 'nc_',
  'adminlogin'    => '${ADMIN_USER}',
  'adminpass'     => '${ADMIN_PASS}',
  'directory'     => '/storage'
);" > /home/appbox/public_html/config/autoconfig.php
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
        /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
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

        # Make sure config.php exists
        wait_for_web existing

        read_status
        if version_gap; then
            log "the database ($(stored_version /home/appbox/public_html/config/config.php)) is more than one major version behind the installed code; updates across several major versions are unsupported, so this installation is left unchanged"
        elif [ "$NC_NEEDS_UPGRADE" = 1 ] || [ -f "$INSTALLER_MAINT_MARK" ]; then
            if [ "$NC_MAINTENANCE" = 1 ] && [ ! -f "$INSTALLER_MAINT_MARK" ]; then
                log "maintenance mode was already on and was not set by this installer; leaving it on and not upgrading"
            else
                touch "$INSTALLER_MAINT_MARK"
                finish_installer_maintenance || true
            fi
        else
            log "Nextcloud is up to date; no upgrade needed"
        fi
        read_status
        if [ "$NC_MAINTENANCE" = 0 ] && [ "$NC_NEEDS_UPGRADE" = 0 ]; then
            su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-columns" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction config:app:set files max_chunk_size --value 52428800" -s /bin/sh appbox
        fi
        
        pkill -9 mysql
        pkill -9 nginx
        pkill -9 php
        rm -fr /run/mysqld/mysqld.sock
    else
        /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
        /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
        sleep 10

        while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
        do
            sleep 3
            echo "waiting for mysql ..."
        done

        wait_for_web fresh

        su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction app:update --all" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction app:enable files_external" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:create apps local null::null --config datadir=/APPBOX_DATA/apps/" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:option 1 enable_sharing true" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:create storage local null::null --config datadir=/APPBOX_DATA/storage/" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:option 2 enable_sharing true" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction config:app:set files max_chunk_size --value 52428800" -s /bin/sh appbox
        touch "$INSTALLER_MAINT_MARK"
        finish_installer_maintenance || true

        pkill -9 mysql
        pkill -9 nginx
        pkill -9 php
    fi
fi

/usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
/usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
/usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
sleep 10

while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
do
    sleep 3
    echo "waiting for mysql ..."
done

wait_for_web existing

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

if ! grep -q 'maintenance_window_start' /home/appbox/public_html/config/config.php; then
    # 'maintenance_window_start' => 1,
    # Set maintenance window to a random time of day between 0-6
    RANDOM_TIME=$(shuf -i 0-6 -n 1)
    sed -i "/\$CONFIG/a \ \ 'maintenance_window_start' => $RANDOM_TIME," /home/appbox/public_html/config/config.php
fi

if [ -f "$INSTALLER_MAINT_MARK" ]; then
    if version_gap; then
        log "an earlier installer run did not finish, but the database is more than one major version behind the code; leaving it unchanged"
    else
        log "an earlier installer run did not finish; finishing it"
        finish_installer_maintenance || true
    fi
fi

pkill -9 mysql
pkill -9 nginx
pkill -9 php

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
log "start sequence finished"


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
# echo "apc.enable_cli=1" >> /etc/php/8.3/cli/conf.d/20-apcu.ini
# If end up in an upgrade loop
# delete affected apps from /home/appbox/public_html/apps/
# and restore from a fresh unzipped nextcloud.zip
# upgrade should then complete