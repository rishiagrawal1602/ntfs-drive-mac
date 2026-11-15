#!/bin/bash
# Mount NTFS partitions read/write via ntfs-3g (macFUSE kernel extension).
# Usage: sudo mount-ntfs.sh [diskXsY ...]     (no args = all external NTFS partitions)
# Env:   NTFS_CLEAN=1 (default) stops macOS writing ._ AppleDouble files / Apple xattrs to the drive.
if [ "$EUID" -ne 0 ]; then echo "Run with: sudo $0"; exit 1; fi
NTFS3G=/opt/homebrew/bin/ntfs-3g
[ -x "$NTFS3G" ] || NTFS3G=/usr/local/bin/ntfs-3g
[ -x "$NTFS3G" ] || { echo "FAILED: ntfs-3g not found. Install: brew install gromgit/fuse/ntfs-3g-mac"; exit 1; }
USER_ID=$(stat -f %u /dev/console)
CLEAN_OPTS=()
[ "${NTFS_CLEAN:-1}" = "1" ] && CLEAN_OPTS=(-o noappledouble -o noapplexattr)
if [ $# -gt 0 ]; then parts="$*"; else
  parts=$(diskutil list external | awk '/Windows_NTFS|Microsoft Basic Data/ {print $NF}')
fi
[ -z "$parts" ] && { echo "No external NTFS partitions found."; exit 1; }
for p in $parts; do
  [[ "$p" =~ ^disk[0-9]+s[0-9]+$ ]] || { echo "==> $p: invalid partition id"; continue; }
  dev=/dev/$p
  name=$(diskutil info "$p" | awk -F': *' '/Volume Name/ {print $2}')
  [ -z "$name" ] && name="NTFS-$p"
  mp="/Volumes/$name"
  echo "==> $p -> $mp"
  if mount | grep -q "^$dev on .*(macfuse"; then echo "    already mounted"; continue; fi
  diskutil unmount "$dev" >/dev/null 2>&1
  mkdir -p "$mp"
  # ntfs-3g daemonizes itself after a successful mount (setsid), so it survives
  # the Terminal window closing or the app quitting. No nohup needed.
  "$NTFS3G" "$dev" "$mp" -o local -o allow_other -o auto_xattr -o auto_cache \
    "${CLEAN_OPTS[@]}" -o volname="$name" -o uid=$USER_ID -o gid=20 \
    >"/tmp/ntfs-3g-$p.log" 2>&1 </dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do mount | grep -q "^$dev on .*(macfuse" && break; sleep 1; done
  if mount | grep -q "^$dev on .*(macfuse"; then
    echo "    mounted read/write"
  else
    echo "    FAILED:"; cat "/tmp/ntfs-3g-$p.log"; rmdir "$mp" 2>/dev/null
    diskutil mount "$p" >/dev/null 2>&1   # fall back to read-only so the drive stays usable
  fi
done
