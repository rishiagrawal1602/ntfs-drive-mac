#!/bin/bash
# Mount NTFS partitions read/write via ntfs-3g (macFUSE kernel extension).
#
# Usage: sudo mount-ntfs.sh [--clean|--no-clean] [diskXsY[:Name] ...]
#   no partitions given  -> all external NTFS partitions
#   diskXsY:Name         -> mount with a custom Finder name
#   --clean (default)    -> stop macOS writing ._ AppleDouble files / Apple xattrs to the drive
#
# This script may be allowed to run as root WITHOUT a password (see install-helper.sh),
# so every input is validated strictly.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [ "$EUID" -ne 0 ]; then echo "Run with: sudo $0"; exit 1; fi

NTFS3G=/opt/homebrew/bin/ntfs-3g
[ -x "$NTFS3G" ] || NTFS3G=/usr/local/bin/ntfs-3g
[ -x "$NTFS3G" ] || { echo "FAILED: ntfs-3g not found. Install: brew install gromgit/fuse/ntfs-3g-mac"; exit 1; }
USER_ID=$(stat -f %u /dev/console)
[[ "$USER_ID" =~ ^[0-9]+$ ]] || USER_ID=0

# Turn any string into a safe single path component (no '/', no leading dots, <= 32 chars).
sanitize() {
  local n
  n=$(printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9 _.-' | cut -c1-32)
  while [[ "$n" == .* ]]; do n="${n#.}"; done
  n="${n%"${n##*[! ]}"}"   # trim trailing spaces
  printf '%s' "$n"
}

CLEAN=1
[ "${NTFS_CLEAN:-1}" = "0" ] && CLEAN=0   # manual use: sudo NTFS_CLEAN=0 mount-ntfs.sh
args=()
for a in "$@"; do
  case "$a" in
    --clean) CLEAN=1 ;;
    --no-clean) CLEAN=0 ;;
    -*) echo "Unknown option: $a"; exit 1 ;;
    *) args+=("$a") ;;
  esac
done
CLEAN_OPTS=()
[ "$CLEAN" = 1 ] && CLEAN_OPTS=(-o noappledouble -o noapplexattr)

if [ ${#args[@]} -eq 0 ]; then
  while read -r p; do [ -n "$p" ] && args+=("$p"); done \
    < <(diskutil list external | awk '/Windows_NTFS|Microsoft Basic Data/ {print $NF}')
fi
[ ${#args[@]} -eq 0 ] && { echo "No external NTFS partitions found."; exit 1; }

for a in "${args[@]}"; do
  p="${a%%:*}"
  custom=""
  [[ "$a" == *:* ]] && custom="${a#*:}"
  [[ "$p" =~ ^disk[0-9]+s[0-9]+$ ]] || { echo "==> $p: invalid partition id"; continue; }
  dev=/dev/$p
  # Only touch external NTFS partitions.
  info=$(diskutil info "$p" 2>/dev/null)
  if ! grep -qE "Device Location: +External|Removable Media: +(Removable|Yes)|Protocol: +USB" <<<"$info" \
     || ! grep -qiE "Partition Type: +(Windows_NTFS|Microsoft Basic Data)|Type \(Bundle\): +ntfs|File System Personality: +NTFS" <<<"$info"; then
    echo "==> $p: not an external NTFS partition, skipped"; continue
  fi
  name=$(sanitize "$custom")
  [ -z "$name" ] && name=$(sanitize "$(awk -F': *' '/Volume Name/ {print $2}' <<<"$info")")
  [ -z "$name" ] && name="NTFS-$p"
  mp="/Volumes/$name"
  echo "==> $p -> $mp"
  if mount | grep -q "^$dev on .*(macfuse"; then echo "    already mounted"; continue; fi
  # Never mount over a folder some other volume is already using.
  if mount | grep -q " on $mp ("; then mp="/Volumes/$name-$p"; fi
  diskutil unmount "$dev" >/dev/null 2>&1
  [ -L "$mp" ] && { echo "    FAILED: $mp is a symlink"; continue; }
  mkdir -p "$mp"
  # ntfs-3g daemonizes itself after a successful mount (setsid), so it survives
  # the Terminal window closing or the app quitting. No nohup needed.
  "$NTFS3G" "$dev" "$mp" -o local -o allow_other -o auto_xattr -o auto_cache \
    "${CLEAN_OPTS[@]}" -o volname="$name" -o uid="$USER_ID" -o gid=20 \
    >"/tmp/ntfs-3g-$p.log" 2>&1 </dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do mount | grep -q "^$dev on .*(macfuse" && break; sleep 1; done
  if mount | grep -q "^$dev on .*(macfuse"; then
    echo "    mounted read/write"
  else
    echo "    FAILED:"; cat "/tmp/ntfs-3g-$p.log"; rmdir "$mp" 2>/dev/null
    diskutil mount "$p" >/dev/null 2>&1   # fall back to read-only so the drive stays usable
  fi
done
