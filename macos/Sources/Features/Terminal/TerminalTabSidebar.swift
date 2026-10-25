import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the tabs of any terminal window may have changed: their order, titles,
    /// colors, key equivalents, or which one is selected.
    static let terminalTabsDidChange = Notification.Name("com.mitchellh.ghostty.terminalTabsDidChange")
}

/// The tabs of one terminal window's tab group, as listed by the vertical tab sidebar.
///
/// Every tab is its own window, so each window owns a model and shows its own copy of the
/// sidebar. Only the selected tab's window is on screen, so that is the copy the user sees.
@MainActor
final class TerminalTabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier

        /// The 1-based position of the tab in its window.
        let index: Int
        let title: String
        let keyEquivalent: String?
        let color: TerminalTabColor
        let isSelected: Bool
    }

    @Published private(set) var tabs: [Tab] = []

    /// The window this sidebar is shown in.
    weak var window: NSWindow? {
        didSet {
            observeWindowClose()
            refresh()
        }
    }

    /// Whether the window uses `macos-titlebar-style = vertical-tabs`.
    var showsSidebar: Bool {
        (window as? TerminalWindow)?.showsTabSidebar ?? false
    }

    private var observer: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .terminalTabsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer is delivered on the main queue.
            MainActor.assumeIsolated {
                self?.refresh()

                // The tab group takes an event loop cycle to settle after a tab is added or closed.
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// Forgets the window once it closes. Asking AppKit for a closed window's tabs (as a
    /// late refresh would) registers it with a tab group again, which keeps it alive.
    private func observeWindowClose() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        guard let window else { return }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window = nil
            }
        }
    }

    /// The windows in our tab group in tab order. A window that isn't tabbed is its own only tab.
    private var tabWindows: [NSWindow] {
        guard let window else { return [] }
        return window.tabbedWindows ?? [window]
    }

    func refresh() {
        // The window only carries a key equivalent label while it is in a tab group, so a
        // lone tab would have none. Look the shortcuts up from the keybinds instead.
        let config = (window?.windowController as? BaseTerminalController)?.ghostty.config
        let newTabs = tabWindows.enumerated().map { offset, tabWindow in
            let index = offset + 1
            let shortcut = index <= 9 ? config?.keyboardShortcut(for: "goto_tab:\(index)") : nil
            return Tab(
                id: ObjectIdentifier(tabWindow),
                index: index,
                title: tabWindow.title,
                keyEquivalent: shortcut.map { "\($0)" },
                color: (tabWindow as? TerminalWindow)?.tabColor ?? .none,
                // Our window is only on screen while it is the selected tab.
                isSelected: tabWindow === window
            )
        }

        guard newTabs != tabs else { return }
        tabs = newTabs
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func select(_ tab: Tab) {
        tabWindow(for: tab)?.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        controller(for: tab)?.closeTab(nil)
    }

    func closeOthers(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.closeOtherTabs(nil)
    }

    func closeBelow(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.closeTabsOnTheRight(nil)
    }

    func moveToNewWindow(_ tab: Tab) {
        tabWindow(for: tab)?.moveTabToNewWindow(nil)
    }

    func showAllTabs() {
        window?.toggleTabOverview(nil)
    }

    func promptTitle(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.promptTabTitle()
    }

    func setColor(_ color: TerminalTabColor, for tab: Tab) {
        (tabWindow(for: tab) as? TerminalWindow)?.tabColor = color
    }

    /// Moves a tab so it sits before the tab now at `slot`, or last when `slot` is the
    /// number of tabs. The selected tab stays selected and every tab keeps its terminal:
    /// only the tab group's order changes.
    func move(_ tab: Tab, toSlot slot: Int) {
        let windows = tabWindows
        guard let source = windows.firstIndex(where: { ObjectIdentifier($0) == tab.id }),
              let destination = TerminalTabSidebar.destinationIndex(
                movingFrom: source,
                toSlot: slot,
                count: windows.count),
              let tabGroup = window?.tabGroup
        else { return }

        let moving = windows[source]
        var remaining = windows
        remaining.remove(at: source)
        let selected = tabGroup.selectedWindow

        // Like `move_tab`, take the window out of the group and add it back beside its new
        // neighbor, without animation so the window never shows on its own.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        tabGroup.removeWindow(moving)
        if destination == 0 {
            remaining[0].addTabbedWindowSafely(moving, ordered: .below)
        } else {
            remaining[destination - 1].addTabbedWindowSafely(moving, ordered: .above)
        }

        if let selected {
            tabGroup.selectedWindow = selected
            selected.makeKey()
        }

        NSAnimationContext.endGrouping()

        // The key equivalents follow the position, so relabel. This also refreshes the sidebar.
        ((selected ?? moving).windowController as? TerminalController)?.relabelTabs()
    }

    /// The right-click menu for a tab. It has the same items as a native tab's menu, including
    /// the tab color palette, which is why it is an AppKit menu: the palette is a custom menu
    /// item view and SwiftUI menus can't hold one.
    func contextMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let hasOtherTabs = tabs.count > 1
        menu.addItem(menuItem("Close Tab", symbol: "xmark") { [weak self] in
            self?.close(tab)
        })
        menu.addItem(menuItem("Close Other Tabs", symbol: "xmark", isEnabled: hasOtherTabs) { [weak self] in
            self?.closeOthers(tab)
        })
        menu.addItem(menuItem("Close Tabs to the Right", symbol: "xmark", isEnabled: tab.index < tabs.count) { [weak self] in
            self?.closeBelow(tab)
        })
        menu.addItem(menuItem("Move Tab to New Window", symbol: "macwindow.badge.plus", isEnabled: hasOtherTabs) { [weak self] in
            self?.moveToNewWindow(tab)
        })
        menu.addItem(menuItem("Show All Tabs") { [weak self] in
            self?.showAllTabs()
        })

        menu.addItem(.separator())
        menu.addItem(menuItem("Rename Tab...", symbol: "pencil.line") { [weak self] in
            self?.promptTitle(tab)
        })

        let palette = NSHostingView(rootView: TabColorMenuView(selectedColor: tab.color) { [weak self] color in
            self?.setColor(color, for: tab)
        })
        palette.frame.size = palette.intrinsicContentSize
        let paletteItem = NSMenuItem()
        paletteItem.view = palette
        menu.addItem(paletteItem)

        return menu
    }

    private func menuItem(
        _ title: String,
        symbol: String? = nil,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
        item.target = action
        // The item's target is weak, so the item itself keeps the action alive.
        item.representedObject = action
        item.isEnabled = isEnabled
        if let symbol {
            item.setImageIfDesired(systemSymbolName: symbol)
        }
        return item
    }

    /// Runs a closure as a menu item's action.
    private final class MenuAction: NSObject {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        // Not named `perform(_:)`: `#selector` would resolve that to NSObject's
        // `performSelector:`, which treats the menu item as a selector and aborts.
        @objc func run(_ sender: Any?) {
            handler()
        }
    }

    private func tabWindow(for tab: Tab) -> NSWindow? {
        tabWindows.first { ObjectIdentifier($0) == tab.id }
    }

    private func controller(for tab: Tab) -> TerminalController? {
        tabWindow(for: tab)?.windowController as? TerminalController
    }
}

