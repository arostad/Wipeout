# Wipeout

<img src="icon/app.png" width="180" align="left" alt="Wipeout">

If a drive shows up smaller than it should after erasing it in the macOS Disk Utility, it's usually because of a partition Disk Utility can't see. This tool wipes a USB stick, SD card, or any non-system drive back to one full-size partition with the file system of your choosing without having to dive into terminal commands. I built this tool for my own workflow, but if it's useful to anyone else, all the better.

App created by [Andy Rostad](https://github.com/arostad).  Released under the [MIT License](https://github.com/arostad/Wipeout/blob/main/LICENSE).

<br clear="all">

## Features

- **Common filesystems** — ExFAT, FAT32, Mac OS Extended (Journaled), and APFS.
- **UEFI shell sticks** — Formats FAT32 and stages `EFI/BOOT/BOOTX64.EFI` plus an `Update/` folder for BIOS payloads. Secure Boot usually needs to be off.
- **Deep wipe** — Optionally zeros the disk before formatting.
- **Dry run** — Prints the full plan without touching the disk.
- **No password prompt** — Runs as you. macOS only asks for an administrator password if a drive actually needs it.
- **Live console** — Plain-English steps, color-coded by severity, with the raw `diskutil` output a click away.
- **Eject when done** — After a successful format, the button turns into Eject.
- **Built-in safeguards** — Blocks the Mac's boot disk and hides other internal disks unless you opt in.
- **Clean volume labels** — Sanitizes the label for the selected filesystem.

## Download

[**Download Wipeout.zip**](https://github.com/arostad/Wipeout/releases/download/latest/Wipeout.app.zip)

Apple Silicon only. GitHub Actions rebuilds this download on every push to `main`. Unzip to get `Wipeout.app`.

> Wipeout destroys the selected disk. The Mac's boot disk is blocked.
