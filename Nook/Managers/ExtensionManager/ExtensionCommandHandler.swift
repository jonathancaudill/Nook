//
//  ExtensionCommandHandler.swift
//  Nook
//
//  Phase 3.2: Command Handling Infrastructure
//  Phase 6: Enhanced Command Support with Keyboard Shortcuts and Menu Integration
//

import AppKit
import Foundation
import WebKit

@available(macOS 15.4, *)
@MainActor
final class ExtensionCommandHandler: NSObject {
    private let extensionContext: WKWebExtensionContext
    private let extensionId: String
    private var commands: [WKWebExtension.Command] = []
    private var commandObservers: [NSKeyValueObservation] = []
    // Phase 6: Track registered keyboard shortcuts and event monitors
    // Note: WKWebExtension.Command doesn't have a Shortcut type, so we'll track shortcuts manually
    private var registeredShortcuts: [String: (monitor: Any, keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags)] = [:]
    private let userDefaults = UserDefaults.standard
    private let customizationsKey = "extension.command.customizations"
    // Phase 6: Reference to ExtensionManager for context access
    weak var extensionManager: ExtensionManager?
    // Phase 6: Track menu items for cleanup
    private var menuItems: [String: NSMenuItem] = [:]
    
    init(extensionContext: WKWebExtensionContext, extensionId: String) {
        self.extensionContext = extensionContext
        self.extensionId = extensionId
        super.init()
        observeCommands()
    }
    
    deinit {
        commandObservers.forEach { $0.invalidate() }
        // Phase 6: Clean up event monitors directly (deinit can't call async methods)
        for (_, (monitor, _, _)) in registeredShortcuts {
            if let monitor = monitor as? NSObjectProtocol {
                NSEvent.removeMonitor(monitor)
            }
        }
        registeredShortcuts.removeAll()
    }
    
    // MARK: - Command Observation
    
    private func observeCommands() {
        // Observe commands array changes
        let observer = extensionContext.observe(\.commands) { [weak self] context, _ in
            Task { @MainActor in
                self?.updateCommands()
            }
        }
        commandObservers.append(observer)
        
        // Initial update
        updateCommands()
    }
    
    private func updateCommands() {
        let newCommands = extensionContext.commands
        
        // Unregister removed commands
        let removedCommands = commands.filter { oldCommand in
            !newCommands.contains { $0.id == oldCommand.id }
        }
        for command in removedCommands {
            unregisterCommand(command)
        }
        
        // Register new commands
        let addedCommands = newCommands.filter { newCommand in
            !commands.contains { $0.id == newCommand.id }
        }
        for command in addedCommands {
            registerCommand(command)
        }
        
        commands = newCommands
        
        // Phase 6: Update menu items and notify ExtensionManager to update menu
        updateMenuItems()
        extensionManager?.updateExtensionCommandsMenu()
    }
    
    // MARK: - Command Registration
    
    private func registerCommand(_ command: WKWebExtension.Command) {
        print("⌨️ [Phase 6] Registering command: \(command.id)")
        
        // Phase 6: Load saved customization or use default shortcut
        if let shortcut = getEffectiveShortcut(for: command) {
            registerKeyboardShortcut(for: command, keyEquivalent: shortcut.keyEquivalent, modifierFlags: shortcut.modifierFlags)
        }
        
        // Phase 6: Create menu item
        createMenuItems(for: command)
    }
    
    private func unregisterCommand(_ command: WKWebExtension.Command) {
        print("⌨️ [Phase 6] Unregistering command: \(command.id)")
        
        // Phase 6: Unregister keyboard shortcut
        unregisterKeyboardShortcut(for: command)
        
        // Phase 6: Clean up menu items
        cleanupMenuItems(for: command)
    }
    
    // MARK: - Phase 6: Keyboard Shortcut Management
    
    /// Get the effective shortcut for a command (customized or default)
    private func getEffectiveShortcut(for command: WKWebExtension.Command) -> (keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags)? {
        // Check for saved customization
        if let customization = loadCommandCustomization(for: command) {
            return (keyEquivalent: customization.keyEquivalent, modifierFlags: customization.modifierFlags)
        }
        
        // Use default shortcut from command if available
        // Note: WKWebExtension.Command doesn't expose shortcut directly, so we'll need to get it from the command's properties
        // For now, return nil and handle shortcuts through the command's activation key
        return nil
    }
    
    /// Register a keyboard shortcut for a command
    private func registerKeyboardShortcut(for command: WKWebExtension.Command, keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags) {
        let commandId = command.id
        
        // Check if already registered
        if registeredShortcuts[commandId] != nil {
            unregisterKeyboardShortcut(for: command)
        }
        
        // Create event monitor for this shortcut
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            
            // Check if this event matches our shortcut
            let eventKey = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let eventModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            
            if eventKey == keyEquivalent.lowercased() && eventModifiers == modifierFlags {
                // Match! Execute the command
                Task { @MainActor in
                    self.performCommand(command, in: nil, for: nil)
                }
                return nil // Consume the event
            }
            
            return event
        }
        
