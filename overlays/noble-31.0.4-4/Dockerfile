# Nextcloud 31.0.4-4: the released 31.0.4-3 image with two corrections in
# /etc/my_init.d/30_installer.sh. Every other file, package and setting stays
# exactly as in 31.0.4-3; release-gate.sh checks that.
#
# 31.0.4-3 waited at start for index.php to answer 200, a redirect, 401, 403
# or 503. Installations whose code is several major versions ahead of their
# database answer 500, so their containers waited forever and never finished
# starting (the update stayed "updating"). 31.0.4-4 accepts any answer from
# PHP for an existing installation; only no answer, 502 and 504 mean nginx or
# php-fpm is not ready.
#
# The storage permission pass (mode 0770, owner appbox:appbox for everything
# under /storage) started chmod and chown once per file, which kept large
# installations offline for hours on every update. 31.0.4-4 changes only the
# entries that are not already right, in batches, with the same targets; it
# still runs before nginx starts. release/30_installer.sh.diff is the change.
FROM repo.cylo.net/nextcloud@sha256:2532811b97ef36cb7b92df6678c929f0a35819807ff56593b1e879f213f9c9de

# Release pin carried over from 31.0.4-3 and 31.0.4-2 (Ubuntu noble php8.3 with the fixes
# from the PHP security release of 21 October 2026). This overlay does not
# change PHP; the build and release-gate.sh check that the inherited php8.3
# packages still satisfy it.
ARG PHP83_MIN_VERSION=8.3.6-0ubuntu0.24.04.13
LABEL net.cylo.php-min-version="${PHP83_MIN_VERSION}"

# Replace only the installer, and only when the base still has the 31.0.4-3
# installer the fix was written against. cp keeps the file's owner and mode.
RUN --mount=type=bind,source=30_installer.sh,target=/tmp/30_installer.sh \
    --mount=type=bind,source=release/check-php-packages.sh,target=/tmp/check-php-packages.sh \
    set -eu; \
    echo '3246c9e0a0172e7840c3ead27b35b00bb921844fc91b201f845c2db23700efd1  /etc/my_init.d/30_installer.sh' | sha256sum -c -; \
    bash -n /tmp/30_installer.sh; \
    cp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh; \
    cmp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh; \
    sh /tmp/check-php-packages.sh php8.3 "$PHP83_MIN_VERSION"
