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

// MARK: - Console model

enum LogLevel {
    case step      // plain-English "what's happening now"
    case info
    case success
    case warning
    case error
    case detail    // raw tool output, shown dimmed / behind "Show details"
}

struct ConsoleLine: Identifiable {
    let id: Int
    let level: LogLevel
    let text: String
}

enum RunOutcome: Equatable {
    case success(title: String, detail: String)
    case preview(title: String, detail: String)
    case failure(title: String, detail: String)
    case ejected(title: String, detail: String)
}

// MARK: - Runner

final class FormatRunner: ObservableObject {

    /// Full raw log (no level markers). The Copy button copies this.
    @Published private(set) var console: String = ""
    /// Parsed lines for the friendly console view.
    @Published private(set) var lines: [ConsoleLine] = []
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastExitOK: Bool? = nil
    @Published private(set) var removableAccessBlocked: Bool = false
    @Published private(set) var outcome: RunOutcome? = nil
    /// Set after a real (non-dry-run) format succeeds. Holds the settings key the
    /// format ran with, so the UI can offer Eject until the user changes something.
    @Published private(set) var readyDisk: Disk? = nil
    @Published private(set) var readyKey: String? = nil

    private var pendingStageLabel: String? = nil
    private var tailTimer: Timer?
    private var logURL: URL?
    private var readOffset: UInt64 = 0
    private var partial: String = ""
    private var nextLineID = 0

    // Current job context
    private var job: Job?

