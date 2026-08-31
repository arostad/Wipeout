# Wipeout

<table>
<tr>
<td valign="middle">
<img src="icon/app.png" width="180" alt="Wipeout">
</td>
<td valign="middle">

If the macOS Disk Utility won't fully erase a drive, it's usually because there's a partition on it that Disk Utility can't see. This tool wipes a USB stick, SD card, or non-system drive back to one full-size partition with the file system of your choosing without having to dive into terminal commands. I built it for my own use, but if it's useful to anyone else, all the better.

App carefully directed by [Andy Rostad](https://github.com/arostad).  Released under the [MIT License](https://github.com/arostad/Wipeout/blob/main/LICENSE).

</td>
</tr>
</table>

## Features

- **Common filesystems** — ExFAT, FAT32, Mac OS Extended (Journaled), and APFS.
- **UEFI shell sticks** — Formats FAT32 and stages `EFI/BOOT/BOOTX64.EFI` plus an `Update/` folder for BIOS payloads. Secure Boot usually needs to be off.
- **Deep wipe** — Optionally zeros the disk before formatting.
- **Dry run** — Prints the full plan without touching the disk.
- **Live console** — Shows what ran and its output.
- **Built-in safeguards** — Blocks the Mac's boot disk and hides other internal disks unless you opt in.
- **Clean volume labels** — Sanitizes the label for the selected filesystem.

## Download

[**Download Wipeout.app.zip**](https://github.com/arostad/Wipeout/releases/download/latest/Wipeout.app.zip)

Apple Silicon only. GitHub Actions rebuilds this download on every push to `main`. Unzip to get `Wipeout.app`.

> Wipeout destroys the selected disk. The Mac's boot disk is blocked.
