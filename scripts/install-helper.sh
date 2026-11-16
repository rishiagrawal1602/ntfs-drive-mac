#!/bin/bash
# One-time setup for password-free mounting.
# Usage: sudo install-helper.sh <username> <source-dir-with-scripts>
#
# - Copies mount-ntfs.sh / eject-ntfs.sh to a root-owned folder (users can't modify them).
# - Adds /etc/sudoers.d/ntfs-drive allowing ONLY <username> to run ONLY those two scripts
#   as root without a password. Validated with visudo before it's installed.
# Undo with uninstall-helper.sh (or the app's menu).
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }
U="${1:-}"; SRC="${2:-}"
[[ "$U" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] && id "$U" >/dev/null 2>&1 || { echo "Invalid user: $U"; exit 1; }
[ -f "$SRC/mount-ntfs.sh" ] && [ -f "$SRC/eject-ntfs.sh" ] || { echo "Scripts not found in $SRC"; exit 1; }

DEST=/Library/PrivilegedHelperTools/com.local.ntfsdrive
mkdir -p "$DEST"
chown root:wheel /Library/PrivilegedHelperTools "$DEST"
chmod 755 "$DEST"
install -o root -g wheel -m 755 "$SRC/mount-ntfs.sh" "$DEST/mount-ntfs.sh"
install -o root -g wheel -m 755 "$SRC/eject-ntfs.sh" "$DEST/eject-ntfs.sh"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# Installed by NTFS Drive.app: password-free NTFS mount/eject for $U.
# Remove with: sudo rm /etc/sudoers.d/ntfs-drive
$U ALL=(root) NOPASSWD: $DEST/mount-ntfs.sh, $DEST/eject-ntfs.sh
EOF
visudo -cf "$TMP" >/dev/null
install -o root -g wheel -m 440 "$TMP" /etc/sudoers.d/ntfs-drive
visudo -c >/dev/null
echo "Password-free mounting enabled for $U."