    private struct Job {
        let disk: Disk
        let fs: FSChoice
        let label: String
        let scheme: String
        let dryRun: Bool
        let key: String
        let scriptURL: URL
        var elevated: Bool
        var attemptStartOffset: UInt64
    }

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
        lines = []
        lastExitOK = nil
        outcome = nil
    }

    func appendLocal(_ line: String) {
        emit(.info, line)
    }

    /// Forget the "drive ready" state (user changed device or settings).
    func clearReady() {
        guard readyDisk != nil || readyKey != nil else { return }
        readyDisk = nil
        readyKey = nil
        if case .success = outcome { outcome = nil }
    }

    func start(disk: Disk, fs: FSChoice, volumeName: String, dryRun: Bool, deepWipe: Bool,
               schemeOverride: String? = nil, settingsKey: String = "") {
        guard !isRunning else { return }
        guard !disk.isBootDisk else {
            emit(.error, "Refused: \(disk.devNode) backs the running system.")
            return
        }

        if fs.isUefiShell && FormatRunner.shellBinaryURL() == nil {
            emit(.error, "Refused: Shell.efi not found. Put it at \(FormatRunner.shellBinaryHint) and try again.")
            return
        }

        let label = FormatRunner.sanitize(volumeName, for: fs)
        let scheme = schemeOverride ?? fs.scheme
        let tmp = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let scriptURL = tmp.appendingPathComponent("wipeout-\(token).sh")
        let logFileURL = tmp.appendingPathComponent("wipeout-\(token).log")

        let body = FormatRunner.scriptBody(disk: disk,
                                           fs: fs,
                                           volumeName: label,
                                           dryRun: dryRun,
                                           deepWipe: deepWipe,
                                           scheme: scheme,
                                           logPath: logFileURL.path)
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        } catch {
            emit(.error, "Could not stage the format script: \(error.localizedDescription)")
            return
        }

        isRunning = true
        lastExitOK = nil
        outcome = nil
        readyDisk = nil
        readyKey = nil
        removableAccessBlocked = false
        pendingStageLabel = (fs.isUefiShell && !dryRun) ? label : nil
        readOffset = 0
        partial = ""
        logURL = logFileURL
        job = Job(disk: disk, fs: fs, label: label, scheme: scheme, dryRun: dryRun,
                  key: settingsKey, scriptURL: scriptURL, elevated: false, attemptStartOffset: 0)
        startTail()
        runAttempt()
    }

    /// Eject the drive that was just formatted. Runs as the logged-in user.
    func eject(_ disk: Disk, completion: @escaping () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        let name = disk.id
        emit(.step, "Ejecting \(name)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = shell("/usr/sbin/diskutil", ["eject", disk.devNode])
            let out = String(data: r.out, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                for l in (out + r.err).split(separator: "\n") { self.emit(.detail, String(l)) }
                if r.status == 0 {
                    self.emit(.success, "Ejected \(name). You can unplug the drive.")
                    self.outcome = .ejected(title: "Ejected", detail: "\(disk.mediaName) is safe to unplug.")
                } else {
                    self.emit(.error, "Couldn't eject \(name). Quit any app using the drive and try again.")
                    self.outcome = .failure(title: "Eject failed",
                                            detail: "Quit any app using \(name), then click Eject again or use Finder.")
                }
                if r.status == 0 {
                    self.readyDisk = nil
                    self.readyKey = nil
                }
                self.isRunning = false
                completion()
            }
        }
    }

    // MARK: Running

    /// First attempt runs the script as the logged-in user (no password).
    /// diskutil talks to DiskArbitration / diskmanagementd, which lets the console
    /// user erase and partition external drives. Only if macOS refuses with a
    /// permission error do we retry once through the old administrator prompt.
    private func runAttempt() {
        guard var j = job else { return }
        j.attemptStartOffset = readOffset
        job = j
        let scriptPath = j.scriptURL.path
        let elevated = j.elevated
        DispatchQueue.global(qos: .userInitiated).async {
            let r: (status: Int32, out: Data, err: String)
            if elevated {
                let osa = "do shell script \"/bin/bash '\(scriptPath)'\" with administrator privileges"
                r = shell("/usr/bin/osascript", ["-e", osa])
            } else {
                r = shell("/bin/bash", [scriptPath])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.attemptFinished(status: r.status, stderr: r.err)
            }
        }
    }

    private func attemptFinished(status: Int32, stderr: String) {
        drain()
        guard var j = job else { return }

        if status != 0 && !j.elevated && !j.dryRun && permissionFailure(since: j.attemptStartOffset, stderr: stderr) {
            emit(.warning, "macOS needs administrator approval for this drive. Asking for your password once to finish.")
            j.elevated = true
            job = j
            runAttempt()
            return
        }

        flushPartial()
        tailTimer?.invalidate()
        tailTimer = nil

        if status == 0 {
            if let label = pendingStageLabel {
                pendingStageLabel = nil
                stageUefiShell(label: label)
                return
            }
            succeed()
        } else {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if j.elevated && err.contains("-128") {
                emit(.error, "Cancelled: administrator approval was dismissed. Nothing more was written.")
                fail(title: "Cancelled", detail: "The password prompt was dismissed. The drive may be partly erased; run again to finish.")
            } else {
                if !err.isEmpty { emit(.error, err) }
                let reason = lastErrorLine() ?? "The format script exited with code \(status)."
                fail(title: "Format failed", detail: reason)
            }
        }
    }

    private func succeed() {
        guard let j = job else { return }
        lastExitOK = true
        if j.dryRun {
            emit(.success, "Preview finished. Nothing was written to \(j.disk.id).")
            outcome = .preview(title: "Preview finished",
                               detail: "Nothing was written. Turn off Dry run to format \(j.disk.id).")
        } else {
            let what = "\(j.disk.sizeString) \(FormatRunner.friendlyFS(j.fs)) (\(j.scheme))"
            emit(.success, "Done. \(j.label) is ready: \(what).")
            outcome = .success(title: "Drive ready", detail: "\(j.label) on \(j.disk.id) — \(what). Eject it before unplugging.")
            readyDisk = j.disk
            readyKey = j.key
        }
        cleanupJob()
    }

    private func fail(title: String, detail: String) {
        lastExitOK = false
        outcome = .failure(title: title, detail: detail)
        cleanupJob()
    }

    private func cleanupJob() {
        if let j = job { try? FileManager.default.removeItem(at: j.scriptURL) }
        job = nil
        isRunning = false
    }

    /// True when this attempt's output looks like macOS refused for lack of privilege.
    private func permissionFailure(since offset: UInt64, stderr: String) -> Bool {
        var text = stderr
        if let url = logURL, let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            try? fh.seek(toOffset: offset)
            text += String(data: fh.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        let t = text.lowercased()
        let needles = ["permission denied", "not permitted", "not privileged", "insufficient privilege",
                       "must be root", "requires root", "run as root", "root privileges",
                       "not authorized", "authorization", "couldn't open device", "-69877"]
        return needles.contains { t.contains($0) }
    }

    private func lastErrorLine() -> String? {
        lines.last(where: { $0.level == .error })?.text
    }

    // MARK: Log tailing / parsing

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
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        partial += chunk
        while let nl = partial.firstIndex(of: "\n") {
            let raw = String(partial[..<nl])
            partial = String(partial[partial.index(after: nl)...])
            ingest(raw)
        }
    }

    private func flushPartial() {
        if !partial.isEmpty {
            ingest(partial)
            partial = ""
        }
    }

    /// Script lines carry an optional "@@LEVEL " marker; anything else is raw tool output.
    private func ingest(_ rawLine: String) {
        // Progress bars use carriage returns; keep only the latest state.
        let line = rawLine.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? rawLine
        let markers: [(String, LogLevel)] = [("@@STEP ", .step), ("@@INFO ", .info), ("@@OK ", .success),
                                             ("@@WARN ", .warning), ("@@ERR ", .error), ("@@CMD ", .detail)]
        for (m, level) in markers where line.hasPrefix(m) {
            let text = String(line.dropFirst(m.count))
            emit(level, level == .detail ? "$ " + text : text)
            return
        }
        emit(.detail, line)
    }

    private func emit(_ level: LogLevel, _ text: String) {
        console += text + "\n"
        lines.append(ConsoleLine(id: nextLineID, level: level, text: text))
        nextLineID += 1
    }

    // MARK: UEFI staging (runs in-process so macOS can prompt for removable volume access)

    private func stageUefiShell(label: String) {
        guard let src = FormatRunner.shellBinaryURL() else {
            emit(.error, "Shell.efi went missing between format and staging.")
            fail(title: "Staging failed", detail: "Shell.efi went missing between format and staging.")
            return
        }
        emit(.step, "Copying the UEFI shell onto the drive…")
        let volume = URL(fileURLWithPath: "/Volumes/" + label)

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var waited = 0.0
            while !fm.fileExists(atPath: volume.path) && waited < 15.0 {
                Thread.sleep(forTimeInterval: 0.5)
                waited += 0.5
            }

            var out: [(LogLevel, String)] = []
            var ok = true
            var blocked = false

            if !fm.fileExists(atPath: volume.path) {
                out.append((.error, "\(volume.path) never mounted."))
                ok = false
            } else {
                out.append((.detail, "volume  : \(volume.path)"))
                let boot = volume.appendingPathComponent("EFI/BOOT")
                let dest = boot.appendingPathComponent("BOOTX64.EFI")
                do {
                    try fm.createDirectory(at: boot, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: src, to: dest)
                    try fm.createDirectory(at: volume.appendingPathComponent("Update"),
                                           withIntermediateDirectories: true)
                    out.append((.detail, "wrote   : EFI/BOOT/BOOTX64.EFI"))
                    out.append((.detail, "created : Update/"))
                    out.append((.info, "At the server's shell prompt: fs0: then cd \\Update"))
                } catch {
                    ok = false
                    let ns = error as NSError
                    if ns.code == NSFileWriteNoPermissionError || ns.code == 513 || ns.code == 1 {
                        blocked = true
                        out.append((.error, "macOS blocked writing to the removable volume."))
                        out.append((.warning, "Allow Wipeout under Privacy & Security > Files and Folders > Removable Volumes, then run again. The drive is already formatted, so a rerun only re-stages the files."))
                    } else {
                        out.append((.error, "Staging failed: \(error.localizedDescription)"))
                    }
                }
            }

            DispatchQueue.main.async {
                for (lvl, l) in out { self.emit(lvl, l) }
                self.removableAccessBlocked = blocked
                if ok {
                    self.succeed()
                } else {
                    self.fail(title: "UEFI shell not staged",
                              detail: blocked ? "macOS blocked writing to the drive. Allow Removable Volumes access and run again."
                                              : (self.lastErrorLine() ?? "Staging failed."))
                }
            }
        }
    }

    // MARK: Script generation

    static func friendlyFS(_ fs: FSChoice) -> String {
        switch fs {
        case .exfat: return "exFAT"
        case .fat32, .uefiShell: return "FAT32"
        case .hfsPlus: return "Mac OS Extended"
        case .apfs: return "APFS"
        }
    }

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
        let ntfsNote = (fs == .exfat && scheme == "MBR")
            ? "@@INFO Note: exFAT on MBR shows as Windows_NTFS in the table above. That is expected; both use partition type 0x07."
            : ""
        return """
        #!/bin/bash
        set -u
        exec >>"\(logPath)" 2>&1

        DRY=\(dry)
        DEEP=\(deepWipe ? "1" : "0")
        UEFI=\(fs.isUefiShell ? "1" : "0")
        DISK="\(disk.devNode)"
        NAME="\(disk.id)"
        SCHEME="\(scheme)"
        FSTYPE="\(fs.fsArg)"
        FRIENDLY="\(friendlyFS(fs))"
        VOLNAME="\(volumeName)"
        SIZE=\(disk.sizeBytes)
        MB=$(( SIZE / 1048576 ))

        step() { echo "@@STEP $*"; }
        info() { echo "@@INFO $*"; }
        ok()   { echo "@@OK $*"; }
        warn() { echo "@@WARN $*"; }
        err()  { echo "@@ERR $*"; }
        run() {
          echo "@@CMD $*"
          if [ "$DRY" -eq 1 ]; then return 0; fi
          "$@"
        }

        echo "=== wipeout $(date '+%Y-%m-%d %H:%M:%S') ($(id -un)) ==="
        info "Target: $NAME (\(disk.mediaName), \(disk.sizeString)) -> $FRIENDLY ($SCHEME), label $VOLNAME"
        if [ "$UEFI" -eq 1 ]; then info "Mode: UEFI shell boot media"; fi
        if [ "$DEEP" -eq 1 ]; then info "Mode: deep wipe (full zero pass)"; fi
        if [ "$DRY" -eq 1 ]; then warn "Dry run: commands are shown but nothing will be written."; fi

        echo "--- layout before ---"
        diskutil list "$DISK"

        step "Unmounting $NAME…"
        run diskutil unmountDisk force "$DISK"
        if [ $? -ne 0 ] && [ "$DRY" -eq 0 ]; then
          err "Couldn't unmount $NAME. Quit any app using the drive and try again."
          exit 10
        fi

        step "Clearing the old partition map…"
        run diskutil eraseDisk free NONE "$SCHEME" "$DISK"
        if [ $? -ne 0 ]; then
          warn "Couldn't clear the old partition map; continuing to format anyway."
        fi

        if [ "$DEEP" -eq 1 ]; then
          step "Writing zeros to all ${MB} MiB (this takes a while)…"
          run diskutil zeroDisk force "$DISK"
          if [ $? -ne 0 ] && [ "$DRY" -eq 0 ]; then
            err "Deep wipe (zeroDisk) failed."
            exit 11
          fi
        fi

        if [ "$UEFI" -eq 1 ] && [ "$SCHEME" = "GPT" ]; then
          info "GPT adds a 200 MB EFI System partition; the shell goes on the data volume."
        fi

        step "Erasing and formatting as $FRIENDLY ($SCHEME), label $VOLNAME…"
        run diskutil partitionDisk "$DISK" 1 "$SCHEME" "$FSTYPE" "$VOLNAME" R
        if [ $? -ne 0 ] && [ "$DRY" -eq 0 ]; then
          err "Formatting (partitionDisk) failed."
          exit 12
        fi

        echo "--- layout after ---"
        diskutil list "$DISK"
        \(ntfsNote)
        exit 0
        """
    }
}