        registeredShortcuts[commandId] = (monitor: monitor as Any, keyEquivalent: keyEquivalent, modifierFlags: modifierFlags)
        print("⌨️ [Phase 6] Registered keyboard shortcut for command '\(command.id)': \(keyEquivalent) with modifiers \(modifierFlags)")
    }
    
    /// Unregister a keyboard shortcut for a command
    private func unregisterKeyboardShortcut(for command: WKWebExtension.Command) {
        let commandId = command.id
        
        if let (monitor, _, _) = registeredShortcuts.removeValue(forKey: commandId) {
            if let monitor = monitor as? NSObjectProtocol {
                NSEvent.removeMonitor(monitor)
            }
            print("⌨️ [Phase 6] Unregistered keyboard shortcut for command '\(command.id)'")
        }
    }
    
    // MARK: - Phase 6: Customization Persistence
    
    /// Load saved customization for a command
    private func loadCommandCustomization(for command: WKWebExtension.Command) -> CommandCustomization? {
        guard let data = userDefaults.dictionary(forKey: customizationsKey),
              let extensionData = data[extensionId] as? [String: Any],
              let commandData = extensionData[command.id] as? [String: Any] else {
            return nil
        }
        
        // Parse customization data
        if let keyEquivalent = commandData["keyEquivalent"] as? String,
           let modifierFlagsRaw = commandData["modifierFlags"] as? UInt {
            let modifierFlags = NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
            return CommandCustomization(keyEquivalent: keyEquivalent, modifierFlags: modifierFlags)
        }
        
        return nil
    }
    
    /// Save customization for a command
    func saveCommandCustomization(for command: WKWebExtension.Command, keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags) {
        var allCustomizations = userDefaults.dictionary(forKey: customizationsKey) ?? [:]
        var extensionCustomizations = (allCustomizations[extensionId] as? [String: Any]) ?? [:]
        
        extensionCustomizations[command.id] = [
            "keyEquivalent": keyEquivalent,
            "modifierFlags": modifierFlags.rawValue
        ]
        
        allCustomizations[extensionId] = extensionCustomizations
        userDefaults.set(allCustomizations, forKey: customizationsKey)
        
        // Re-register with new shortcut
        registerKeyboardShortcut(for: command, keyEquivalent: keyEquivalent, modifierFlags: modifierFlags)
        print("⌨️ [Phase 6] Saved customization for command '\(command.id)': \(keyEquivalent) with modifiers \(modifierFlags)")
    }
    
    /// Check for shortcut conflicts
    private func hasShortcutConflict(keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags, excludingCommandId: String? = nil) -> Bool {
        // Check against other registered extension commands
        for (commandId, (_, keyEq, modFlags)) in registeredShortcuts {
            if commandId == excludingCommandId { continue }
            
            if keyEq.lowercased() == keyEquivalent.lowercased() &&
               modFlags == modifierFlags {
                return true
            }
        }
        
        // TODO: Check against app's KeyboardShortcutManager shortcuts
        // This would require access to KeyboardShortcutManager
        
        return false
    }
    
    // MARK: - Phase 6: Customization Data Model
    
    private struct CommandCustomization {
        let keyEquivalent: String
        let modifierFlags: NSEvent.ModifierFlags
    }
    
    private func unregisterAllCommands() {
        for command in commands {
            unregisterCommand(command)
        }
    }
    
    // MARK: - Command Execution
    
    @objc private func handleCommand(_ sender: NSMenuItem) {
        guard let commandId = sender.representedObject as? String,
              let command = commands.first(where: { $0.id == commandId }) else {
            return
        }
        
        // Phase 6: Get execution context
        let context = getExecutionContext(for: command)
        performCommand(command, in: context.tab, for: context.window)
    }
    
    /// Phase 6: Execute command with proper context handling
    func performCommand(_ command: WKWebExtension.Command, in tab: (any WKWebExtensionTab)?, for window: (any WKWebExtensionWindow)?) {
        print("⌨️ [Phase 6] Executing command: \(command.id)")
        
        // Phase 6: Ensure context is ready before executing
        ensureContextReady(tab: tab, window: window) { [weak self] in
            guard let self = self else { return }
            
            // Phase 6: Set user gesture context if we have an active tab
            if let tabAdapter = tab as? ExtensionTabAdapter,
               let extensionManager = self.extensionManager {
                extensionManager.userGesturePerformed(in: tabAdapter.tab)
            }
            
            // Phase 6: Execute the command
            do {
                try self.extensionContext.performCommand(command)
                print("✅ [Phase 6] Successfully executed command: \(command.id)")
            } catch {
                print("❌ [Phase 6] Failed to execute command '\(command.id)': \(error.localizedDescription)")
                self.handleCommandExecutionError(error, for: command)
            }
        }
    }
    
    /// Phase 6: Convenience method for backward compatibility
    func performCommand(_ command: WKWebExtension.Command) {
        let context = getExecutionContext(for: command)
        performCommand(command, in: context.tab, for: context.window)
    }
    
    /// Phase 6: Execute command from keyboard event
    func performCommand(for event: NSEvent) {
        // Find command matching the event's key equivalent and modifiers
        let keyEquivalent = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifierFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        
        // Check registered shortcuts
        if let (commandId, value) = registeredShortcuts.first(where: { (_, value) in
            value.keyEquivalent.lowercased() == keyEquivalent && value.modifierFlags == modifierFlags
        }),
        let command = commands.first(where: { $0.id == commandId }) {
            let context = getExecutionContext(for: command)
            performCommand(command, in: context.tab, for: context.window)
        }
    }
    
    // MARK: - Phase 6: Context Handling
    
    /// Get the execution context for a command (active tab, focused window)
    private func getExecutionContext(for command: WKWebExtension.Command) -> (tab: (any WKWebExtensionTab)?, window: (any WKWebExtensionWindow)?) {
        guard let extensionManager = extensionManager else {
            return (nil, nil)
        }
        
        // Get active tab through ExtensionManager's helper
        let tabAdapter = extensionManager.getActiveTabAdapter()
        
        // Get focused window
        let windowAdapter = extensionManager.windowAdapter
        
        return (tabAdapter, windowAdapter)
    }
    
    /// Ensure context is ready before executing command
    private func ensureContextReady(tab: (any WKWebExtensionTab)?, window: (any WKWebExtensionWindow)?, completion: @escaping () -> Void) {
        // For now, execute immediately
        // In the future, we could check if tab/window is loading and wait
        completion()
    }
    
    /// Handle command execution errors
    private func handleCommandExecutionError(_ error: Error, for command: WKWebExtension.Command) {
        // Log error for debugging
        print("❌ [Phase 6] Command execution error for '\(command.id)': \(error.localizedDescription)")
        
        // TODO: Show user-friendly error message if needed
        // This could be integrated with ExtensionManager's error monitoring
    }
    
    // MARK: - Phase 6: Menu System Integration
    
    /// Create menu items for a command
    private func createMenuItems(for command: WKWebExtension.Command) {
        // Create a basic menu item using command ID as title
        let menuItem = NSMenuItem(
            title: command.id,
            action: #selector(handleCommand(_:)),
            keyEquivalent: ""
        )
        menuItem.target = self
        menuItem.representedObject = command.id
        
        // Set keyboard shortcut if we have one registered
        if let (_, keyEq, modFlags) = registeredShortcuts[command.id] {
            menuItem.keyEquivalent = keyEq
            menuItem.keyEquivalentModifierMask = modFlags
        }
        
        menuItems[command.id] = menuItem
        print("⌨️ [Phase 6] Created menu item for command '\(command.id)'")
    }
    
    /// Clean up menu items for a command
    private func cleanupMenuItems(for command: WKWebExtension.Command) {
        menuItems.removeValue(forKey: command.id)
        print("⌨️ [Phase 6] Cleaned up menu item for command '\(command.id)'")
    }
    
    /// Get all menu items for this extension's commands
    func getAllMenuItems() -> [NSMenuItem] {
        return Array(menuItems.values)
    }
    
    /// Get menu items organized by extension (for submenu structure)
    func getMenuItemsForExtension(extensionName: String) -> NSMenuItem {
        let extensionMenuItem = NSMenuItem(title: extensionName, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: extensionName)
        
        // Add all command menu items to submenu
        // Create new menu items based on the stored ones
        for (commandId, originalMenuItem) in menuItems.sorted(by: { $0.value.title < $1.value.title }) {
            let menuItem = NSMenuItem(
                title: originalMenuItem.title,
                action: originalMenuItem.action,
                keyEquivalent: originalMenuItem.keyEquivalent
            )
            menuItem.keyEquivalentModifierMask = originalMenuItem.keyEquivalentModifierMask
            menuItem.target = originalMenuItem.target
            menuItem.representedObject = originalMenuItem.representedObject
            menuItem.isEnabled = originalMenuItem.isEnabled
            submenu.addItem(menuItem)
        }
        
        extensionMenuItem.submenu = submenu
        return extensionMenuItem
    }
    
    /// Update menu items when commands change
    func updateMenuItems() {
        // Remove old menu items
        for command in commands {
            if menuItems[command.id] == nil {
                createMenuItems(for: command)
            }
        }
        
        // Remove menu items for commands that no longer exist
        let currentCommandIds = Set(commands.map { $0.id })
        for (commandId, _) in menuItems {
            if !currentCommandIds.contains(commandId) {
                menuItems.removeValue(forKey: commandId)
            }
        }
    }
}

