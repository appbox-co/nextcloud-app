# Nextcloud 35.0.0-7: the released 35.0.0-6 image with only
# /etc/my_init.d/30_installer.sh replaced. The new installer writes
# autoconfig.php with PHP's var_export from the environment, so an admin
# password with ', ", \ or $ installs correctly, checks the HTTP status of
# index.php and occ's installed state instead of grepping for '200', and fails
# closed: a setup that did not finish sends no installed callback, leaves no
# /etc/app_installer_completed and runs again at the next start.
# Packages, Nextcloud, the other my_init scripts and the configuration stay
# exactly as in 35.0.0-6; release-gate.sh checks that.
FROM repo.cylo.net/nextcloud@sha256:0e6329de457ffa6e9997d2c6939817bfcbeb99157080bc88475b30b7d2370732

COPY --chmod=0775 30_installer.sh /etc/my_init.d/30_installer.sh
