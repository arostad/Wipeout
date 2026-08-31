import SwiftUI
import AppKit

@main
struct WipeoutApp: App {
    var body: some Scene {
        WindowGroup("Wipeout Drive Formatter") {
            ContentView()
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Wipeout") { showAbout() }
            }
        }
    }
}

private let labelWidth: CGFloat = 96

/// One form row: fixed-width right-aligned label, control starts at the same x every time.
private struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .frame(width: labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

private func showAbout() {
    let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor
    ]
    let credits = NSMutableAttributedString(
        string: "Erase any drive back to one clean partition.\n\nCreated by ",
        attributes: body)
    let name = NSMutableAttributedString(string: BuildInfo.author, attributes: body)
    name.addAttributes([
        .link: BuildInfo.githubURL,
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue
    ], range: NSRange(location: 0, length: name.length))
    credits.append(name)

    NSApplication.shared.orderFrontStandardAboutPanel(options: [
        .applicationName: "Wipeout",
        .applicationVersion: BuildInfo.version,
        .credits: credits,
        NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): BuildInfo.copyright
    ])
    NSApplication.shared.activate(ignoringOtherApps: true)
}

struct ContentView: View {

    @StateObject private var runner = FormatRunner()

    @State private var disks: [Disk] = []
    @State private var selectedID: String = ""
    @State private var fs: FSChoice = .exfat
    @State private var volumeName: String = "USB"
    @State private var showInternal: Bool = false
    @State private var dryRun: Bool = false
    @State private var deepWipe: Bool = false
    @State private var uefiScheme: String = "MBR"
    @FocusState private var labelFocused: Bool
    @State private var confirming: Bool = false

    private var visibleDisks: [Disk] {
        disks.filter { showInternal || !$0.isInternal }
    }

    private var selected: Disk? {
        visibleDisks.first { $0.id == selectedID }
    }

    private var deepWipeEstimate: String {
        guard let d = selected else { return "zeroes the entire device before formatting" }
        let minutes = max(1, Int(Double(d.sizeBytes) / (90.0 * 1_000_000) / 60.0))
        return "full zero pass, roughly \(minutes) min at typical USB 3 speed"
    }

    private var canFormat: Bool {
        guard let d = selected else { return false }
        if fs.isUefiShell && FormatRunner.shellBinaryURL() == nil { return false }
        return !runner.isRunning && !d.isBootDisk
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Device selection
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Device").font(.headline)
                    Spacer()
                    Toggle("Show internal disks", isOn: $showInternal)
                        .toggleStyle(.checkbox)
                    Button("Rescan") { rescan() }
                        .disabled(runner.isRunning)
                }

                Picker("", selection: $selectedID) {
                    if visibleDisks.isEmpty {
                        Text("No eligible devices found").tag("")
                    }
                    ForEach(visibleDisks) { d in
                        Text(d.menuLabel).tag(d.id)
                    }
                }
                .labelsHidden()
                .disabled(runner.isRunning)

                if let d = selected {
                    Text(d.detailLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if d.isBootDisk {
                        Text("This disk backs the running system. Formatting is blocked.")
                            .font(.caption).bold()
                            .foregroundColor(.red)
                    } else if d.isInternal {
                        Text("Internal disk selected. Verify the identifier before continuing.")
                            .font(.caption).bold()
                            .foregroundColor(.orange)
                    }
                }
            }

            Divider()

