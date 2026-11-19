#!/bin/bash
# Usage (inside the image, as root): perm-pass-check.sh <files>
# Compares the installer's fix_storage_permissions (extracted from
# /etc/my_init.d/30_installer.sh) with the per-file find passes it replaces:
#   1. on a tree that is already correct (every entry 0770 appbox:appbox), the
#      new pass must change nothing and take at most a fifth of the old time;
#   2. on a tree with wrong modes and owners (files, directories, a symbolic
#      link), both passes must leave exactly the same modes and owners, and the
#      wrong entries must end up 0770 appbox:appbox.
# Runs from / with one entry in /APPBOX_DATA/apps, like the installer in an
# Appbox container, so the unquoted -path patterns expand the same way.
set -euo pipefail
files=${1:-20000}
fail() { echo "FAIL: $*" >&2; exit 1; }
installer=/etc/my_init.d/30_installer.sh
sed -n '/^fix_storage_permissions() {/,/^}/p' "$installer" > /tmp/fsp.sh
[ -s /tmp/fsp.sh ] || fail "no fix_storage_permissions() in $installer"
# shellcheck disable=SC1091
. /tmp/fsp.sh
old_pass() {
    find /storage -not \( -path */apps/* -prune \) -not \( -path */apps/ -prune \) -exec chmod 0770 {} \; 2>/dev/null
    find /storage -not \( -path */apps/* -prune \) -not \( -path */apps/ -prune \) -exec chown appbox:appbox {} \; 2>/dev/null
}
mkdir -p /APPBOX_DATA/apps/gate.example /storage
cd /
make_tree() {
    rm -rf /storage/*
    local d i
    for d in $(seq 1 20); do
        mkdir -p "/storage/user/files/d$d"
        for i in $(seq 1 $((files / 20))); do : > "/storage/user/files/d$d/f$i"; done
    done
    chown -R appbox:appbox /storage
    chmod -R 0770 /storage
}
state() { find /storage -printf '%m %u %g %y %p\n' | sort; }

echo "== already-correct tree with $files files"
make_tree
before=$(state)
t0=$(date +%s%N); old_pass; t1=$(date +%s%N)
[ "$(state)" = "$before" ] || fail "the old pass changed a correct tree"
out=$(fix_storage_permissions); t2=$(date +%s%N)
echo "$out"
[ "$(state)" = "$before" ] || fail "the new pass changed a correct tree"
echo "$out" | grep -q 'chmod 0770 on 0 entries, chown appbox:appbox on 0 entries' || fail "the new pass reported changes on a correct tree"
old_ms=$(( (t1 - t0) / 1000000 )); new_ms=$(( (t2 - t1) / 1000000 ))
echo "old pass ${old_ms} ms, new pass ${new_ms} ms"
[ $((new_ms * 5)) -le "$old_ms" ] || fail "the new pass is not at least five times faster (${new_ms} ms vs ${old_ms} ms)"

echo "== tree with wrong modes and owners"
mess() {
    chmod 0600 /storage/user/files/d1/f1; chown root:root /storage/user/files/d1/f1
    chmod 0644 /storage/user/files/d2/f2; chown appbox:root /storage/user/files/d2/f2
    chmod 0700 /storage/user/files/d3; chown root:appbox /storage/user/files/d3
    chmod 0755 /storage/user; chown nobody:nogroup /storage/user/files/d4/f4
    ln -s /storage/user/files/d5/f5 /storage/user/link-to-f5; chown -h root:root /storage/user/link-to-f5
    chown root:root /storage/user/files/d5/f5
}
make_tree; mess; old_pass; old_state=$(state)
make_tree; mess; out=$(fix_storage_permissions); new_state=$(state)
echo "$out"
diff <(echo "$old_state") <(echo "$new_state") || fail "old and new passes leave different modes or owners"
for p in /storage/user/files/d1/f1 /storage/user/files/d2/f2 /storage/user/files/d3 /storage/user /storage/user/files/d4/f4 /storage/user/files/d5/f5; do
    [ "$(stat -c '%a %U %G' "$p")" = "770 appbox appbox" ] || fail "$p is $(stat -c '%a %U %G' "$p") after the pass"
done
echo "$out" | grep -qE 'chmod 0770 on [1-9][0-9]* entries, chown appbox:appbox on [1-9][0-9]* entries' || fail "the new pass did not report its changes"
echo "perm-pass-check passed: correct tree unchanged in ${new_ms} ms (old ${old_ms} ms); wrong entries fixed exactly as before"