/// Places the vertical tab sidebar beside a terminal window's content.
struct TerminalTabSidebarLayout<Content: View>: View {
    @ObservedObject var model: TerminalTabSidebarModel
    @ObservedObject var ghostty: Ghostty.App
    let content: Content

    @AppStorage(TerminalTabSidebar.collapsedKey) private var isCollapsed = false
    @AppStorage(TerminalTabSidebar.widthKey) private var width = TerminalTabSidebar.defaultWidth

    /// The sidebar width when the current resize drag began.
    @State private var widthAtDragStart: Double?

    init(model: TerminalTabSidebarModel, ghostty: Ghostty.App, @ViewBuilder content: () -> Content) {
        self.model = model
        self.ghostty = ghostty
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.showsSidebar {
                TerminalTabSidebar(model: model, isCollapsed: $isCollapsed)
                    .frame(width: isCollapsed ? TerminalTabSidebar.collapsedWidth : width)
                    .background(ghostty.config.backgroundColor.opacity(ghostty.config.backgroundOpacity))
                    .environment(\.colorScheme, NSColor(ghostty.config.backgroundColor).isLightColor ? .light : .dark)

                divider
                    // The grab strip reaches over the terminal's edge, so it has to sit
                    // above the terminal to be reachable from that side too.
                    .zIndex(1)
            }

            content
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: TerminalTabSidebar.dividerWidth)
            .overlay {
                if !isCollapsed {
                    // A wider invisible strip so the divider is easy to grab. The cursor is
                    // set like the split divider's: the terminal sets its own pointer style,
                    // which a pushed cursor can't reliably win against.
                    Color.clear
                        .frame(width: 7)
                        .contentShape(Rectangle())
                        .backport.pointerStyle(.resizeLeftRight)
                        .onHover { isHovering in
                            // macOS 15+ uses the pointer style above.
                            if #available(macOS 15, *) { return }

                            if isHovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(resizeGesture)
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = widthAtDragStart ?? width
                widthAtDragStart = start
                let range = TerminalTabSidebar.widthRange
                width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                widthAtDragStart = nil
            }
    }
}

/// The vertical list of a terminal window's tabs, replacing the native tab bar.
struct TerminalTabSidebar: View {
    static let collapsedKey = "TerminalTabSidebarCollapsed"
    static let widthKey = "TerminalTabSidebarWidth"
    static let defaultWidth: Double = 200
    static let widthRange: ClosedRange<Double> = 120...400
    static let collapsedWidth: Double = 40
    static let dividerWidth: Double = 1