            // Format options
            VStack(alignment: .leading, spacing: 8) {
                Text("Format").font(.headline)

                LabeledRow("Filesystem") {
                    Picker("", selection: $fs) {
                        ForEach(FSChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(runner.isRunning)
                    .onChange(of: fs) { newValue in
                        if volumeName.isEmpty || FSChoice.allCases.contains(where: { $0.defaultLabel == volumeName }) {
                            volumeName = newValue.defaultLabel
                        }
                    }
                }

                LabeledRow("Volume label") {
                    HStack(spacing: 8) {
                        TextField("e.g. UBUNTU", text: $volumeName)
                            .frame(width: 240)
                            .focused($labelFocused)
                            .onSubmit { labelFocused = false }
                            .disabled(runner.isRunning)
                        Text("mounts as \(FormatRunner.sanitize(volumeName, for: fs))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if fs.allowsSchemeOverride {
                    LabeledRow("Scheme") {
                        HStack(spacing: 8) {
                            Picker("", selection: $uefiScheme) {
                                Text("MBR").tag("MBR")
                                Text("GPT").tag("GPT")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .disabled(runner.isRunning)
                            Text(uefiScheme == "MBR"
                                 ? "one partition, no stray ESP"
                                 : "adds a 200 MB ESP; for firmware that only sees ESP-typed disks")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if fs.isUefiShell {
                    if FormatRunner.shellBinaryURL() == nil {
                        Text("Shell.efi not found. Put it at \(FormatRunner.shellBinaryHint) or in the app bundle's Resources folder.")
                            .font(.caption).bold()
                            .foregroundColor(.red)
                    } else {
                        Text("Writes EFI/BOOT/BOOTX64.EFI plus an empty Update folder. Firmware boots it as removable media.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if runner.removableAccessBlocked {
                    HStack(spacing: 8) {
                        Text("macOS blocked writing to the removable volume.")
                            .font(.caption).bold()
                            .foregroundColor(.red)
                        Button("Open privacy settings") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                    }
                }

                HStack(spacing: 16) {
                    Toggle("Dry run (print commands only)", isOn: $dryRun)
                        .toggleStyle(.checkbox)
                        .disabled(runner.isRunning)
                    Toggle("Deep wipe (zero whole device)", isOn: $deepWipe)
                        .toggleStyle(.checkbox)
                        .disabled(runner.isRunning)
                        .help(deepWipeEstimate)
                    Spacer()
                    if runner.isRunning { ProgressView().controlSize(.small) }
                    Button(dryRun ? "Preview" : "Erase & Format") { confirming = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canFormat)
                }
            }

            Divider()

            // Console
            HStack {
                Text("Console").font(.headline)
                Spacer()
                if let ok = runner.lastExitOK {
                    Text(ok ? "last run: OK" : "last run: FAILED")
                        .font(.caption)
                        .foregroundColor(ok ? .green : .red)
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.console, forType: .string)
                }
                .disabled(runner.console.isEmpty)
                Button("Clear") { runner.clear() }
                    .disabled(runner.isRunning || runner.console.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.console.isEmpty ? "idle\n" : runner.console)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(Color(white: 0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color.black.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: runner.console) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(minHeight: 240)
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture { labelFocused = false }
        .onAppear {
            rescan()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                labelFocused = false
                for w in NSApp.windows where w.isVisible { w.makeFirstResponder(nil) }
            }
        }
        .alert("Erase \(selected?.devNode ?? "")?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button(dryRun ? "Preview" : "Erase", role: .destructive) { launch() }
        } message: {
            if let d = selected {
                Text("""
                \(d.mediaName) — \(d.sizeString)
                Volumes: \(d.volumeSummary)

                Every partition on this device will be destroyed and replaced with one \(fs.fsArg) partition named \(FormatRunner.sanitize(volumeName, for: fs)) on \(fs.allowsSchemeOverride ? uefiScheme : fs.scheme).\(deepWipe ? "\n\nDeep wipe is on: \(deepWipeEstimate)" : "")
                """)
            }
        }
    }

    // MARK: Actions

    private func rescan() {
        let found = DiskScanner.scan()
        disks = found
        let visible = found.filter { showInternal || !$0.isInternal }
        if visible.first(where: { $0.id == selectedID }) == nil {
            selectedID = visible.first(where: { $0.category == .usb && !$0.isBootDisk })?.id
                ?? visible.first(where: { !$0.isBootDisk })?.id
                ?? ""
        }
    }

    private func launch() {
        guard let d = selected else { return }
        runner.appendLocal("")
        runner.start(disk: d, fs: fs, volumeName: volumeName, dryRun: dryRun, deepWipe: deepWipe,
                     schemeOverride: fs.allowsSchemeOverride ? uefiScheme : nil)
    }
}
