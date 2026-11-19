# Nextcloud 27.1.5-3: repo.cylo.net/nextcloud:27.1.5-2 with its installer
# (/etc/my_init.d/30_installer.sh) no longer running under set -x, which
# printed autoconfig.php, including the Nextcloud admin and database
# passwords, into the container log. Packages, configuration and every other
# file stay exactly as in 27.1.5-2; release-gate.sh checks that.
FROM repo.cylo.net/nextcloud@sha256:8b47040592cb24bcee764025bdff0674d15ed300c11c7e91a81fbe462092f3a8

# Replace only the installer, and only when the base still has the installer
# the change was written against. cp keeps the file's owner and mode.
RUN --mount=type=bind,source=30_installer.sh,target=/tmp/30_installer.sh \
    set -eu; \
    echo '4ff6ed5a04c0e653c02774b0ccea54a59db1bb60bc56e9d4abe2c819197aa7d7  /etc/my_init.d/30_installer.sh' | sha256sum -c -; \
    bash -n /tmp/30_installer.sh; \
    cp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh; \
    cmp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh
