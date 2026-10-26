import AppKit
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape { onEscape() } else { super.keyDown(with: event) }
    }
}

/// A hosting view that takes the very first click. Without this, a click on a panel of an
/// app that isn't in front only focuses the panel, and a second click is needed to act.
class ClickThroughHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The indicator's host, which also reports right-clicks so the indicator can open Settings.
final class IndicatorHost<Content: View>: ClickThroughHost<Content> {
    var onRightClick: (() -> Void)?
    /// When set, the host tells a click from a drag itself: a click calls `onClick`, and a
    /// drag hands the window to the window server to move (if `canDrag` says so).
    var onClick: (() -> Void)?
    var canDrag: () -> Bool = { false }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick() } else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick, let window else { return super.mouseDown(with: event) }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                onClick()
                return
            }
            let moved = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            if moved > 3 && canDrag() {
                // This returns before the drag ends; the controller saves the spot from the
                // window's own move notifications instead.
                window.performDrag(with: event)
                return
            }
        }
    }
}

/// Owns everything on screen: the indicator (corner tray or notch wings) that opens the
/// session list, and the menu bar item that opens Settings.
@MainActor
final class Controller: NSObject {
    private enum Sheet { case list, launcher, settings }
    private enum Anchor { case indicator, statusItem }

    private let store: SessionStore
    private var indicatorPanel: FloatingPanel!
    private var trayHost: GlassHost<TrayView>!
    private var notchHost: IndicatorHost<NotchView>?
    private var sheetPanel: FloatingPanel!
    private var sheet: Sheet?
    private var anchor: Anchor = .indicator
    private var statusItem: NSStatusItem?
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var snoozedUntil: Date?
    /// True while the controller itself moves the indicator, so only the person's drags are saved.
    private var placingIndicator = false

    /// Called each time Settings opens, to refresh what it shows about notification permission.
    var onSettingsShown: () -> Void = {}

    private static let margin: CGFloat = 2

    init(store: SessionStore) {
        self.store = store
        super.init()

        trayHost = GlassHost(rootView: TrayView(store: store, onTap: { [weak self] in self?.toggle(.list, from: .indicator) }),
                             radius: TrayView.radius)
        trayHost.host.onRightClick = { [weak self] in self?.toggle(.settings, from: .indicator) }
        trayHost.host.onClick = { [weak self] in self?.toggle(.list, from: .indicator) }
        trayHost.host.canDrag = { [weak self] in self?.store.state.placement == .free }
        indicatorPanel = makePanel()
        indicatorPanel.isMovable = true
        indicatorPanel.contentView = trayHost

        sheetPanel = makePanel()
        sheetPanel.onEscape = { [weak self] in self?.closeSheet() }

        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(indicatorMoved), name: NSWindow.didMoveNotification, object: indicatorPanel)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(environmentChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        layout()
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    @objc private func environmentChanged() { layout() }

    /// In Free mode, remembers every spot the person drags the tray to.
    @objc private func indicatorMoved() {
        guard !placingIndicator, store.state.placement == .free, indicatorPanel.contentView === trayHost else { return }
        store.setFreeOrigin(indicatorPanel.frame.origin)
    }

    // MARK: Indicator

    private var terminalIsFrontmost: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if let id = front.bundleIdentifier, TerminalFinder.knownTerminals.contains(id) { return true }
        return store.hostAppPids.contains(front.processIdentifier)
    }

    private var shouldShowIndicator: Bool {
        if store.state.placement == .menuBarOnly { return false }
        if let until = snoozedUntil {
            if until > Date() { return false }
            snoozedUntil = nil
        }
        if store.threads.isEmpty { return false }
        // The notch stays clickable everywhere: over the notch it covers nothing.
        if store.state.placement == .notch && notchScreen != nil { return true }
        if sheet != nil && anchor == .indicator { return true }
        if store.state.hideInTerminal && terminalIsFrontmost { return false }
        return true
    }

    private var notchScreen: NSScreen? { NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) }

    /// The wings show their counts unless a terminal is in front and the person asked for
    /// quiet there; the notch itself stays clickable either way.

    private func layout() {
        updateStatusItem()
        if shouldShowIndicator {
            if store.state.placement == .notch, let screen = notchScreen, let notch = Self.notchRect(on: screen) {
                showNotch(notch)
            } else {
                showTray()
            }
            indicatorPanel.orderFrontRegardless()
        } else {
            indicatorPanel.orderOut(nil)
            if anchor == .indicator, sheet != nil { closeSheet() }
        }
        if sheet != nil { positionSheet() }
    }

    private var indicatorIsNotch: Bool { notchHost != nil && indicatorPanel.contentView === notchHost }

    private func showTray() {
        if indicatorPanel.contentView !== trayHost { indicatorPanel.contentView = trayHost }
        indicatorPanel.level = .statusBar
        guard let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let size = trayHost.fittingSize
        let origin: NSPoint
        if store.state.placement == .free {
            origin = freeOrigin(size: size)
        } else if store.state.placement == .notch {
            // A Mac without a notch: the same tray, centred under the menu bar.
            origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height)
        } else {
            let corner = store.state.corner
            origin = NSPoint(
                x: corner.isRight ? area.maxX - size.width - Self.margin : area.minX + Self.margin,
                y: corner.isBottom ? area.minY + Self.margin : area.maxY - size.height - Self.margin)
        }
        indicatorPanel.hasShadow = true
        setFrame(indicatorPanel, NSRect(origin: origin, size: size))
    }

    private func showNotch(_ notch: NSRect) {
        let t = Tally(store)
        let quiet = store.state.hideInTerminal && terminalIsFrontmost && !(sheet != nil && anchor == .indicator)
        let free = MenuBarSpace.free(beside: notch)
        // Both wings are always the same width, set by the tighter side, so the notch stays
        // centred. They show while there is anything to count, and only if both sides have room.
        let fit = min(NotchView.wing, min(free.left, free.right) - 6)
        let show = !quiet && (t.needs > 0 || t.running > 0) && fit >= 30
        let left: CGFloat = show ? fit : 0
        let right: CGFloat = show ? fit : 0
        let view = NotchView(store: store, notchWidth: notch.width, height: notch.height, leftWing: left, rightWing: right,
                             onTap: { [weak self] in self?.toggle(.list, from: .indicator) })
        if let host = notchHost {
            host.rootView = view
        } else {
            let host = IndicatorHost(rootView: view)
            host.sizingOptions = []
            host.onRightClick = { [weak self] in self?.toggle(.settings, from: .indicator) }
            notchHost = host
        }
        if indicatorPanel.contentView !== notchHost { indicatorPanel.contentView = notchHost }
        // Above the menu bar, so the panel can sit over the notch itself.
        indicatorPanel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        let frame = NSRect(x: notch.minX - left, y: notch.minY, width: notch.width + left + right, height: notch.height)
        // It reads as part of the notch, so it casts no shadow.
        indicatorPanel.hasShadow = false
        setFrame(indicatorPanel, frame)
    }

    /// Where the person dragged the tray, kept on whichever screen it is on (it starts in the
    /// bottom-right corner). Dragging moves its left edge; the tray grows to the right.
    private func freeOrigin(size: NSSize) -> NSPoint {
        let fallback = NSScreen.screens.first?.visibleFrame ?? .zero
        guard let x = store.state.freeX, let y = store.state.freeY else {
            return NSPoint(x: fallback.maxX - size.width - Self.margin, y: fallback.minY + Self.margin)
        }
        let point = NSPoint(x: x, y: y)
        let area = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame ?? fallback
        return NSPoint(x: min(max(point.x, area.minX), area.maxX - size.width),
                       y: min(max(point.y, area.minY), area.maxY - size.height))
    }

    /// Moves a panel and, when its shape changed, has the window server redraw the shadow
    /// from the new content once SwiftUI has drawn it.
    private func setFrame(_ panel: NSPanel, _ frame: NSRect) {
        let resized = panel.frame.size != frame.size
        placingIndicator = true
        panel.setFrame(frame, display: true)
        placingIndicator = false
        guard resized, panel.hasShadow else { return }
        DispatchQueue.main.async { panel.invalidateShadow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { panel.invalidateShadow() }
    }

    /// The notch in global coordinates, from the parts of the menu bar either side of it.
    private static func notchRect(on screen: NSScreen) -> NSRect? {
        let height = screen.safeAreaInsets.top
        guard height > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return nil }
        return NSRect(x: screen.frame.minX + left.width, y: screen.frame.maxY - height, width: width, height: height)
    }

    // MARK: Menu bar item (opens Settings)

    private func updateStatusItem() {
        let wanted = store.state.showMenuBar || store.state.placement == .menuBarOnly
        if !wanted {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
                if anchor == .statusItem { closeSheet() }
            }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.imagePosition = .imageLeading
            statusItem = item
        }
        let t = Tally(store)
        guard let button = statusItem?.button else { return }
        button.image = StatusGlyph.image(t.needs > 0 ? .attention : (t.running > 0 ? .running : .quiet))
        button.title = ""
        button.toolTip = "AgentNudge"
        button.setAccessibilityLabel(t.spoken)
    }

    @objc private func statusItemClicked() {
        toggle(.settings, from: .statusItem)
    }

    // MARK: List and Settings sheets

    private func toggle(_ kind: Sheet, from source: Anchor) {
        if sheet == kind && anchor == source {
            closeSheet()
            return
        }
        open(kind, from: source)
    }

    func showSettings() {
        open(.settings, from: statusItem != nil ? .statusItem : .indicator)
    }

    func showList() {
        open(.list, from: .indicator)
    }

    private func open(_ kind: Sheet, from source: Anchor) {
        anchor = source
        sheet = kind
        switch kind {
        case .list:
            store.refresh()
            sheetPanel.contentView = GlassHost(rootView: ListView(store: store, onOpen: { [weak self] t in self?.openThread(t) },
                                                                  onLaunched: { [weak self] in self?.closeSheet() }),
                                               radius: ListView.radius)
        case .launcher:
            sheetPanel.contentView = GlassHost(rootView: ListView(store: store, onOpen: { [weak self] t in self?.openThread(t) },
                                                                  onLaunched: { [weak self] in self?.closeSheet() }, launching: true),
                                               radius: ListView.radius)
        case .settings:
            sheetPanel.contentView = GlassHost(rootView: SettingsPanel(store: store, onQuit: { NSApp.terminate(nil) }, onShown: onSettingsShown),
                                               radius: SettingsPanel.radius)
        }
        sheetPanel.hasShadow = true
        layout()
        positionSheet()
        sheetPanel.alphaValue = 0
        sheetPanel.orderFrontRegardless()
        sheetPanel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            sheetPanel.animator().alphaValue = 1
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeSheet() }
            }
        }
        if kind == .settings, !store.state.onboarded { store.markOnboarded() }
    }

    func closeSheet() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        sheet = nil
        sheetPanel.orderOut(nil)
        sheetPanel.contentView = nil
        layout()
    }

    private func positionSheet() {
        guard let content = sheetPanel.contentView, let screen = NSScreen.screens.first else { return }
        let size = content.fittingSize
        let bounds = screen.visibleFrame
        var origin: NSPoint
        switch anchor {
        case .statusItem:
            guard let item = statusItem?.button?.window?.frame else { return }
            origin = NSPoint(x: item.midX - size.width / 2, y: item.minY - size.height - 6)
        case .indicator:
            let ind = indicatorPanel.frame
            if indicatorIsNotch {
                origin = NSPoint(x: ind.midX - size.width / 2, y: ind.minY - size.height - 8)
            } else if store.state.placement == .corner || store.state.placement == .free {
                // Open toward the middle of the screen: up from a low tray, down from a high one,
                // and lined up with whichever edge of the tray is nearer the screen's side.
                let corner = store.state.corner
                let screen = NSScreen.screens.first(where: { $0.frame.intersects(ind) })?.frame ?? bounds
                let low = store.state.placement == .free ? ind.midY < screen.midY : corner.isBottom
                let right = store.state.placement == .free ? ind.midX > screen.midX : corner.isRight
                origin = NSPoint(
                    x: right ? ind.maxX - size.width : ind.minX,
                    y: low ? ind.maxY + 8 : ind.minY - size.height - 8)
            } else {
                origin = NSPoint(x: ind.midX - size.width / 2, y: ind.minY - size.height - 8)
            }
        }
        origin.x = min(max(origin.x, bounds.minX + 6), bounds.maxX - size.width - 6)
        origin.y = min(max(origin.y, bounds.minY + 6), bounds.maxY - size.height - 6)
        setFrame(sheetPanel, NSRect(origin: origin, size: size))
    }

    private func openThread(_ t: AgentThread) {
        closeSheet()
        store.open(t)
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: URL commands (agentnudge://list, new, settings, close, snooze, open?id=)
    //
    // Any web page or app can open these URLs, so none of them runs anything: they only
    // show AgentNudge's own UI or focus an existing session. Starting a session always
    // takes a click in the launcher.

    func handle(_ url: URL) {
        switch url.host {
        case "list": showList()
        case "new": open(.launcher, from: .indicator)
        case "open":
            // agentnudge://open?id=<session id>
            if let id = query(url)["id"], let t = store.threads.first(where: { $0.id == id }) { openThread(t) }

        case "settings": showSettings()
        case "close": closeSheet()
        case "snooze":
            snoozedUntil = Date().addingTimeInterval(3600)
            layout()
        default: break
        }
    }
}
