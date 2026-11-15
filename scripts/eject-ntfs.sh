#!/bin/bash
# Unmount NTFS partitions and eject only the physical disks that hold them.
# Usage: sudo eject-ntfs.sh [diskN ...]     (no args = every external disk with NTFS partitions)
if [ $# -gt 0 ]; then disks="$*"; else
  disks=$(for d in $(diskutil list external | awk '/^\/dev\/disk/ {print $1}'); do
            diskutil list "$d" | grep -qE "Windows_NTFS|Microsoft Basic Data" && basename "$d"; done)
fi
[ -z "$disks" ] && { echo "No NTFS drive connected."; exit 0; }
status=0
for d in $disks; do
  d=$(basename "$d")
  [[ "$d" =~ ^disk[0-9]+$ ]] || { echo "$d: invalid disk id"; continue; }
  busy=0
  for p in $(diskutil list "$d" | awk '/Windows_NTFS|Microsoft Basic Data/ {print $NF}'); do
    mp=$(mount | awk -v dev="/dev/$p" '$1==dev' | sed -E 's/^.* on (.*) \(.*$/\1/')
    [ -z "$mp" ] && continue
    if ! diskutil unmount "/dev/$p" >/dev/null 2>&1 && ! umount "/dev/$p" >/dev/null 2>&1; then
      apps=$(lsof -Fc "$mp" 2>/dev/null | sed -n 's/^c//p' | sort -u | paste -sd, - | sed 's/,/, /g')
      echo "BUSY: $mp is in use${apps:+ by: $apps}. Close those files and try again."
      busy=1; status=1
    fi
  done
  [ $busy = 1 ] && continue
  if diskutil eject "$d" >/dev/null 2>&1; then echo "Ejected $d - safe to unplug."
  else echo "Could not eject $d - close any open files on it and try again."; status=1; fi
done
rmdir /Volumes/NTFS-* 2>/dev/null
exit $status
