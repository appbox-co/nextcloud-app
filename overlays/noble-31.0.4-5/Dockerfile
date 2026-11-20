# Nextcloud 31.0.4-5: the released 31.0.4-4 image with only its php8.3 packages
# upgraded to Ubuntu's fix for the PHP security release of 19 November 2026.
# Nextcloud, the installer, the configuration and every other package stay
# exactly as in 31.0.4-4; release-gate.sh checks that.
FROM repo.cylo.net/nextcloud@sha256:80dfe93dd5baa2cef72fcda1747aafcae8579e269d61746265dded1298bf9964

# Release pin: the first Ubuntu noble php8.3 version with the fixes from the
# PHP security release of 19 November 2026. The build fails unless every
# installed package built from the php8.3 source ends up at one version that is
# at least this one. release-gate.sh reads this line.
ARG PHP83_MIN_VERSION=8.3.6-0ubuntu0.24.04.14
LABEL net.cylo.php-min-version="${PHP83_MIN_VERSION}"

# Upgrade only the installed php8.3 packages; keep existing configuration.
RUN --mount=type=bind,source=release/check-php-packages.sh,target=/tmp/check-php-packages.sh \
    set -eux; \
    apt-get update; \
    php_packages=$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${source:Package}\n' \
        | awk -F'|' '$1 ~ /^ii/ && $3 == "php8.3" {print $2}'); \
    test -n "$php_packages"; \
    DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get install -y --no-install-recommends --only-upgrade \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        $php_packages; \
    sh /tmp/check-php-packages.sh php8.3 "$PHP83_MIN_VERSION"; \
    php-fpm8.3 -t; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*