    /// Every row has the same height, so a tab's position in the list is a multiple of
    /// the pitch and dragging needs no measuring. Rows are tall enough for a two-line title.
    static let rowHeight: CGFloat = 52
    static let rowCornerRadius: CGFloat = 12
    static let tileSize: CGFloat = 30
    static let rowSpacing: CGFloat = 2

    /// The slot a tab dragged from `index` by `offset` points would be dropped into. Slot
    /// `n` means before the tab at `n`, and `count` means after the last tab. The tab moves
    /// past a neighbor once its center crosses the neighbor's center.
    static func dropSlot(from index: Int, offset: CGFloat, pitch: CGFloat, count: Int) -> Int {
        let slot = (CGFloat(index) + 1 + offset / pitch).rounded(.down)
        return min(max(Int(slot), 0), count)
    }

    /// Where a tab moving from `source` to `slot` ends up once it is out of its old place,
    /// or nil when the drop leaves it where it is.
    static func destinationIndex(movingFrom source: Int, toSlot slot: Int, count: Int) -> Int? {
        guard (0..<count).contains(source), (0...count).contains(slot) else { return nil }
        guard slot != source, slot != source + 1 else { return nil }
        return slot > source ? slot - 1 : slot
    }

    /// How many rows the tab at `row` shifts to make room while the tab at `source` is
    /// dragged over `slot`: -1 (up), 1 (down) or 0, so the list already shows the order
    /// the drop would make.
    static func displacement(ofRowAt row: Int, draggingFrom source: Int, toSlot slot: Int, count: Int) -> Int {
        guard row != source,
              let destination = destinationIndex(movingFrom: source, toSlot: slot, count: count)
        else { return 0 }

        if destination > source, row > source, row <= destination { return -1 }
        if destination < source, row >= destination, row < source { return 1 }
        return 0
    }

    /// The width the sidebar and its divider currently take out of a window's content.
    static var occupiedWidth: CGFloat {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: collapsedKey) {
            return collapsedWidth + dividerWidth
        }

        let width = defaults.object(forKey: widthKey) as? Double ?? defaultWidth
        return width + dividerWidth
    }

    @ObservedObject var model: TerminalTabSidebarModel
    @Binding var isCollapsed: Bool

    /// The tab being dragged to a new position. It resets by itself when the drag ends or
    /// is cancelled, so a lost mouse-up can't leave a row stuck out of place. The reset
    /// isn't animated: by then the tabs already sit where the rows were shifted to.
    @GestureState(resetTransaction: TerminalTabSidebar.instantTransaction)
    private var drag: TabDrag?

