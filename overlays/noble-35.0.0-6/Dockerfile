# Nextcloud 35.0.0-6: the released 35.0.0-5 image (PHP 8.4 from the ondrej/php
# PPA, Redis, MySQL 8.4) with only its installed php8.4 packages replaced by
# our rebuild of the PPA's php8.4 8.4.28-2+ubuntu24.04.1+deb.sury.org+1 source
# package (repo.cylo.net/php-artifacts:sury-php8.4-8.4.28-noble, pinned by
# digest), for the PHP security release of 19 November 2026. The PPA had
# published the source but not the binaries. Nextcloud, nginx, MySQL, Redis,
# the my_init scripts and the configuration stay as in 35.0.0-5;
# release-gate.sh checks every package and file this overlay changes.
FROM repo.cylo.net/php-artifacts@sha256:2523b152432ee16ba6d9418aeaa0cafcc7e3ba97fccfb3aed46c5a73e2b2f8d0 AS php-artifacts

FROM repo.cylo.net/nextcloud@sha256:7f6f0473f114bba2f5b8d0d57db25002722e0fa45f0389fb281e4b557bcde56a

# Release pin: every installed package built from the php8.4 source must end
# up at exactly this version. release-gate.sh reads this line.
ARG PHP84_MIN_VERSION=8.4.28-2+ubuntu24.04.1+deb.sury.org+1
ARG PHP_SOURCE_PACKAGE=php8.4
# MySQL 8.4 is inherited unchanged from 35.0.0-5 (installed at
# 8.4.13-1ubuntu24.04 there); release-gate.sh checks the installed packages
# against this minimum.
ARG MYSQL84_MIN_VERSION=8.4.13-1ubuntu24.04
LABEL net.cylo.php-min-version="${PHP84_MIN_VERSION}" \
      net.cylo.php-artifacts="repo.cylo.net/php-artifacts@sha256:2523b152432ee16ba6d9418aeaa0cafcc7e3ba97fccfb3aed46c5a73e2b2f8d0"

# Install exactly the php8.4 packages the image already has, at the artifact
# version, keeping the deployed configuration: dpkg keeps locally modified
# conffiles (--force-confold) and ucf keeps modified php.ini files
# (UCF_FORCE_CONFFOLD=1); conffiles whose packaged default changed are put
# back to the deployed content. The PHP conf.d links must not change. No apt
# index or network is used. --force-unsafe-io only skips dpkg's per-file
# fsync while the layer is built.
RUN --mount=type=bind,from=php-artifacts,source=/debs,target=/tmp/php-debs \
    set -eu; \
    cd /tmp/php-debs; \
    sha256sum -c --quiet SHA256SUMS; \
    pkgs=$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${source:Package}\n' \
        | awk -F'|' -v src="$PHP_SOURCE_PACKAGE" '$1 ~ /^ii/ && $3 == src {print $2}' | sort); \
    [ -n "$pkgs" ]; \
    files=""; \
    for pkg in $pkgs; do \
        arch=$(dpkg-query -W -f='${Architecture}' "$pkg"); \
        file="/tmp/php-debs/${pkg}_${PHP84_MIN_VERSION}_${arch}.deb"; \
        [ -f "$file" ] || { echo "no artifact deb for $pkg ($file)" >&2; exit 1; }; \
        files="$files $file"; \
    done; \
    for sapi in cli fpm; do \
        [ -d "/etc/php/8.4/$sapi/conf.d" ] && ls -1 "/etc/php/8.4/$sapi/conf.d" > "/tmp/confd-$sapi.before" || true; \
    done; \
    conffiles=$(dpkg-query -W -f='${Conffiles}\n' $pkgs | awk '$1 ~ /^\// && $NF != "obsolete" {print $1}' | sort -u); \
    mkdir -p /tmp/conffiles-before; \
    for f in $conffiles; do if [ -f "$f" ]; then cp -a --parents "$f" /tmp/conffiles-before/; fi; done; \
    DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 \
        dpkg -i --force-confold --force-confdef --force-unsafe-io $files; \
    for f in $conffiles; do \
        [ -f "/tmp/conffiles-before$f" ] || continue; \
        if ! cmp -s "/tmp/conffiles-before$f" "$f"; then \
            cp -a "/tmp/conffiles-before$f" "$f"; echo "kept the deployed $f"; \
        fi; \
        rm -f "$f.dpkg-dist"; \
    done; \
    rm -rf /tmp/conffiles-before; \
    for sapi in cli fpm; do \
        [ -f "/tmp/confd-$sapi.before" ] || continue; \
        ls -1 "/etc/php/8.4/$sapi/conf.d" | diff -u "/tmp/confd-$sapi.before" - \
            || { echo "the upgrade changed /etc/php/8.4/$sapi/conf.d" >&2; exit 1; }; \
        rm -f "/tmp/confd-$sapi.before"; \
    done; \
    [ -z "$(dpkg -C)" ] || { dpkg -C; exit 1; }; \
    for pkg in $pkgs; do \
        version=$(dpkg-query -W -f='${Version}' "$pkg"); \
        [ "$version" = "$PHP84_MIN_VERSION" ] || { echo "$pkg is $version, not $PHP84_MIN_VERSION" >&2; exit 1; }; \
    done; \
    if dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | grep -qE '^ii +php8\.(3|5)'; then \
        echo "php8.3 or php8.5 packages are installed" >&2; exit 1; \
    fi; \
    [ "$(readlink -f /usr/bin/php)" = /usr/bin/php8.4 ]; \
    php-fpm8.4 -t
