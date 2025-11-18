//
//  ExtensionActionView.swift
//  Nook
//
//  Clean ExtensionActionView using ONLY native WKWebExtension APIs
//

import SwiftUI
import WebKit
import AppKit
import Combine

// MARK: - Action Property Observer
@available(macOS 15.5, *)
class ActionPropertyObserver: NSObject, ObservableObject {
    @Published var label: String = ""
    @Published var badgeText: String = ""
    @Published var hasUnreadBadge: Bool = false
    @Published var isEnabled: Bool = true
    @Published var icon: NSImage?
    @Published var menuItems: [NSMenuItem] = []

    private var action: WKWebExtension.Action?
    private var observationKeys: [NSKeyValueObservation] = []

    func observeAction(_ action: WKWebExtension.Action) {
        // Stop observing previous action
        stopObserving()

        self.action = action

        // Initial values
        updateFromAction()

        // Set up KVO observations for dynamic properties
        let labelObservation = action.observe(\.label) { [weak self] action, _ in
            DispatchQueue.main.async {
                self?.label = action.label
            }
        }

        let badgeTextObservation = action.observe(\.badgeText) { [weak self] action, _ in
            DispatchQueue.main.async {
                self?.badgeText = action.badgeText
            }
        }

        let hasUnreadBadgeObservation = action.observe(\.hasUnreadBadgeText) { [weak self] action, _ in
            DispatchQueue.main.async {
                self?.hasUnreadBadge = action.hasUnreadBadgeText
            }
        }

        let isEnabledObservation = action.observe(\.isEnabled) { [weak self] action, _ in
            DispatchQueue.main.async {
                self?.isEnabled = action.isEnabled
            }
        }

        let menuItemsObservation = action.observe(\.menuItems) { [weak self] action, _ in
            DispatchQueue.main.async {
                self?.menuItems = action.menuItems
            }
        }

        observationKeys = [labelObservation, badgeTextObservation, hasUnreadBadgeObservation, isEnabledObservation, menuItemsObservation]
    }

    func stopObserving() {
        observationKeys.removeAll()
        action = nil
    }

    private func updateFromAction() {
        guard let action = action else { return }

        label = action.label
        badgeText = action.badgeText
        hasUnreadBadge = action.hasUnreadBadgeText
        isEnabled = action.isEnabled
        menuItems = action.menuItems

        // Phase 12.2: Load icon asynchronously with error handling
        let iconSize = CGSize(width: 16, height: 16)
        Task { @MainActor in
            // Try to get action icon first
            if let actionIcon = action.icon(for: iconSize) {
                self.icon = actionIcon
            } else {
                // Fallback: Try to get extension icon from ExtensionManager
                // We need to get the extension ID from the action's context
                // For now, we'll leave icon as nil and let the view handle fallback
                self.icon = nil
            }
        }
    }

    deinit {
        stopObserving()
    }
}

@available(macOS 15.5, *)
struct ExtensionActionView: View {
    let extensions: [InstalledExtension]
    @EnvironmentObject var browserManager: BrowserManager
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(extensions.filter { $0.isEnabled }, id: \.id) { ext in
                ExtensionActionButton(ext: ext)
                    .environmentObject(browserManager)
            }
        }
    }
}

@available(macOS 15.5, *)
struct ExtensionActionButton: View {
    let ext: InstalledExtension
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovering: Bool = false
    @StateObject private var actionObserver = ActionPropertyObserver()
    @State private var action: WKWebExtension.Action?
    
