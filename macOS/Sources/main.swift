import AppKit
import AVFoundation
import Foundation
import IOKit
import IOKit.pwr_mgt

private let ioMessageCanSystemSleep: natural_t = 0xE0000270
private let ioMessageSystemWillSleep: natural_t = 0xE0000280
private let ioMessageSystemHasPoweredOn: natural_t = 0xE0000300
private let openSoundPreferenceKey = "openLidSoundFile"
private let wakeSoundDedupInterval: TimeInterval = 1.0
private let wakeRetryDelays: [TimeInterval] = [0.25, 0.75, 1.5]

private enum AppPaths {
    static func projectRoot() -> URL {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        // When running from an .app bundle the path is:
        //   <root>/OpenLidSounds.app/Contents/MacOS/OpenLidSounds
        // so we need 4 deletions to reach <root>.
        // When running the raw .build binary the path is:
        //   <root>/.build/release/OpenLidSounds  (3 deletions)
        // Detect by checking whether the 3-level parent ends in ".app".
        let threeUp = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if threeUp.pathExtension == "app" {
            return threeUp.deletingLastPathComponent()
        }
        return threeUp
    }

    static func soundEffectsDirectory() -> URL {
        projectRoot().appendingPathComponent("sound_effects", isDirectory: true)
    }
}

final class SoundCatalog {
    private let fileManager = FileManager.default
    private let supportedExtensions: Set<String> = ["aif", "aiff", "caf", "m4a", "mp3", "wav"]
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func availableSounds() -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}

final class SoundSelectionStore {
    private let defaults = UserDefaults.standard

    func loadSelection(for key: String, from availableSounds: [URL]) -> URL? {
        guard let storedName = defaults.string(forKey: key) else {
            return availableSounds.first
        }

        if let match = availableSounds.first(where: { $0.lastPathComponent == storedName }) {
            return match
        }

        return availableSounds.first
    }

    func saveSelection(_ soundURL: URL?, for key: String) {
        defaults.set(soundURL?.lastPathComponent, forKey: key)
    }
}

final class SoundPlayer: NSObject, NSSoundDelegate {
    private var openSoundURL: URL?
    private let fallbackOpenSoundPath = "/System/Library/Sounds/Glass.aiff"
    private var activeSounds: [NSSound] = []
    private var cachedPlayers: [String: AVAudioPlayer] = [:]

    func updateOpenSound(_ url: URL?) {
        openSoundURL = url
        if let url {
            _ = preparePlayer(for: url.path)
        }
    }

    @discardableResult
    func playOpenSound() -> Bool {
        let path = openSoundURL?.path ?? fallbackOpenSoundPath

        if playPreparedSound(at: path) {
            return true
        }

        return playSound(at: path)
    }

    @discardableResult
    private func playSound(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }

        guard let sound = NSSound(contentsOfFile: path, byReference: true) else {
            return false
        }

        sound.delegate = self
        activeSounds.append(sound)
        return sound.play()
    }

    private func preparePlayer(for path: String) -> AVAudioPlayer? {
        if let cached = cachedPlayers[path] {
            return cached
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.prepareToPlay()
            player.volume = 1.0
            cachedPlayers[path] = player
            return player
        } catch {
            return nil
        }
    }

    private func playPreparedSound(at path: String) -> Bool {
        guard let player = preparePlayer(for: path) else {
            return false
        }

        return startPreparedPlayer(player)
    }

    private func startPreparedPlayer(_ player: AVAudioPlayer) -> Bool {
        player.currentTime = 0
        player.prepareToPlay()
        return player.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        activeSounds.removeAll { $0 === sound }
    }
}

final class PowerEventMonitor {
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private let soundPlayer: SoundPlayer
    private var wakeObserver: NSObjectProtocol?
    private var lastWakeSoundTimestamp: Date?
    private var wakeAttemptGeneration: Int = 0

    init(soundPlayer: SoundPlayer) {
        self.soundPlayer = soundPlayer
    }

    func start() {
        var notificationPort: IONotificationPortRef?
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notificationPort,
            powerCallback,
            &notifier
        )

        guard rootPort != 0, let notificationPort else {
            return
        }

        self.notificationPort = notificationPort

