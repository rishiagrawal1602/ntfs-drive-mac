#!/bin/bash
# Remount all external NTFS partitions with read/write via ntfs-3g (macFUSE kernel extension).
# Usage: sudo ~/mount-ntfs.sh
if [ "$EUID" -ne 0 ]; then echo "Run with: sudo $0"; exit 1; fi
NTFS3G=/opt/homebrew/bin/ntfs-3g
USER_ID=$(stat -f %u /dev/console)
parts=$(diskutil list external | awk '/Windows_NTFS|Microsoft Basic Data/ {print $NF}')
[ -z "$parts" ] && { echo "No external NTFS partitions found."; exit 1; }
for p in $parts; do
  dev=/dev/$p
  name=$(diskutil info "$p" | awk -F': *' '/Volume Name/ {print $2}')
  [ -z "$name" ] && name="NTFS-$p"
  mp="/Volumes/$name"
  echo "==> $p -> $mp"
  if mount | grep -q "on $mp "; then echo "    already mounted"; continue; fi
  diskutil unmount "$dev" >/dev/null 2>&1
  mkdir -p "$mp"
  # ntfs-3g daemonizes itself after a successful mount (setsid), so it survives
  # the Terminal window closing or the app quitting. No nohup needed.
  "$NTFS3G" "$dev" "$mp" -o local -o allow_other -o auto_xattr \
    -o auto_cache -o volname="$name" -o uid=$USER_ID -o gid=20 \
    >"/tmp/ntfs-3g-$p.log" 2>&1 </dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do mount | grep -q "on $mp " && break; sleep 1; done
  if mount | grep -q "on $mp "; then
    echo "    mounted read/write"
  else
    echo "    FAILED:"; cat "/tmp/ntfs-3g-$p.log"; rmdir "$mp" 2>/dev/null
    diskutil mount "$p" >/dev/null 2>&1   # fall back to read-only so the drive stays usable
  fi
done