    var body: some View {
        Button(action: {
            showExtensionPopup()
        }) {
            ZStack(alignment: .topTrailing) {
                Group {
                    // Phase 12.2: Use action icon if available, otherwise fall back to extension icon
                    if let actionIcon = actionObserver.icon {
                        Image(nsImage: actionIcon)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .scaledToFit()
                    } else if let extensionIcon = loadExtensionIcon() {
                        Image(nsImage: extensionIcon)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .scaledToFit()
                    } else {
                        // Placeholder icon
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(6)

                // Badge overlay
                if !actionObserver.badgeText.isEmpty {
                    Text(actionObserver.badgeText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(actionObserver.hasUnreadBadge ? Color.red : Color.gray.opacity(0.7))
                        .clipShape(Capsule())
                        .offset(x: 4, y: -4)
                }
            }
            .background(isHovering ? .white.opacity(0.1) : .clear)
            .background(ActionAnchorView(extensionId: ext.id))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(actionObserver.label.isEmpty ? ext.name : actionObserver.label)
        .disabled(!actionObserver.isEnabled)
        .opacity(actionObserver.isEnabled ? 1.0 : 0.5)
        .contextMenu {
            // Main action
            Button(action: showExtensionPopup) {
                Text(ext.name)
                if !actionObserver.label.isEmpty {
                    Text("(\(actionObserver.label))").foregroundColor(.secondary)
                }
            }

            // Action menu items if available
            if !actionObserver.menuItems.isEmpty {
                Divider()
                ForEach(Array(actionObserver.menuItems.enumerated()), id: \.offset) { index, menuItem in
                    Button(action: { handleActionMenuItem(menuItem) }) {
                        if menuItem.state == .on {
                            Text("✓ \(menuItem.title)")
                        } else {
                            Text(menuItem.title)
                        }
                    }
                    .disabled(!menuItem.isEnabled)
                }
            }
        }
        .onHover { state in
            isHovering = state
        }
        .onAppear {
            loadAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ExtensionActionDidUpdate"))) { notification in
            if let extensionId = notification.userInfo?["extensionId"] as? String,
               extensionId == ext.id {
                loadAction()
            }
        }
        .onDisappear {
            // Stop observing when view disappears
            actionObserver.stopObserving()
        }
    }
    
    private func loadAction() {
        guard #available(macOS 15.5, *) else { return }

        // Get action from ExtensionManager (stored when delegate callback fires)
        if let action = ExtensionManager.shared.getExtensionAction(for: ext.id) {
            self.action = action

            // Start observing the action properties
            actionObserver.observeAction(action)
        }
        // Note: If no action is available yet, the UI will use the static extension icon
        // until the delegate callback provides the action via didUpdate
    }
    
    private func showExtensionPopup() {
        print("🎯 Performing action for extension: \(ext.name)")

        guard let extensionContext = ExtensionManager.shared.getExtensionContext(for: ext.id) else {
            print("❌ No extension context found")
            return
        }

        print("✅ Calling performAction() - this should trigger the delegate")
        if let current = browserManager.currentTab(for: windowState) {
            if let adapter = ExtensionManager.shared.stableAdapter(for: current) {
                extensionContext.performAction(for: adapter)
            } else {
                extensionContext.performAction(for: nil)
            }
        } else {
            extensionContext.performAction(for: nil)
        }
    }

    private func loadExtensionIcon() -> NSImage? {
        guard #available(macOS 15.4, *) else { return nil }
        
        let iconSize = NSSize(width: 16, height: 16)
        
        // Phase 12.2: Try to get icon from ExtensionManager cache first
        if let cachedIcon = ExtensionManager.shared.getCachedIcon(for: ext.id, size: iconSize) {
            return cachedIcon
        }
        
        // Phase 12.2: Try to get icon from extension context
        if let extensionIcon = ExtensionManager.shared.getExtensionIcons(for: ext.id, size: iconSize) {
            return extensionIcon
        }
        
        // Phase 12.2: Fallback to file-based icon
        if let iconPath = ext.iconPath,
           let nsImage = NSImage(contentsOfFile: iconPath) {
            // Cache it for future use
            ExtensionManager.shared.cacheIcon(nsImage, for: ext.id, size: iconSize)
            return nsImage
        }
        
        return nil
    }
    
    private func handleActionMenuItem(_ menuItem: NSMenuItem) {
        print("📋 Action menu item selected: \(menuItem.title)")

        // Trigger the menu item's action - it should already be configured by WebKit
        if let action = menuItem.action, let target = menuItem.target {
            NSApp.sendAction(action, to: target, from: menuItem)
            print("✅ Triggered menu item action: \(menuItem.title)")
        } else {
            print("⚠️ Menu item has no action or target configured")
        }
    }
}

@available(macOS 15.5, *)
#Preview {
    ExtensionActionView(extensions: [])
}

// MARK: - Anchor View for Popover Positioning
private struct ActionAnchorView: NSViewRepresentable {
    let extensionId: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        if #available(macOS 15.5, *) {
            ExtensionManager.shared.setActionAnchor(for: extensionId, anchorView: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 15.5, *) {
            ExtensionManager.shared.setActionAnchor(for: extensionId, anchorView: nsView)
        }
    }
}
