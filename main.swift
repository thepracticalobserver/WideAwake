import Cocoa
import SwiftUI
import Combine
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Model

final class Model: ObservableObject {
    let interval: TimeInterval = 30

    @Published var isActive = false
    /// Independent of the mouse nudge: holds system and display sleep assertions only (no input
    /// events), so the screen never goes dark but nothing moves your cursor.
    @Published var caffeineOn = false
    @Published var startedAt: Date?
    @Published var lastMove: Date?
    @Published var nextMove: Date?
    @Published var moveCount = 0
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var presented = false
    @Published var arrowX: CGFloat = 150

    var onActiveChanged: (() -> Void)?

    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var systemSleepAssertion: IOPMAssertionID = 0
    private var userActivityAssertion: IOPMAssertionID = 0
    private var caffeineAssertion: IOPMAssertionID = 0
    private var caffeineDisplayAssertion: IOPMAssertionID = 0

    func toggle() { isActive ? stop() : start() }

    func setCaffeine(_ on: Bool) {
        if on {
            if caffeineAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "WideAwake Caffeine" as CFString,
                                            &caffeineAssertion)
            }
            if caffeineDisplayAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "WideAwake Caffeine" as CFString,
                                            &caffeineDisplayAssertion)
            }
        } else {
            if caffeineAssertion != 0 {
                IOPMAssertionRelease(caffeineAssertion)
                caffeineAssertion = 0
            }
            if caffeineDisplayAssertion != 0 {
                IOPMAssertionRelease(caffeineDisplayAssertion)
                caffeineDisplayAssertion = 0
            }
        }
        caffeineOn = on
        onActiveChanged?()
    }

    func start() {
        // Posting synthetic mouse events requires the Accessibility permission
        // (shown as "Device Control and Data Access" on the newest macOS).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }

        isActive = true
        startedAt = Date()
        lastMove = nil
        moveCount = 0
        preventSleep()
        nudge()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.nudge() }
        onActiveChanged?()
    }

    func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
        nextMove = nil
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        if systemSleepAssertion != 0 {
            IOPMAssertionRelease(systemSleepAssertion)
            systemSleepAssertion = 0
        }
        onActiveChanged?()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item. Try moving the app to /Applications."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func preventSleep() {
        guard sleepAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "WideAwake is active" as CFString,
                                    &sleepAssertion)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "WideAwake is active" as CFString,
                                    &systemSleepAssertion)
    }

    /// Seconds since the last real or synthetic input of any kind (what apps like Slack read as "idle").
    private func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Mouse nudge plus a Shift tap, so both pointer and keyboard idle clocks reset.
    /// Skipped while you are actually using the Mac, so it never fights your cursor.
    private func nudge() {
        nextMove = Date().addingTimeInterval(interval)
        if idleSeconds() < 10 { return }

        if let start = CGEvent(source: nil)?.location {
            let moved = CGPoint(x: start.x + 5, y: start.y)
            for point in [moved, start] {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: down)?.post(tap: .cghidEventTap)
        }
        IOPMAssertionDeclareUserActivity("WideAwake nudge" as CFString, kIOPMUserActiveLocal, &userActivityAssertion)

        lastMove = Date()
        moveCount += 1
    }
}

// MARK: - Views

private let panelColor = Color(red: 0.08, green: 0.08, blue: 0.08)
// The single accent: a warm lamp amber for the bulb, countdown ring and Caffeine switch.
private let amber = Color(red: 0.91, green: 0.64, blue: 0.24)

