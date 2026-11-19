#!/bin/sh
# Recreate the runtime directories under /run at every container start.
#
# Appbox mounts a fresh tmpfs on /run in each container, so anything created
# there by the image or an earlier start is gone after a restart. Without these
# directories php-fpm8.1 cannot bind /run/php/php8.1-fpm.sock, mysqld (run as
# appbox) cannot create /run/mysqld/mysqld.sock, sshd refuses to start, and the
# installer's upgrade waits for mysqld forever. The 31.0.4-2 and 35.0.0 images
# create the same directories at the top of their installer.
set -eu

install -d -m 0755 -o appbox -g appbox /run/php /run/mysqld
install -d -m 0755 -o root -g root /run/sshd
