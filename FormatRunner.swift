import Foundation

// MARK: - Filesystem choices

enum FSChoice: String, CaseIterable, Identifiable {
    case exfat
    case fat32
    case hfsPlus
    case apfs
    case uefiShell

    var id: String { rawValue }

    /// Label shown in the picker.
    var title: String {
        switch self {
        case .exfat:   return "ExFAT — MBR (Windows / macOS / Linux, >32 GB)"
        case .fat32:   return "FAT32 — MBR (firmware, BIOS, embedded)"
        case .hfsPlus: return "Mac OS Extended (Journaled) — GPT"
        case .apfs:    return "APFS — GPT (macOS only)"
        case .uefiShell: return "UEFI shell — FAT32 / MBR (bootable, adds Update folder)"
        }
    }

    /// Format token passed to `diskutil partitionDisk`.
    var fsArg: String {
        switch self {
        case .exfat:   return "ExFAT"
        case .fat32:   return "MS-DOS FAT32"
        case .hfsPlus: return "JHFS+"
        case .apfs:    return "APFS"
        case .uefiShell: return "MS-DOS FAT32"
        }
    }

    var scheme: String {
        switch self {
        case .exfat, .fat32, .uefiShell: return "MBR"
        case .hfsPlus, .apfs: return "GPT"
        }
    }

    /// Only the UEFI shell option exposes a scheme choice; everything else is fixed.
    var allowsSchemeOverride: Bool { self == .uefiShell }

    /// FAT/ExFAT labels: 11 chars, uppercase, no punctuation.
    var requiresShortUppercaseName: Bool {
        switch self {
        case .exfat, .fat32, .uefiShell: return true
        case .hfsPlus, .apfs: return false
        }
    }

    var isUefiShell: Bool { self == .uefiShell }

    var defaultLabel: String { self == .uefiShell ? "UEFISHELL" : "USB" }
}

// MARK: - Runner

final class FormatRunner: ObservableObject {

    @Published private(set) var console: String = ""
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastExitOK: Bool? = nil
    @Published private(set) var removableAccessBlocked: Bool = false

    private var pendingStageLabel: String? = nil
    private var tailTimer: Timer?
    private var logURL: URL?
    private var readOffset: UInt64 = 0

