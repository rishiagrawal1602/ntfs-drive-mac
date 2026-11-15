# NTFS Drive for Mac

A tiny, free macOS app to **mount NTFS drives with read/write access** and **eject them safely**, as an alternative to paid tools like Tuxera or Paragon.

It's a native **menu bar app** built on [macFUSE](https://macfuse.github.io/) and [ntfs-3g](https://github.com/tuxera/ntfs-3g). Plug in your drive and it becomes writable.

<p align="center"><img src="icon/icon_1024.png" width="160" alt="NTFS Drive icon"></p>

> Tested on an Apple Silicon Mac with macOS 26 (Tahoe), macFUSE 5.5.0, and ntfs-3g-mac 2026.9.28. Requires macOS 13 or later; universal binary (Apple Silicon + Intel).

## Features
- **Menu bar app:** a four-pane icon in the menu bar lists every NTFS partition with its size, free space and a ✅ Read/Write or 🔒 Read-only badge. Each partition offers Open in Finder, Mount and Eject
- **Auto-mount on plug-in:** NTFS drives are switched to read/write automatically when you connect them (toggle in the menu)
- **Keeps Windows drives clean:** mounts with `noappledouble` + `noapplexattr`, so macOS doesn't litter the drive with `._*` and `.DS_Store` files (toggle in the menu)
- **Notifications:** "Drive ready for writing", "Safe to unplug", and if a drive is busy, **which apps are using it**
- **Helpful errors:** plain-language guidance for hibernated Windows drives and blocked disk access
- **Safe:** falls back to read-only if a mount fails, and ejects only disks that hold NTFS partitions
- **Launch at login** (toggle in the menu)
- Mounts keep running after you quit the app (ntfs-3g runs in the background on its own)

## 1. Install dependencies
```bash
brew install --cask macfuse
brew tap gromgit/homebrew-fuse
brew install gromgit/fuse/ntfs-3g-mac
```

## 2. Allow the macFUSE kernel extension (Apple Silicon, one-time)
The macFUSE **FSKit** backend doesn't work for ntfs-3g block-device mounts (they need root, and the FSKit extension is enabled per user, so you get `File system extension not found`). Use the kernel extension instead:

1. Shut down. Hold the power button until **Loading startup options** appears, then choose **Options**.
2. **Utilities → Startup Security Utility →** your disk **→ Security Policy…**
3. Choose **Reduced Security** and tick **Allow user management of kernel extensions from identified developers**. Restart.
4. Try a mount once (step 4). Then go to **System Settings → Privacy & Security**, click **Allow** next to *Benjamin Fleischer* (macFUSE), and restart.

## 3. Build the app
Needs only the Xcode Command Line Tools (`xcode-select --install`); no Xcode project.
```bash
git clone https://github.com/rishiagrawal1602/ntfs-drive-mac.git
cd ntfs-drive-mac
./build.sh            # installs to /Applications/NTFS Drive.app
# ./build.sh ./build  # or build somewhere else
```

## 4. Use it
Open **NTFS Drive**. It runs in the menu bar (there's no Dock icon).
- Plug in a drive. With **Auto-mount** on, you're asked for your password and the drive becomes read/write.
- Or click the menu bar icon and choose **Mount All Read/Write**, or pick one partition → **Mount Read/Write**.
- Before unplugging: **Eject All**, or pick one partition → **Eject Disk**. Wait for the **Safe to unplug** notification.
- Turn on **Launch at login** so it's always ready.

The first time you open it, right-click → **Open** (the app is ad-hoc signed). Allow notifications when asked.

The scripts also work without the app:
```bash
sudo scripts/mount-ntfs.sh            # all NTFS partitions (or pass e.g. disk4s1)
sudo scripts/eject-ntfs.sh            # all NTFS disks (or pass e.g. disk4)
sudo NTFS_CLEAN=0 scripts/mount-ntfs.sh      # allow macOS ._ files
```

To see what the app detects: `"/Applications/NTFS Drive.app/Contents/MacOS/NTFSDrive" --scan`

## Troubleshooting
| Message | Fix |
|---|---|
| `Operation not permitted` / "macOS blocked disk access" | System Settings → Privacy & Security → **Full Disk Access** → add **NTFS Drive** (or Terminal) |
| `unsafe state` / hibernated | Windows didn't shut down cleanly. In Windows, hold **Shift** while clicking Shut Down, or disable Fast Startup |
| `File system extension not found` | You're on the FSKit backend; follow step 2 to use the kernel extension |
| No **Allow** button in Privacy & Security | Try a mount first (that triggers the prompt), and make sure step 2 is done |
| "Drive is in use by: …" | Close files open from the drive in those apps, then eject again |
| No notifications | System Settings → Notifications → **NTFS Drive** → Allow |

## Project layout
```
src/NTFSDrive.swift         menu bar app (AppKit + DiskArbitration auto-mount + notifications)
scripts/mount-ntfs.sh       mounts NTFS partitions read/write with ntfs-3g
scripts/eject-ntfs.sh       unmounts and ejects NTFS disks, reports apps keeping them busy
icon/                       app icon (.icns), preview PNG, and the Python script that draws it
build.sh                    compiles (universal), packages and signs "NTFS Drive.app"
```

## Roadmap
- Enter your password once instead of on every mount (privileged helper)
- Custom names for partitions
- Detect and help fix hibernated or not-cleanly-closed drives
- Setup wizard that checks macFUSE, ntfs-3g, kernel extension approval and Full Disk Access
- Downloadable `.dmg` release / Homebrew cask

## Disclaimer
Writing to NTFS from macOS through ntfs-3g is widely used but not officially supported by Apple or Microsoft. Back up important data. Always eject before unplugging.
The icon is an original design and isn't affiliated with Microsoft.

## License
MIT
