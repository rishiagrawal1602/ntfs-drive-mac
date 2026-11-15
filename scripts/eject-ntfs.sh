#!/bin/bash
# Safely unmount all NTFS partitions and eject only the disks that hold them.
parts=$(diskutil list external | awk '/Windows_NTFS|Microsoft Basic Data/ {print $NF}')
[ -z "$parts" ] && { echo "No NTFS drive connected."; exit 0; }
for p in $parts; do
  diskutil unmount "/dev/$p" >/dev/null 2>&1 || umount "/dev/$p" >/dev/null 2>&1
done
sleep 1
for d in $(diskutil list external | awk '/^\/dev\/disk/ {print $1}'); do
  if diskutil list "$d" | grep -qE "Windows_NTFS|Microsoft Basic Data"; then
    diskutil eject "$d" >/dev/null 2>&1 && echo "Ejected $d - safe to unplug." || echo "Could not eject $d - close any open files on it and try again."
  fi
done
rmdir /Volumes/NTFS-* 2>/dev/null
exit 0