    private static var instantTransaction: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    private struct TabDrag: Equatable {
        let id: ObjectIdentifier

        /// The 0-based position of the tab when the drag began.
        let index: Int
        let offset: CGFloat
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                VStack(spacing: 4) {
                    collapseButton
                    newTabButton
                }
                .padding(.top, 5)
                .padding(.bottom, 6)

                ScrollView(showsIndicators: false) {
                    tabList(isCompact: true)
                        .padding(.bottom, 6)
                }
            } else {
                HStack {
                    collapseButton
                    Spacer()
                    newTabButton
                }
                .padding(.horizontal, 6)
                .frame(height: 40)

                ScrollView {
                    tabList(isCompact: false)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tabList(isCompact: Bool) -> some View {
        let pitch = (isCompact ? Self.tileSize : Self.rowHeight) + Self.rowSpacing

        let count = model.tabs.count

        // Where the dragged tab came from and the slot under it, worked out once per
        // pointer move.
        let target = drag.map {
            (source: $0.index, slot: Self.dropSlot(from: $0.index, offset: $0.offset, pitch: pitch, count: count))
        }

        return LazyVStack(spacing: Self.rowSpacing) {
            ForEach(model.tabs) { tab in
                let isDragged = drag?.id == tab.id
                let shift = target.map {
                    Self.displacement(ofRowAt: tab.index - 1, draggingFrom: $0.source, toSlot: $0.slot, count: count)
                } ?? 0

                TerminalTabSidebarRow(model: model, tab: tab, isCompact: isCompact)
                    // Rows only move by a transform, so neither following the pointer nor
                    // making room costs any layout. The other rows only change when the
                    // dragged tab crosses a neighbor's center, and slide there.
                    .offset(y: isDragged ? drag?.offset ?? 0 : CGFloat(shift) * pitch)
                    .animation(.easeOut(duration: 0.15), value: shift)
                    .opacity(isDragged ? 0.8 : 1)
                    .zIndex(isDragged ? 1 : 0)
                    .gesture(reorderGesture(for: tab, pitch: pitch), including: count > 1 ? .all : .subviews)
            }
        }
        .coordinateSpace(name: Self.listSpace)
    }

    private static let listSpace = "TerminalTabSidebarList"

    private func reorderGesture(for tab: TerminalTabSidebarModel.Tab, pitch: CGFloat) -> some Gesture {
        // Measured in the list's space, not the row's: the row itself moves with the drag.
        // The minimum distance leaves clicks and double-clicks to the row.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
            .updating($drag) { value, state, _ in
                state = TabDrag(id: tab.id, index: tab.index - 1, offset: value.translation.height)
            }
            .onEnded { value in
                let slot = Self.dropSlot(
                    from: tab.index - 1,
                    offset: value.translation.height,
                    pitch: pitch,
                    count: model.tabs.count)

                // The rows already show the new order, so the real move must not animate
                // them a second time.
                withTransaction(Self.instantTransaction) {
                    model.move(tab, toSlot: slot)
                }
            }
    }

    private var collapseButton: some View {
        TerminalTabSidebarButton(
            systemName: "sidebar.left",
            label: isCollapsed ? "Show Tab Sidebar" : "Hide Tab Sidebar"
        ) {
            isCollapsed.toggle()
        }
    }

    private var newTabButton: some View {
        TerminalTabSidebarButton(systemName: "plus", label: "New Tab") {
            model.newTab()
        }
    }
}

/// A round icon button in the tab sidebar, drawn like the native tab bar's buttons.
private struct TerminalTabSidebarButton: View {
    enum Kind {
        /// Like the tab bar's new tab button: a large glass circle.
        case bar

        /// Like a tab's close button: a small circle lighter than the tab it sits on.
        case close
    }

    let systemName: String
    let label: String
    var kind: Kind = .bar
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(kind == .close ? closeFill : .clear))
                .terminalTabSidebarGlass(
                    in: Circle(),
                    isEnabled: kind == .bar,
                    isInteractive: true,
                    tint: isHovering ? Color.primary.opacity(0.12) : nil,
                    fallback: barFallbackFill
                )
                // The click target can be larger than the circle that is drawn.
                .frame(width: targetSize, height: targetSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var diameter: CGFloat {
        switch kind {
        case .bar: 30
        case .close: 16
        }
    }

    private var targetSize: CGFloat {
        switch kind {
        case .bar: 30
        case .close: 22
        }
    }

    private var glyphSize: CGFloat {
        switch kind {
        case .bar: 14
        case .close: 8.5
        }
    }

    private var glyphWeight: Font.Weight {
        switch kind {
        case .bar: .medium
        case .close: .bold
        }
    }

    private var closeFill: Color {
        Color.primary.opacity(isHovering ? 0.30 : 0.16)
    }

    /// What the bar buttons are filled with where there is no glass.
    private var barFallbackFill: Color {
        if isHovering { return Color.primary.opacity(0.14) }
        return Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07)
    }
}

private extension View {
    /// Draws the view on the system's Liquid Glass, which is what the native tab bar's tabs
    /// and buttons are made of and what gives them their bright rim. Glass needs macOS 26;
    /// earlier systems get a flat fill instead.
    @ViewBuilder
    func terminalTabSidebarGlass<S: Shape>(
        in shape: S,
        isEnabled: Bool = true,
        isInteractive: Bool = false,
        tint: Color? = nil,
        fallback: Color
    ) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(
                isEnabled ? Glass.regular.tint(tint).interactive(isInteractive) : .identity,
                in: shape
            )
        } else {
            background(shape.fill(isEnabled ? fallback : .clear))
        }
#else
        background(shape.fill(isEnabled ? fallback : .clear))
#endif
    }
}

