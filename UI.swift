import SwiftUI
import AppKit
import CoreText

@main
struct WipeoutApp: App {
    @StateObject private var updateInstall = UpdateInstallController()

    init() {
        Wordmark.registerBundledFont()
    }

    var body: some Scene {
        WindowGroup("wipeout Drive Formatter") {
            ContentView()
                .environmentObject(updateInstall)
                .frame(minWidth: MainWindowMetrics.minWidth, minHeight: MainWindowMetrics.minHeight)
        }
        .defaultSize(width: MainWindowMetrics.minWidth, height: MainWindowMetrics.minHeight)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands { AboutCommands() }

        Window("About wipeout", id: "about") {
            AboutView()
                .environmentObject(updateInstall)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About wipeout") {
                openWindow(id: "about")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// Main window size. 0.4.16 was 760×620. The green Drive ready (or other
/// outcome) banner sits under the Console header and consumes
/// `outcomeBannerHeight` plus one extra `ContentView` stack spacing, which
/// had been shrinking the console and clipping its bottom edge. The window
/// does not auto-resize when the banner or update popover appears; instead
/// the default and minimum height include that room up front.
private enum MainWindowMetrics {
    static let minWidth: CGFloat = 760
    static let legacyMinHeight: CGFloat = 620
    /// Typical OutcomeBanner: 8 pt padding + 16 pt headline line + 2 pt
    /// inner stack spacing + 16 pt callout line + 8 pt padding.
    static let outcomeBannerHeight: CGFloat = 50
    /// Extra VStack spacing when the banner is inserted between the Console
    /// header and the console (`ContentView` uses spacing 14).
    static let outcomeBannerSpacing: CGFloat = 14
    static let minHeight: CGFloat = legacyMinHeight + outcomeBannerHeight + outcomeBannerSpacing

    /// Existing installs may have a saved frame at the old 620 pt content
    /// height. Raise those (and anything else below the new default) so the
    /// taller minimum actually takes effect. Larger frames are left alone.
    /// The title-bar stays put; the window grows downward.
    static func raiseSavedFrameIfNeeded() {
        for window in NSApp.windows {
            guard window.isVisible, !window.isSheet, window.canBecomeMain else { continue }
            if window.title.hasPrefix("About") { continue }
            let isFormatter = window.title.contains("Drive Formatter")
                || (window.title.isEmpty && window.styleMask.contains(.resizable))
            guard isFormatter else { continue }
            let layoutHeight = window.contentLayoutRect.height
            let deficit = minHeight - layoutHeight
            guard deficit > 0.5 else { continue }
            var frame = window.frame
            frame.size.height += deficit
            frame.origin.y -= deficit
            window.setFrame(frame, display: true)
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

/// UserDefaults key for "Check for updates at launch". Defaults to on.
let checkUpdatesAtLaunchKey = "checkForUpdatesAtLaunch"

/// Shared install state for the main-window update popover and the About window.
@MainActor
final class UpdateInstallController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case verified
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64? = nil

    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .verified: return true
        default: return false
        }
    }

    var failedMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var downloadFraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(total))
    }

    var downloadPercent: Int? {
        guard let fraction = downloadFraction else { return nil }
        return min(100, Int((fraction * 100).rounded(.down)))
    }

    func reset() {
        phase = .idle
        receivedBytes = 0
        totalBytes = nil
    }

    func start() async throws {
        phase = .downloading
        receivedBytes = 0
        totalBytes = nil
        do {
            try await UpdateChecker.downloadAndRestart { [weak self] stage in
                Task { @MainActor in
                    self?.apply(stage)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    private func apply(_ stage: UpdateInstallStage) {
        switch stage {
        case .download(let received, let total):
            if phase != .downloading { phase = .downloading }
            receivedBytes = received
            totalBytes = total
        case .verifying:
            phase = .verifying
        case .verified:
            phase = .verified
        }
    }
}

private enum ByteCountText {
    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}

private struct UpdateInstallProgressView: View {
    @ObservedObject var installer: UpdateInstallController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch installer.phase {
            case .idle:
                EmptyView()
            case .downloading:
                Text("Downloading the update…")
                    .font(.callout)
                downloadMeter
            case .verifying:
                Text("Verifying checksum…")
                    .font(.callout)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.wipeoutAccent)
                    .controlSize(.small)
            case .verified:
                Text("Checksum verified ✓")
                    .font(.callout)
                    .foregroundColor(.wipeoutSuccess)
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundColor(.wipeoutError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var downloadMeter: some View {
        if let fraction = installer.downloadFraction,
           let percent = installer.downloadPercent,
           let total = installer.totalBytes {
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(LinearProgressViewStyle(tint: Color.wipeoutAccent))
                    .controlSize(.small)
                Text("\(percent)%")
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            Text("\(ByteCountText.format(installer.receivedBytes)) of \(ByteCountText.format(total))")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ProgressView()
                .progressViewStyle(LinearProgressViewStyle(tint: Color.wipeoutAccent))
                .controlSize(.small)
            Text("\(ByteCountText.format(installer.receivedBytes)) downloaded")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// About wordmark: bundled Plus Jakarta Sans SemiBold at 36 pt, −0.01em tracking.
/// Falls back to the system semibold if the font is missing or failed to register.
private enum Wordmark {
    static let postScriptName = "PlusJakartaSans-SemiBold"
    static let size: CGFloat = 36
    static let tracking: CGFloat = -0.36

    static func registerBundledFont() {
        guard let url = Bundle.main.url(
            forResource: "PlusJakartaSans-SemiBold",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static var font: Font {
        if NSFont(name: postScriptName, size: size) != nil {
            return .custom(postScriptName, size: size)
        }
        return .system(size: size, weight: .semibold)
    }
}

private struct AboutView: View {

    @EnvironmentObject private var updateInstall: UpdateInstallController
    @State private var status = ""
    @State private var checking = false
    @State private var updateAvailable = false
    @AppStorage(checkUpdatesAtLaunchKey) private var checkAtLaunch = true

    private let sourceURL = URL(string: "https://github.com/arostad/Wipeout")!
    private let licenseURL = URL(string: "https://github.com/arostad/Wipeout/blob/main/LICENSE")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("wipeout")
                            .font(Wordmark.font)
                            .tracking(Wordmark.tracking)
                        Text("Version \(BuildInfo.version)")
                            .font(.headline)
                        Link("GitHub project page", destination: sourceURL)
                            .font(.callout)
                    }
                }

                Text("Wipes a USB stick, SD card, or any non-system drive back to one full-size partition with the file system of your choosing.")
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text("App created by ")
                        Link(BuildInfo.author, destination: URL(string: BuildInfo.githubURL)!)
                        Text(".")
                    }
                    HStack(spacing: 0) {
                        Text("Released under the ")
                        Link("MIT License", destination: licenseURL)
                        Text(".")
                    }
                }

                Toggle("Check for updates at launch (recommended)", isOn: $checkAtLaunch)
                    .toggleStyle(OrangeCheckboxStyle())

                Text("Each update check sends one anonymous request to the wipeout update server. It counts only the country the request came from, for a rough guesstimate of the app's popularity (or lack thereof) for my own curiosity. Your IP address is never stored, and no identifiers, cookies, or telemetry are used.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if updateInstall.phase != .idle {
                    UpdateInstallProgressView(installer: updateInstall)
                } else if !status.isEmpty {
                    Text(status)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button(updateAvailable ? "Update now" : "Check for updates") {
                    if updateAvailable {
                        installUpdate()
                    } else {
                        checkForUpdates()
                    }
                }
                .disabled(checking || updateInstall.isBusy)
                Spacer()
                Button("Close") { NSApp.keyWindow?.close() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
        .frame(width: 460)
    }

    private func checkForUpdates() {
        checking = true
        status = "Checking…"
        updateInstall.reset()
        Task {
            let info = await UpdateChecker.check()
            checking = false
            if let error = info.error, !info.isNewer {
                status = error
            } else if !info.isNewer {
                status = "You're on the latest version (\(BuildInfo.version))."
            } else {
                status = "Version \(info.remoteVersion) is available."
                updateAvailable = true
            }
        }
    }

    private func installUpdate() {
        checking = true
        status = ""
        Task {
            do {
                try await updateInstall.start()
                NSApplication.shared.terminate(nil)
            } catch {
                status = error.localizedDescription
                checking = false
            }
        }
    }
}

struct ContentView: View {

    @EnvironmentObject private var updateInstall: UpdateInstallController
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
    @State private var didCheckForUpdates = false
    @State private var availableUpdate: UpdateInfo?
    @State private var showingUpdatePopover = false
    @State private var updateMessage = ""
    @State private var showDetails = false
    @AppStorage(checkUpdatesAtLaunchKey) private var checkAtLaunch = true

    /// Everything that defines a format job. Changing any of it drops the Eject state.
    private var settingsKey: String {
        "\(selectedID)|\(fs.rawValue)|\(runner.ntfsFormatter?.personality ?? "")|\(FormatRunner.sanitize(volumeName, for: fs))|\(uefiScheme)|\(deepWipe)|\(dryRun)"
    }

    private var ntfsAvailable: Bool { runner.ntfsFormatter != nil }

    /// The drive just formatted with the current settings, ready to eject.
    private var ejectTarget: Disk? {
        guard let d = runner.readyDisk, runner.readyKey == settingsKey, d.id == selectedID else { return nil }
        return d
    }

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
        if fs == .ntfs && !ntfsAvailable { return false }
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
                        .toggleStyle(OrangeCheckboxStyle())
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
                            .foregroundColor(.wipeoutError)
                    } else if d.isInternal {
                        Text("Internal disk selected. Verify the identifier before continuing.")
                            .font(.caption).bold()
                            .foregroundColor(.wipeoutWarning)
                    }
                }
            }

            Divider()

            // Format options
            VStack(alignment: .leading, spacing: 8) {
                Text("Format").font(.headline)

                LabeledRow("Filesystem") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $fs) {
                            ForEach(FSChoice.allCases) { choice in
                                if choice == .ntfs && !ntfsAvailable {
                                    Text("NTFS — needs Paragon or Tuxera")
                                        .foregroundColor(.secondary)
                                        .help("NTFS needs Paragon NTFS or Tuxera NTFS for Mac installed")
                                        .tag(choice)
                                        .disabled(true)
                                } else {
                                    Text(choice.title)
                                        .tag(choice)
                                }
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
                        // Only if NTFS is the current selection without a driver; otherwise
                        // the disabled menu item carries the hint and this line stays gone
                        // so the layout under the picker does not shift.
                        if fs == .ntfs && !ntfsAvailable {
                            Text("NTFS needs Paragon NTFS or Tuxera NTFS for Mac installed")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                            .foregroundColor(.wipeoutError)
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
                            .foregroundColor(.wipeoutError)
                        Button("Open privacy settings") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                    }
                }

                HStack(spacing: 16) {
                    Toggle("Dry run (print commands only)", isOn: $dryRun)
                        .toggleStyle(OrangeCheckboxStyle())
                        .disabled(runner.isRunning)
                    Toggle("Deep wipe (zero whole device)", isOn: $deepWipe)
                        .toggleStyle(OrangeCheckboxStyle())
                        .disabled(runner.isRunning)
                        .help(deepWipeEstimate)
                    Spacer()
                    if runner.isRunning { ProgressView().controlSize(.small) }
                    if let target = ejectTarget {
                        Button("Eject") {
                            runner.eject(target) { rescan() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(runner.isRunning)
                        .help("Eject \(target.id) so it is safe to unplug")
                    } else {
                        Button(dryRun ? "Preview" : "Erase & Format") { confirming = true }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canFormat)
                    }
                }
            }

            Divider()

            // Console
            HStack {
                Text("Console").font(.headline)
                Spacer()
                if runner.outcome == nil, let ok = runner.lastExitOK {
                    Text(ok ? "last run: OK" : "last run: FAILED")
                        .font(.caption)
                        .foregroundColor(ok ? .wipeoutSuccess : .wipeoutError)
                }
                Toggle("Show details", isOn: $showDetails)
                    .toggleStyle(OrangeCheckboxStyle())
                    .help("Show the raw diskutil output")
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.console, forType: .string)
                }
                .help("Copy the full raw log")
                .disabled(runner.console.isEmpty)
                Button("Clear") { runner.clear() }
                    .disabled(runner.isRunning || runner.console.isEmpty)
            }

            if let outcome = runner.outcome {
                OutcomeBanner(outcome: outcome)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if runner.lines.isEmpty {
                            Text("Idle. Pick a drive and a format, then click Erase & Format.")
                                .foregroundColor(.secondary)
                        }
                        ForEach(runner.lines.filter { showDetails || $0.level != .detail }) { line in
                            ConsoleLineView(line: line)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .onChange(of: runner.lines.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: showDetails) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            // Only add a ToolbarItem when an update exists. 0.4.14–0.4.17 always
            // attached a zero-size placeholder so the compact title-bar height
            // would stay put; on macOS 26 that empty item still drew a vacant
            // glass capsule at the trailing edge. The compact title bar itself
            // stays in the chrome via .windowToolbarStyle(.unifiedCompact), so
            // showing or hiding the button does not change the window size.
            if let update = availableUpdate {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) {
                        updateToolbarButton(update)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        updateToolbarButton(update)
                    }
                }
            }
        }
        .onChange(of: showingUpdatePopover) { open in
            // Clicking outside must not lose the download / checksum UI;
            // the popover stays up until relaunch or an error.
            if !open && updateInstall.isBusy {
                DispatchQueue.main.async { showingUpdatePopover = true }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { labelFocused = false }
        .onChange(of: settingsKey) { _ in runner.clearReady() }
        .onChange(of: runner.lastExitOK) { ok in
            if ok == false { showDetails = true }
        }
        .onAppear {
            rescan()
            checkForUpdatesOnce()
            MainWindowMetrics.raiseSavedFrameIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                labelFocused = false
                for w in NSApp.windows where w.isVisible { w.makeFirstResponder(nil) }
                MainWindowMetrics.raiseSavedFrameIfNeeded()
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

                Every partition on this device will be destroyed and replaced with one \(fs.diskutilType(ntfsPersonality: runner.ntfsFormatter?.personality)) partition named \(FormatRunner.sanitize(volumeName, for: fs)) on \(fs.allowsSchemeOverride ? uefiScheme : fs.scheme).\(deepWipe ? "\n\nDeep wipe is on: \(deepWipeEstimate)" : "")
                """)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func updateToolbarButton(_ update: UpdateInfo) -> some View {
        Button {
            showingUpdatePopover = true
        } label: {
            Label {
                Text("Update")
            } icon: {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Color.wipeoutAccent)
            }
        }
        .labelStyle(.titleAndIcon)
        .help("Version \(update.remoteVersion) is available (you have \(BuildInfo.version)).")
        .popover(isPresented: $showingUpdatePopover, arrowEdge: .bottom) {
            updatePopover(update)
        }
        // Keep a standard toolbar inset from the trailing edge;
        // the 0.4.14 filled pill sat flush against it.
        .padding(.trailing, 10)
    }

    @ViewBuilder
    private func updatePopover(_ update: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if updateInstall.phase == .idle {
                Text(updateMessage.isEmpty
                     ? "Version \(update.remoteVersion) is available (you have \(BuildInfo.version))."
                     : updateMessage)
                    .font(.callout)
                    .foregroundColor(updateMessage.isEmpty ? .primary : .wipeoutError)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                UpdateInstallProgressView(installer: updateInstall)
            }

            if !updateInstall.isBusy {
                HStack {
                    Button("Update") { installUpdate() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button("Later") {
                        showingUpdatePopover = false
                        availableUpdate = nil
                        updateMessage = ""
                        updateInstall.reset()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func checkForUpdatesOnce() {
        guard !didCheckForUpdates else { return }
        didCheckForUpdates = true
        guard checkAtLaunch else { return }
        Task {
            let info = await UpdateChecker.check()
            if info.isNewer {
                availableUpdate = info
            }
        }
    }

    private func installUpdate() {
        guard availableUpdate != nil else { return }
        updateMessage = ""
        showingUpdatePopover = true
        Task {
            do {
                try await updateInstall.start()
                NSApplication.shared.terminate(nil)
            } catch {
                updateMessage = error.localizedDescription
            }
        }
    }

    private func rescan() {
        runner.refreshNTFSSupport()
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
        runner.start(disk: d, fs: fs, volumeName: volumeName, dryRun: dryRun, deepWipe: deepWipe,
                     schemeOverride: fs.allowsSchemeOverride ? uefiScheme : nil,
                     settingsKey: settingsKey)
    }
}

// MARK: - Console views

private struct ConsoleLineView: View {
    let line: ConsoleLine

    var body: some View {
        switch line.level {
        case .detail:
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.leading, 22)
        default:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundColor(color)
                    .frame(width: 16)
                Text(line.text)
                    .font(line.level == .step ? .callout.weight(.semibold) : .callout)
                    .foregroundColor(line.level == .step || line.level == .info ? .primary : color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch line.level {
        case .step: return "arrow.right.circle"
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .detail: return "circle"
        }
    }

    private var color: Color {
        switch line.level {
        case .step: return .primary
        case .info: return .secondary
        case .success: return .wipeoutSuccess
        case .warning: return .wipeoutWarning
        case .error: return .wipeoutError
        case .detail: return .secondary
        }
    }
}

private struct OutcomeBanner: View {
    let outcome: RunOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.14))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.45)))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var title: String {
        switch outcome {
        case .success(let t, _), .preview(let t, _), .failure(let t, _), .ejected(let t, _): return t
        }
    }

    private var detail: String {
        switch outcome {
        case .success(_, let d), .preview(_, let d), .failure(_, let d), .ejected(_, let d): return d
        }
    }

    private var symbol: String {
        switch outcome {
        case .success: return "checkmark.seal.fill"
        case .preview: return "eye"
        case .failure: return "xmark.octagon.fill"
        case .ejected: return "eject.circle.fill"
        }
    }

    private var color: Color {
        switch outcome {
        case .success, .ejected: return .wipeoutSuccess
        case .preview: return .secondary
        case .failure: return .wipeoutError
        }
    }
}

// MARK: - Palette and control styles (mockup A, 0.3.11)

private func dynamicColor(light: UInt32, dark: UInt32) -> Color {
    func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
    })
}

extension Color {
    /// Icon orange. Checkbox fills, button edges.
    static let wipeoutAccent = dynamicColor(light: 0xFE5000, dark: 0xFE5000)
    /// Deeper icon orange for fills behind white text (5.0:1 with white).
    static let wipeoutAccentFill = dynamicColor(light: 0xC93F00, dark: 0xC93F00)
    /// Warnings are yellow so they never read as the accent orange.
    static let wipeoutWarning = dynamicColor(light: 0xB88A00, dark: 0xFFD60A)
    static let wipeoutSuccess = dynamicColor(light: 0x248A3D, dark: 0x30D158)
    static let wipeoutError = dynamicColor(light: 0xD70015, dark: 0xFF453A)
}

/// Filled orange primary button. Ignores the system accent color on purpose.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.wipeoutAccentFill)
                        .brightness(configuration.isPressed ? -0.08 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.wipeoutAccent, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Checkbox that is orange when checked, regardless of the system accent color.
struct OrangeCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        OrangeCheckbox(configuration: configuration)
    }

    private struct OrangeCheckbox: View {
        let configuration: ToggleStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(configuration.isOn ? Color.wipeoutAccent : Color(nsColor: .controlBackgroundColor))
                        RoundedRectangle(cornerRadius: 3.5)
                            .strokeBorder(configuration.isOn ? Color.wipeoutAccent : Color.secondary.opacity(0.6),
                                          lineWidth: 1)
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "checked" : "unchecked")
        }
    }
}
