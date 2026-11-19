# Nextcloud 27.1.5-4: repo.cylo.net/nextcloud:27.1.5-3 with a faster storage
# permission pass in /etc/my_init.d/30_installer.sh. The pass (mode 0770,
# owner appbox:appbox for everything under /storage) started chmod and chown
# once per file before nginx starts, which kept large installations offline
# for hours on every update. 27.1.5-4 changes only the entries that are not
# already right, in batches, with the same targets, and still before nginx.
# Packages, configuration and every other file stay exactly as in 27.1.5-3;
# release-gate.sh checks that.
FROM repo.cylo.net/nextcloud@sha256:075a797222bb9a992d739ab6ff147e57372924f13c0d98932093dbdec1df3910

# Replace only the installer, and only when the base still has the installer
# the change was written against. cp keeps the file's owner and mode.
RUN --mount=type=bind,source=30_installer.sh,target=/tmp/30_installer.sh \
    set -eu; \
    echo 'cd4dbc9ff75e7ff55f519efd0a21cef48f0143202f461979c2826a25ab236439  /etc/my_init.d/30_installer.sh' | sha256sum -c -; \
    bash -n /tmp/30_installer.sh; \
    cp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh; \
    cmp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh
