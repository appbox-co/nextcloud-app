# Nextcloud 27.1.5-2: repo.cylo.net/nextcloud:27.1.5-1 plus a startup script
# that recreates /run/php, /run/mysqld and /run/sshd at every container start.
# Appbox gives each container a fresh tmpfs on /run, and 27.1.5-1 only had
# those directories from the image build, so after a restart php-fpm8.1 and
# mysqld could not create their sockets and Nextcloud returned 502.
# Packages, installer and configuration stay exactly as in 27.1.5-1;
# release-gate.sh checks that.
FROM repo.cylo.net/nextcloud@sha256:9de39c1b3f81fae18f3067766d4b77e01e581367449fba0c409a0d526568208a

COPY --chmod=0755 05_runtime_dirs.sh /etc/my_init.d/05_runtime_dirs.sh