    /// Where the UEFI shell payload lives: bundle Resources first, then Application Support.
    static func shellBinaryURL() -> URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Shell.efi"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wipeout/Shell.efi")
        if FileManager.default.fileExists(atPath: support.path) { return support }
        return nil
    }

    static var shellBinaryHint: String {
        "~/Library/Application Support/Wipeout/Shell.efi"
    }

    // MARK: Public

    func clear() {
        console = ""
        lastExitOK = nil
    }

    func appendLocal(_ line: String) {
        console += line + "\n"
    }

    func start(disk: Disk, fs: FSChoice, volumeName: String, dryRun: Bool, deepWipe: Bool, schemeOverride: String? = nil) {
        guard !isRunning else { return }
        guard !disk.isBootDisk else {
            appendLocal("REFUSED: \(disk.devNode) backs the running system.")
            return
        }

        if fs.isUefiShell && FormatRunner.shellBinaryURL() == nil {
            appendLocal("REFUSED: Shell.efi not found. Put it at \(FormatRunner.shellBinaryHint) and try again.")
            return
        }

        let label = FormatRunner.sanitize(volumeName, for: fs)
        let tmp = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let scriptURL = tmp.appendingPathComponent("wipeout-\(token).sh")
        let logFileURL = tmp.appendingPathComponent("wipeout-\(token).log")

        let body = FormatRunner.scriptBody(disk: disk,
                                           fs: fs,
                                           volumeName: label,
                                           dryRun: dryRun,
                                           deepWipe: deepWipe,
                                           scheme: schemeOverride ?? fs.scheme,
                                           logPath: logFileURL.path)
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        } catch {
            appendLocal("ERROR: could not stage script: \(error.localizedDescription)")
            return
        }

        isRunning = true
        lastExitOK = nil
        pendingStageLabel = (fs.isUefiShell && !dryRun) ? label : nil
        readOffset = 0
        logURL = logFileURL
        startTail()

        let osa = "do shell script \"/bin/bash '\(scriptURL.path)'\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = shell("/usr/bin/osascript", ["-e", osa])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.finish(status: r.status, stderr: r.err, scriptURL: scriptURL)
            }
        }
    }

    // MARK: Private

    private func startTail() {
        tailTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.drain() }
        RunLoop.main.add(t, forMode: .common)
        tailTimer = t
    }

    private func drain() {
        guard let url = logURL, let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: readOffset)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        readOffset += UInt64(data.count)
        if let chunk = String(data: data, encoding: .utf8) {
            console += chunk
        }
    }

    private func finish(status: Int32, stderr: String, scriptURL: URL) {
        drain()
        tailTimer?.invalidate()
        tailTimer = nil

        if status == 0 {
            lastExitOK = true
            if let label = pendingStageLabel {
                pendingStageLabel = nil
                stageUefiShell(label: label)
                return
            }
        } else {
            lastExitOK = false
            if stderr.contains("-128") {
                appendLocal("CANCELLED: administrator authorization was dismissed.")
            } else if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendLocal("ERROR (osascript \(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            } else {
                appendLocal("ERROR: script exited non-zero (\(status)).")
            }
        }

        try? FileManager.default.removeItem(at: scriptURL)
        isRunning = false
    }

    // MARK: UEFI staging (runs in-process so macOS can prompt for removable volume access)

    private func stageUefiShell(label: String) {
        guard let src = FormatRunner.shellBinaryURL() else {
            appendLocal("ERROR: Shell.efi went missing between format and staging.")
            isRunning = false
            return
        }
        appendLocal("--- staging UEFI shell ---")
        let volume = URL(fileURLWithPath: "/Volumes/" + label)

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var waited = 0.0
            while !fm.fileExists(atPath: volume.path) && waited < 15.0 {
                Thread.sleep(forTimeInterval: 0.5)
                waited += 0.5
            }

            var lines: [String] = []
            var ok = true
            var blocked = false

            if !fm.fileExists(atPath: volume.path) {
                lines.append("FATAL: \(volume.path) never mounted")
                ok = false
            } else {
                lines.append("volume  : \(volume.path)")
                let boot = volume.appendingPathComponent("EFI/BOOT")
                let dest = boot.appendingPathComponent("BOOTX64.EFI")
                do {
                    try fm.createDirectory(at: boot, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: src, to: dest)
                    try fm.createDirectory(at: volume.appendingPathComponent("Update"),
                                           withIntermediateDirectories: true)
                    lines.append("wrote   : EFI/BOOT/BOOTX64.EFI")
                    lines.append("created : Update/")
                    lines.append("")
                    lines.append("At the server's shell prompt: fs0: then cd \\Update")
                } catch {
                    ok = false
                    let ns = error as NSError
                    if ns.code == NSFileWriteNoPermissionError || ns.code == 513 || ns.code == 1 {
                        blocked = true
                        lines.append("FATAL: macOS blocked writing to the removable volume.")
                        lines.append("       Allow Wipeout under Privacy & Security > Files and Folders >")
                        lines.append("       Removable Volumes, then run again. The drive is already")
                        lines.append("       formatted, so a rerun only re-stages the files.")
                    } else {
                        lines.append("FATAL: staging failed - \(error.localizedDescription)")
                    }
                }
            }

            DispatchQueue.main.async {
                for l in lines { self.appendLocal(l) }
                self.appendLocal(ok ? "DONE" : "")
                self.lastExitOK = ok
                self.removableAccessBlocked = blocked
                self.isRunning = false
            }
        }
    }

    // MARK: Script generation

    static func sanitize(_ raw: String, for fs: FSChoice) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { allowed.contains($0) }))
        if s.isEmpty { s = "UNTITLED" }
        if fs.requiresShortUppercaseName {
            s = s.uppercased()
            if s.count > 11 { s = String(s.prefix(11)) }
        } else if s.count > 24 {
            s = String(s.prefix(24))
        }
        return s
    }

    static func scriptBody(disk: Disk, fs: FSChoice, volumeName: String, dryRun: Bool, deepWipe: Bool, scheme: String, logPath: String) -> String {
        let dry = dryRun ? "1" : "0"
        return """
        #!/bin/bash
        set -u
        exec >>"\(logPath)" 2>&1

        DRY=\(dry)
        DEEP=\(deepWipe ? "1" : "0")
        UEFI=\(fs.isUefiShell ? "1" : "0")
        DISK="\(disk.devNode)"
        SCHEME="\(scheme)"
        FSTYPE="\(fs.fsArg)"
        VOLNAME="\(volumeName)"
        SIZE=\(disk.sizeBytes)
        MB=$(( SIZE / 1048576 ))

        say() { echo "$@"; }
        run() {
          say "+ $*"
          if [ "$DRY" -eq 1 ]; then return 0; fi
          "$@"
        }

        say "=== wipeout $(date '+%Y-%m-%d %H:%M:%S') ==="
        say "target  : $DISK  (\(disk.mediaName), \(disk.sizeString))"
        say "scheme  : $SCHEME"
        say "format  : $FSTYPE"
        say "label   : $VOLNAME"
        if [ "$UEFI" -eq 1 ]; then say "mode    : UEFI shell boot media"; fi
        if [ "$DEEP" -eq 1 ]; then say "mode    : deep wipe (full zero pass)"; fi
        if [ "$DRY" -eq 1 ]; then say "mode    : DRY RUN - nothing will be written"; fi
        say ""

        say "--- layout before ---"
        diskutil list "$DISK"
        say ""

        say "--- unmounting ---"
        run diskutil unmountDisk force "$DISK"
        if [ $? -ne 0 ] && [ "$DRY" -eq 0 ]; then
          say "FATAL: could not unmount $DISK"
          exit 10
        fi
        say ""

        say "--- resetting partition map ---"
        run diskutil eraseDisk free NONE "$SCHEME" "$DISK"
        if [ $? -ne 0 ]; then
          say "WARN: map reset failed - continuing to partitionDisk"
        fi
        say ""

        if [ "$DEEP" -eq 1 ]; then
          say "--- deep wipe: zeroing all ${MB} MiB (this takes a while) ---"
          run diskutil zeroDisk force "$DISK"
          if [ $? -ne 0 ] && [ "$DRY" -eq 0 ]; then
            say "FATAL: zeroDisk failed"
            exit 11
          fi
          say ""
        fi

        if [ "$UEFI" -eq 1 ] && [ "$SCHEME" = "GPT" ]; then
          say "note: GPT adds a 200 MB EFI System partition; the shell goes on the data volume"
          say ""
        fi

        say "--- creating single $FSTYPE partition on $SCHEME ---"
        run diskutil partitionDisk "$DISK" 1 "$SCHEME" "$FSTYPE" "$VOLNAME" R
        if [ $? -ne 0 ] && [ "$DRY" -eq 0 ]; then
          say "FATAL: partitionDisk failed"
          exit 12
        fi
        say ""

        say "--- layout after ---"
        diskutil list "$DISK"
        say ""
        if [ "$UEFI" -eq 0 ]; then say "DONE"; fi
        exit 0
        """
    }
}