private extension View {
    func card(radius: CGFloat = 16) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct PopoverView: View {
    @ObservedObject var model: Model

    var body: some View {
        // Per-frame updates while active so the ring sweeps smoothly; idle when off.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isActive)) { context in
            content(now: context.date)
        }
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 16).fill(panelColor))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.10), lineWidth: 1))
        // Timings measured from a reference recording: opens in ~0.15s from ~45% size with a tiny
        // overshoot; closes in ~0.2s shrinking toward the icon while fading.
        .scaleEffect(model.presented ? 1 : 0.4, anchor: UnitPoint(x: model.arrowX / 300, y: 0))
        .animation(model.presented ? .spring(response: 0.24, dampingFraction: 0.72)
                                   : .easeIn(duration: 0.2), value: model.presented)
        .opacity(model.presented ? 1 : 0)
        .animation(model.presented ? .easeOut(duration: 0.1) : .easeIn(duration: 0.18), value: model.presented)
    }

    private func content(now: Date) -> some View {
        let trusted = AXIsProcessTrusted()
        let remaining = model.nextMove.map { max(0, $0.timeIntervalSince(now)) } ?? model.interval
        let progress = model.isActive ? 1 - remaining / model.interval : 0

        return VStack(spacing: 16) {
            top(remaining: remaining, progress: progress, trusted: trusted)
            caffeine
            stats(now: now)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .environment(\.colorScheme, .dark)
    }

    /// Bulb inside the countdown ring (tap to toggle), status beside it.
    private func top(remaining: TimeInterval, progress: Double, trusted: Bool) -> some View {
        HStack(spacing: 16) {
            Button {
                // No withAnimation here: it would animate the text layout too. Only the bulb animates (below).
                model.toggle()
            } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(amber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: model.isActive ? "lightbulb.fill" : "lightbulb")
                        .font(.system(size: 34))
                        .foregroundStyle(model.isActive ? amber : Color.white.opacity(0.4))
                        .symbolEffect(.pulse, isActive: model.isActive)
                }
                .frame(width: 104, height: 104)
                .contentShape(Circle())
                .animation(.smooth, value: model.isActive)
            }
            .buttonStyle(.plain)
            .help(model.isActive ? "Click to turn off" : "Click to turn on")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(model.isActive ? amber : Color.white.opacity(0.25)).frame(width: 8, height: 8)
                    Text(model.isActive ? "Active" : "Off").font(.system(size: 20, weight: .medium)).lineLimit(1)
                }
                // The permission prompt lives in this line (not a separate banner) so the card never changes height.
                if !trusted {
                    Button("Allow access") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(.plain)
                    .help("Privacy & Security > Device Control and Data Access (called Accessibility on older macOS)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                } else {
                    Text(model.isActive ? "Next move in \(Int(remaining.rounded(.up)))s" : "Tap to start")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            // The text column takes whatever is left, so the ring never moves when the text changes.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 260)
        .card()
    }

    /// Separate keep-awake switch: no mouse movement, so the screensaver still runs when you are away.
    private var caffeine: some View {
        let covered = model.isActive  // Wide Awake already holds system and display sleep
        return HStack(spacing: 12) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 20))
                .foregroundStyle(model.caffeineOn && !covered ? amber : Color.white.opacity(0.4))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Caffeine").font(.system(size: 14, weight: .medium)).foregroundStyle(covered ? Color.white.opacity(0.5) : Color.white).lineLimit(1)
                Text(covered ? "Covered by WideAwake" : "Screen stays on")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(covered ? 0.4 : 0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Caffeine", isOn: Binding(get: { model.caffeineOn }, set: { model.setCaffeine($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(amber)
                .opacity(covered ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 260)
        .card()
        .help("Keeps your Mac and screen awake without moving the mouse")
    }

    private func stats(now: Date) -> some View {
        HStack(spacing: 0) {
            stat("Active for", model.startedAt.map { format(now.timeIntervalSince($0)) } ?? "-", on: model.isActive)
            stat("Moves", model.isActive ? "\(model.moveCount)" : "-", on: model.isActive)
            stat("Last move", model.lastMove.map { ago(now.timeIntervalSince($0)) } ?? "-", on: model.isActive)
        }
        .padding(.vertical, 16)
        .frame(width: 260)
        .card()
    }

    private func stat(_ title: String, _ value: String, on: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.4))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.system(size: 11)).foregroundStyle(Color.white.opacity(on ? 0.5 : 0.4)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        let muted = Color.white.opacity(0.36)
        return VStack(spacing: 8) {
            if let error = model.loginError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 16) {
                Text("WideAwake")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(muted.opacity(0.7))
                    .fixedSize()
                Spacer(minLength: 0)
                Button { model.setLaunchAtLogin(!model.launchAtLogin) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.launchAtLogin ? "checkmark.circle.fill" : "circle")
                        Text("Start at login").lineLimit(1).fixedSize()
                    }
                }
                Button { NSApp.terminate(nil) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("Quit")
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    /// Short relative time ("12s ago") so the stats columns stay evenly spaced.
    private func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s ago" : s < 3600 ? "\(s / 60)m ago" : "\(s / 3600)h ago"
    }

    private func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - App

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 17)
    private let model = Model()
    private var panel: Panel!
    private var hosting: NSHostingController<PopoverView>!
    private var fixedSize: NSSize?
    private var lastClose = Date.distantPast
    private var shadowTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = []  // the panel is sized once and never resized, so nothing can shift

        // A borderless panel instead of NSPopover: no system arrow, so the whole
        // surface is one uniform shade.
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered,
                      defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.hide()
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        model.onActiveChanged = { [weak self] in self?.updateIcon() }
        updateIcon()

        // Dev flag used to produce the README screenshots: `--snapshot out.png [--on]`.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1], active: args.contains("--on"), caffeine: args.contains("--caffeine"))
        }
    }

    private func snapshot(to path: String, active: Bool, caffeine: Bool = false) {
        model.presented = true
        model.caffeineOn = caffeine
        if active {
            model.isActive = true
            model.startedAt = Date(timeIntervalSinceNow: -754)
            model.lastMove = Date(timeIntervalSinceNow: -12)
            model.nextMove = Date(timeIntervalSinceNow: 18)
            model.moveCount = 25
        }
        let size = hosting.sizeThatFits(in: CGSize(width: 300, height: 1000))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentViewController = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let view = self.hosting.view
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    @objc private func togglePanel() {
        // Clicking the icon while open first resigns key (closing the panel); don't reopen it.
        if Date().timeIntervalSince(lastClose) < 0.25 { return }
        panel.isVisible ? hide() : show()
    }

    private func show() {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        hosting.view.layoutSubtreeIfNeeded()
        // With automatic sizing off, ask SwiftUI for the content size directly (once), with a safe fallback.
        let measured = hosting.sizeThatFits(in: CGSize(width: 300, height: 1000))
        let size = fixedSize ?? (measured.width > 50 && measured.height > 50 ? measured : NSSize(width: 300, height: 300))
        fixedSize = size

        var frame = NSRect(x: buttonRect.midX - size.width / 2, y: buttonRect.minY - size.height - 3,
                           width: size.width, height: size.height)
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - frame.width - 8)
        }
        // Point the arrow at the icon even when the panel is clamped to the screen edge.
        model.arrowX = min(max(buttonRect.midX - frame.minX, 28), size.width - 28)
        model.objectWillChange.send()  // refresh the permission banner

        // Pop out of the icon: SwiftUI scales/fades the content from its top edge with a spring.
        model.presented = false
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.model.presented = true }

        // The window shadow follows the content's alpha mask, so refresh it while the pop plays.
        shadowTimer?.invalidate()
        let started = Date()
        shadowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            self?.panel.invalidateShadow()
            if Date().timeIntervalSince(started) > 0.6 { t.invalidate() }
        }
    }

    private func hide() {
        guard panel.isVisible, model.presented else { return }
        lastClose = Date()
        model.presented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, !self.model.presented else { return }
            self.panel.orderOut(nil)
        }
    }

    private func updateIcon() {
        let on = model.isActive
        let caffeine = model.caffeineOn && !on
        let symbol = on ? "lightbulb.fill" : caffeine ? "cup.and.saucer.fill" : "lightbulb"
        let tip = on ? "WideAwake: on" : caffeine ? "Caffeine: on" : "WideAwake: off"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tip
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