/// One tab in the sidebar: a rounded row with up to two lines of title when the sidebar
/// is expanded, or a round tile showing its key equivalent in the collapsed rail. The selected tab is drawn on glass like a native tab.
private struct TerminalTabSidebarRow: View {
    let model: TerminalTabSidebarModel
    let tab: TerminalTabSidebarModel.Tab
    let isCompact: Bool

    @State private var isHovering = false

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(Color.primary.opacity(tab.isSelected ? 1 : 0.75))
            .background(shape.fill(hoverFill))
            .terminalTabSidebarGlass(
                in: shape,
                isEnabled: tab.isSelected,
                fallback: Color.primary.opacity(0.14)
            )
            .contentShape(shape)
            .onTapGesture { model.select(tab) }
            // Simultaneous so a single click still selects the tab at once, rather than
            // waiting to see whether a second click follows.
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.promptTitle(tab) })
            .onHover { isHovering = $0 }
            .help(isCompact ? tab.title : "")
            .overlay(TerminalTabSidebarMenuArea { model.contextMenu(for: tab) })
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(tab) }
    }

    private var hoverFill: Color {
        Color.primary.opacity(!tab.isSelected && isHovering ? 0.08 : 0)
    }

    /// A round tile when compact. A full-height capsule would leave a two-line row with
    /// huge rounded ends, so rows get rounded corners instead.
    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: isCompact ? TerminalTabSidebar.tileSize / 2 : TerminalTabSidebar.rowCornerRadius,
            style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
        if isCompact {
            tile
        } else {
            row
        }
    }

    private var tile: some View {
        // The key equivalent that selects the tab (e.g. ⌘1), or its position when it has none.
        Text(tab.keyEquivalent ?? "\(tab.index)")
            .font(.system(size: 11))
            .frame(width: TerminalTabSidebar.tileSize, height: TerminalTabSidebar.tileSize)
            .overlay(alignment: .topTrailing) {
                if let color = tab.color.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 6, height: 6)
                        .padding(3)
                }
            }
    }

    private var row: some View {
        HStack(spacing: 4) {
            // Like a native tab, the close button is on the leading side and only shows
            // on hover. Its slot is always reserved so the title doesn't shift.
            ZStack {
                if isHovering {
                    TerminalTabSidebarButton(systemName: "xmark", label: "Close Tab", kind: .close) {
                        model.close(tab)
                    }
                } else if let color = tab.color.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 22, height: 22)

            Text(tab.title)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 4)

            if let keyEquivalent = tab.keyEquivalent {
                Text(keyEquivalent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: TerminalTabSidebar.rowHeight)
    }
}

/// Shows an AppKit menu when its area is right-clicked or control-clicked, and lets every
/// other mouse event through to the SwiftUI views beneath it.
private struct TerminalTabSidebarMenuArea: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> MenuAreaView {
        let view = MenuAreaView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ nsView: MenuAreaView, context: Context) {
        nsView.menuProvider = menu
    }

    final class MenuAreaView: NSView {
        var menuProvider: (() -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim the clicks that open a context menu. Everything else, such as
            // selecting the tab or pressing its close button, belongs to the row beneath.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?()
        }
    }
}
