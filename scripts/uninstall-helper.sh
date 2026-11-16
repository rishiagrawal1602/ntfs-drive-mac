#!/bin/bash
# Turn off password-free mounting: removes the sudoers rule and the root-owned script copies.
# Usage: sudo uninstall-helper.sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }
rm -f /etc/sudoers.d/ntfs-drive
rm -rf /Library/PrivilegedHelperTools/com.local.ntfsdrive
echo "Password-free mounting disabled."
