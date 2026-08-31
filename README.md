# Wipeout

<table>
<tr>
<td valign="middle">
<img src="icon/app.png" width="180" alt="Wipeout">
</td>
<td valign="middle">

macOS GUI for wiping a USB stick, SD card, or external NVMe back to a single full-size partition — including drives written by Rufus, Ventoy, dd, or any Linux tool that leaves partitions macOS refuses to touch. Replaces the diskpart-on-Windows workflow.

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
