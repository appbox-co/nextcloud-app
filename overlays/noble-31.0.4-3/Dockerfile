# Nextcloud 31.0.4-3: the released 31.0.4-2 image with a corrected
# /etc/my_init.d/30_installer.sh. Every other file, package and setting stays
# exactly as in 31.0.4-2; release-gate.sh checks that.
#
# The 31.0.4-2 installer ran occ maintenance:repair --include-expensive at
# every container start. Repair puts Nextcloud in maintenance mode while it
# runs, so a start that was cut short (a node restart, a container restart)
# left maintenance mode on. It also ran occ upgrade and repair against
# databases more than one major version behind the code, which can never
# succeed, and it ran under set -x, which printed the appbox password and the
# autoconfig passwords into the container log. The corrected installer
# (30_installer.sh here; release/30_installer.sh.diff is the change):
#   - prints no secrets: no shell tracing, and autoconfig.php is written only
#     for a fresh install;
#   - runs occ upgrade only when Nextcloud needs it, and repair only after an
#     install or an upgrade, under a marker in the persistent logs volume, so
#     an interrupted run is finished at the next start and maintenance mode is
#     turned off only when the upgrade and repair succeed;
#   - leaves maintenance mode it did not set alone;
#   - does not download new code onto, or upgrade, a database more than one
#     major version behind.
FROM repo.cylo.net/nextcloud@sha256:2fbf3f58f6df25fed7f7842e149a7526fea7f1ebe1b388246967f4f09f38a52b

# Release pin carried over from 31.0.4-2 (Ubuntu noble php8.3 with the fixes
# from the PHP security release of 21 October 2026). This overlay does not
# change PHP; the build and release-gate.sh check that the inherited php8.3
# packages still satisfy it.
ARG PHP83_MIN_VERSION=8.3.6-0ubuntu0.24.04.13
LABEL net.cylo.php-min-version="${PHP83_MIN_VERSION}"

# Replace only the installer, and only when the base still has the 31.0.4-2
# installer the fix was written against. cp keeps the file's owner and mode.
RUN --mount=type=bind,source=30_installer.sh,target=/tmp/30_installer.sh \
    --mount=type=bind,source=release/check-php-packages.sh,target=/tmp/check-php-packages.sh \
    set -eu; \
    echo '096302cb94d79a2768c2feb62ec140547f6c6c40ad06040a78078738b371e09f  /etc/my_init.d/30_installer.sh' | sha256sum -c -; \
    bash -n /tmp/30_installer.sh; \
    cp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh; \
    cmp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh; \
    sh /tmp/check-php-packages.sh php8.3 "$PHP83_MIN_VERSION"
