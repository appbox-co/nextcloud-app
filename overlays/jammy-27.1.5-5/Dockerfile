# Nextcloud 27.1.5-5: the released 27.1.5-4 image with only its php8.1 packages
# upgraded to Ubuntu's fix for the PHP security release of 19 November 2026.
# Nextcloud, the installer, the configuration and every other package stay
# exactly as in 27.1.5-4; release-gate.sh checks that.
FROM repo.cylo.net/nextcloud@sha256:a43bf62d08d67aa4bf23a7308c73950a4d5ccc8f5064d386b6c8f4624d7fea33

# Release pin: the first Ubuntu jammy php8.1 version with the fixes from the
# PHP security release of 19 November 2026. The build fails unless every
# installed package built from the php8.1 source ends up at one version that is
# at least this one. release-gate.sh reads this line.
ARG PHP81_MIN_VERSION=8.1.2-1ubuntu2.29
LABEL net.cylo.php-min-version="${PHP81_MIN_VERSION}"

# Upgrade only the installed php8.1 packages; keep existing configuration.
RUN --mount=type=bind,source=release/check-php-packages.sh,target=/tmp/check-php-packages.sh \
    set -eux; \
    apt-get update; \
    php_packages=$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${source:Package}\n' \
        | awk -F'|' '$1 ~ /^ii/ && $3 == "php8.1" {print $2}'); \
    test -n "$php_packages"; \
    DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get install -y --no-install-recommends --only-upgrade \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        $php_packages; \
    sh /tmp/check-php-packages.sh php8.1 "$PHP81_MIN_VERSION"; \
    php-fpm8.1 -t; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*