        let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWakeSignal()
        }
    }

    func stop() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        if let notificationPort {
            let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }

        if notifier != 0 {
            IOObjectRelease(notifier)
            notifier = 0
        }

        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
    }

    func handlePowerMessage(messageType: natural_t, messageArgument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: messageArgument)

        switch messageType {
        case ioMessageCanSystemSleep:
            IOAllowPowerChange(rootPort, token)

        case ioMessageSystemWillSleep:
            IOAllowPowerChange(rootPort, token)

        case ioMessageSystemHasPoweredOn:
            handleWakeSignal()

        default:
            break
        }
    }



    private func handleWakeSignal() {
        let now = Date()
        if let lastWakeSoundTimestamp,
           now.timeIntervalSince(lastWakeSoundTimestamp) < wakeSoundDedupInterval {
            return
        }

        lastWakeSoundTimestamp = now
        wakeAttemptGeneration += 1
        let generation = wakeAttemptGeneration

        attemptOpenSoundPlayback(generation: generation)

        for delay in wakeRetryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attemptOpenSoundPlayback(generation: generation)
            }
        }
    }

    private func attemptOpenSoundPlayback(generation: Int) {
        guard generation == wakeAttemptGeneration else {
            return
        }

        if soundPlayer.playOpenSound() {
            wakeAttemptGeneration += 1
        }
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let sounds: [URL]
    private let selectionStore: SoundSelectionStore
    private let soundPlayer: SoundPlayer

    // filtered view driven by the search field
    private var filteredSounds: [URL] = []

    private let searchField = NSSearchField()
    private let tableView   = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    // tracks the actually-selected URL independently of the filtered list
    private var selectedSoundURL: URL?

    private static let columnID = NSUserInterfaceItemIdentifier("SoundName")

    init(sounds: [URL], selectionStore: SoundSelectionStore, soundPlayer: SoundPlayer) {
        self.sounds = sounds
        self.selectionStore = selectionStore
        self.soundPlayer = soundPlayer
        self.filteredSounds = sounds

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Open Lid Sound"
        window.center()
        super.init(window: window)

        buildUI()
        restoreSelection()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Title
        let titleLabel = NSTextField(labelWithString: "Open-lid sound")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Search field
        searchField.placeholderString = "Search sounds…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        (searchField.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false

        // Table view
        let column = NSTableColumn(identifier: Self.columnID)
        column.title = ""
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(previewSelection)
        tableView.target = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Preview button
        let previewButton = NSButton(title: "▶  Preview", target: self, action: #selector(previewSelection))
        previewButton.bezelStyle = .rounded
        previewButton.translatesAutoresizingMaskIntoConstraints = false

        // Status label
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.stringValue = sounds.isEmpty
            ? "Add audio files to sound_effects to choose a wake sound."
            : "Click to select · Double-click or ▶ to preview"

        contentView.addSubview(titleLabel)
        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        contentView.addSubview(previewButton)
        contentView.addSubview(statusLabel)

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: pad),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),

            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            scrollView.bottomAnchor.constraint(equalTo: previewButton.topAnchor, constant: -12),

            previewButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            previewButton.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -pad),
        ])
    }

    // MARK: - Selection persistence

    private func restoreSelection() {
        guard !sounds.isEmpty else { soundPlayer.updateOpenSound(nil); return }

        let saved = selectionStore.loadSelection(for: openSoundPreferenceKey, from: sounds) ?? sounds[0]
        selectedSoundURL = saved
        soundPlayer.updateOpenSound(saved)

        // Scroll to and highlight the saved row in the current filtered list
        if let row = filteredSounds.firstIndex(of: saved) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    private func applySelection(at row: Int) {
        guard row >= 0, row < filteredSounds.count else { return }
        let selected = filteredSounds[row]
        selectedSoundURL = selected
        selectionStore.saveSelection(selected, for: openSoundPreferenceKey)
        soundPlayer.updateOpenSound(selected)
        statusLabel.stringValue = "Selected: \(selected.lastPathComponent)"
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filteredSounds = query.isEmpty
            ? sounds
            : sounds.filter { $0.lastPathComponent.lowercased().contains(query) }
        tableView.reloadData()

        // Re-highlight selected item if still visible
        if let current = selectedSoundURL,
           let row = filteredSounds.firstIndex(of: current) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }

        statusLabel.stringValue = filteredSounds.isEmpty
            ? "No results for \"\(searchField.stringValue)\""
            : "\(filteredSounds.count) sound\(filteredSounds.count == 1 ? "" : "s")"
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { filteredSounds.count }

    func tableView(_ tableView: NSTableView,
                   objectValueFor tableColumn: NSTableColumn?,
                   row: Int) -> Any? {
        filteredSounds[row].lastPathComponent
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        applySelection(at: row)
    }

    // MARK: - Actions

    @objc private func previewSelection() {
        _ = soundPlayer.playOpenSound()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let soundCatalog = SoundCatalog(directory: AppPaths.soundEffectsDirectory())
    private let selectionStore = SoundSelectionStore()
    private let soundPlayer = SoundPlayer()
    private var monitor: PowerEventMonitor?
    private var settingsWindowController: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another copy is already running, quit immediately.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.openlidsounds.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        let sounds = soundCatalog.availableSounds()
        let initialOpenSound = selectionStore.loadSelection(for: openSoundPreferenceKey, from: sounds)
        soundPlayer.updateOpenSound(initialOpenSound)

        let monitor = PowerEventMonitor(soundPlayer: soundPlayer)
        monitor.start()
        self.monitor = monitor

        let settingsWindowController = SettingsWindowController(
            sounds: sounds,
            selectionStore: selectionStore,
            soundPlayer: soundPlayer
        )
        self.settingsWindowController = settingsWindowController

        setupStatusItem()
        settingsWindowController.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openSettings() {
        settingsWindowController?.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(self)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "Lid"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Open Lid Sound", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }

        statusItem?.menu = menu
    }
}

private func powerCallback(
    context: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }

    let monitor = Unmanaged<PowerEventMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handlePowerMessage(messageType: messageType, messageArgument: messageArgument)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
