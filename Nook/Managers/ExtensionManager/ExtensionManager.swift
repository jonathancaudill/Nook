//
//  ExtensionManager.swift
//  Nook
//
//  Simplified ExtensionManager using native WKWebExtension APIs
//

import AppKit
import Foundation
import SwiftData
import SwiftUI
import WebKit

// MARK: - Popover Delegate for Action Popup Lifecycle (Phase 5.3)

@available(macOS 15.4, *)
@MainActor
final class ExtensionActionPopoverDelegate: NSObject, NSPopoverDelegate {
    weak var action: WKWebExtension.Action?
    let extensionId: String
    weak var extensionManager: ExtensionManager?
    
    init(action: WKWebExtension.Action, extensionId: String, extensionManager: ExtensionManager) {
        self.action = action
        self.extensionId = extensionId
        self.extensionManager = extensionManager
        super.init()
    }
    
    func popoverDidClose(_ notification: Notification) {
        print("🔐 [Phase 5.3] Popover closed for extension: \(extensionId)")
        
        // Call action.closePopup() as required by Phase 5.3
        if #available(macOS 15.5, *), let action = action {
            action.closePopup()
            print("   Called action.closePopup()")
        }
        
        // Clean up via ExtensionManager
        extensionManager?.closeExtensionPopup(for: extensionId)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionManager: NSObject, ObservableObject,
    WKWebExtensionControllerDelegate
{
    static let shared = ExtensionManager()

    @Published var installedExtensions: [InstalledExtension] = []
    @Published var isExtensionSupportAvailable: Bool = false
    // Scope note: Installed/enabled state is global across profiles; extension storage/state
    // (chrome.storage, cookies, etc.) is isolated per-profile via profile-specific data stores.

    private var extensionController: WKWebExtensionController?
    private var extensionContexts: [String: WKWebExtensionContext] = [:]
    private var actionAnchors: [String: [WeakAnchor]] = [:]
    // Keep options windows alive per extension id
    private var optionsWindows: [String: NSWindow] = [:]
    // Stable adapters for tabs/windows used when notifying controller events
    private var tabAdapters: [UUID: ExtensionTabAdapter] = [:]
    internal var windowAdapter: ExtensionWindowAdapter?
    private weak var browserManagerRef: BrowserManager?
    // Store action references per extension for update tracking
    private var extensionActions: [String: WKWebExtension.Action] = [:]
    // Phase 3.2: Command handlers per extension
    private var commandHandlers: [String: ExtensionCommandHandler] = [:]
    // Phase 3.4: User gesture tracking per tab
    private var activeUserGestures: [UUID: Date] = [:]
    // Phase 3.6: Permission expiration dates [extensionId: [permission/matchPattern: expirationDate]]
    private var permissionExpirations: [String: [String: Date]] = [:]
    // Phase 3.9: Extension errors [extensionId: [WKWebExtension.Error]]
    @Published var extensionErrors: [String: [WKWebExtension.Error]] = [:]
    // Whether to auto-resize extension action popovers to content. Disabled per UX preference.
    private let shouldAutoSizeActionPopups: Bool = false

    // No preference for action popups-as-tabs; keep native popovers per Apple docs

    // Phase 5: Popup lifecycle management
    private var activePopovers: [String: NSPopover] = [:]
    private var popupWebViews: [String: WKWebView] = [:]
    private var popoverDelegates: [String: ExtensionActionPopoverDelegate] = [:]
    
    // Phase 12.2: Icon caching [extensionId: [NSSize: NSImage]]
    private var iconCache: [String: [NSSize: NSImage]] = [:]
    
    // Phase 13.2: Performance optimization caches
    // Property cache with TTL [extensionId: (properties: [String: Any], timestamp: Date)]
    private var propertyCache: [String: (properties: [String: Any], timestamp: Date)] = [:]
    private let propertyCacheTTL: TimeInterval = 30.0 // 30 seconds
    
    // Tab/window list cache with TTL
    private var tabListCache: (tabs: [ExtensionTabAdapter], timestamp: Date)?
    private var windowListCache: (windows: [ExtensionWindowAdapter], timestamp: Date)?
    private let listCacheTTL: TimeInterval = 5.0 // 5 seconds
    
    // Permission status cache [extensionId: [permission: (status: WKWebExtensionContext.PermissionStatus, timestamp: Date)]]
    private var permissionStatusCache: [String: [String: (status: WKWebExtensionContext.PermissionStatus, timestamp: Date)]] = [:]
    private let permissionCacheTTL: TimeInterval = 10.0 // 10 seconds
    
    // Pending permission updates for batching [extensionId: Set<WKWebExtension.Permission>]
    private var pendingPermissionUpdates: [String: Set<WKWebExtension.Permission>] = [:]
    private var permissionUpdateTimer: Timer?

    let context: ModelContext

    // Profile-aware extension storage
    private var profileExtensionStores: [UUID: WKWebsiteDataStore] = [:]
    var currentProfileId: UUID?

    private override init() {
        self.context = Persistence.shared.container.mainContext
        self.isExtensionSupportAvailable =
            ExtensionUtils.isExtensionSupportAvailable
        super.init()

        if isExtensionSupportAvailable {
            setupExtensionController()
            loadInstalledExtensions()
            
            // Phase 3.6: Set up periodic expiration checking
            setupPermissionExpirationChecking()
            
            // Phase 3.8: Set up notification observers
            setupContextNotificationObservers()
            
            // Phase 3.9: Set up periodic error checking
            setupErrorMonitoring()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        // Capture state for cleanup before we tear down references
        let contexts = extensionContexts
        let controller = extensionController

        // MEMORY LEAK FIX: Clean up all extension contexts and break circular references
        tabAdapters.removeAll()
        actionAnchors.removeAll()

        // Close all options windows
        for (_, window) in optionsWindows {
            Task { @MainActor in
                window.close()
            }
        }
        optionsWindows.removeAll()

        // Close all active popovers
        for (_, popover) in activePopovers {
            Task { @MainActor in
                popover.close()
            }
        }
        activePopovers.removeAll()

        // Clean up popup WebViews
        for (_, webView) in popupWebViews {
            Task { @MainActor in
                // Remove extension controller reference to break circular references
                webView.configuration.webExtensionController = nil
            }
        }
        popupWebViews.removeAll()

        // Clean up window adapter
        windowAdapter = nil

        // Unload extension controller contexts asynchronously on the main actor
        if let controller {
            Task { @MainActor in
                for (_, context) in contexts {
                    try? controller.unload(context)
                }
            }
        }
        extensionController = nil
        extensionContexts.removeAll()

        print("🧹 [ExtensionManager] Cleaned up all extension resources")
    }

    // MARK: - Setup

    private func setupExtensionController() {
        // Use persistent controller configuration with stable identifier
        let config: WKWebExtensionController.Configuration
        if let idString = UserDefaults.standard.string(
            forKey: "Nook.WKWebExtensionController.Identifier"
        ),
            let uuid = UUID(uuidString: idString)
        {
            config = WKWebExtensionController.Configuration(identifier: uuid)
        } else {
            let uuid = UUID()
            UserDefaults.standard.set(
                uuid.uuidString,
                forKey: "Nook.WKWebExtensionController.Identifier"
            )
            config = WKWebExtensionController.Configuration(identifier: uuid)
        }

        let controller = WKWebExtensionController(configuration: config)
        controller.delegate = self

        // Store controller reference first
        self.extensionController = controller

        let sharedWebConfig = BrowserConfiguration.shared.webViewConfiguration

        // Create or select a persistent data store for extensions.
        // If we already have a profile context, use a profile-specific store; otherwise use a shared fallback.
        let extensionDataStore: WKWebsiteDataStore
        if let pid = currentProfileId {
            extensionDataStore = getExtensionDataStore(for: pid)
        } else {
            // Fallback shared persistent store until a profile is assigned
            extensionDataStore = WKWebsiteDataStore(
                forIdentifier: config.identifier!
            )
        }

        // Verify data store is properly initialized
        if !extensionDataStore.isPersistent {
            print(
                "⚠️ Warning: Extension data store is not persistent - this may cause storage issues"
            )
        }

        controller.configuration.defaultWebsiteDataStore = extensionDataStore
        controller.configuration.webViewConfiguration = sharedWebConfig

        print(
            "ExtensionManager: WKWebExtensionController configured with persistent storage identifier: \(config.identifier?.uuidString ?? "none")"
        )
        print(
            "   Extension data store is persistent: \(extensionDataStore.isPersistent)"
        )
        print(
            "   Extension data store ID: \(extensionDataStore.identifier?.uuidString ?? "none")"
        )
        print(
            "   App WebViews use separate default data store for normal browsing"
        )

        print(
            "   Native storage types supported: .local, .session, .synchronized"
        )
        print(
            "   World support (MAIN/ISOLATED): \(ExtensionUtils.isWorldInjectionSupported)"
        )

        // Handle macOS 15.4+ ViewBridge issues with delayed delegate assignment
        print(
            "⚠️ Running on macOS 15.4+ - using delayed delegate assignment to avoid ViewBridge issues"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.delegate = self
        }

        // Critical: Associate our app's browsing WKWebViews with this controller so content scripts inject
        if #available(macOS 15.5, *) {
            sharedWebConfig.webExtensionController = controller

            sharedWebConfig.defaultWebpagePreferences.allowsContentJavaScript =
                true

            print(
                "ExtensionManager: Configured shared WebView configuration with extension controller"
            )

            // Update existing WebViews with controller
            updateExistingWebViewsWithController(controller)
        }

        extensionController = controller

        // Verify storage is working after setup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.verifyExtensionStorage(self.currentProfileId)
        }

        print(
            "ExtensionManager: Native WKWebExtensionController initialized and configured"
        )
        print("   Controller ID: \(config.identifier?.uuidString ?? "none")")
        let dataStoreDescription =
            controller.configuration.defaultWebsiteDataStore.map {
                String(describing: $0)
            } ?? "nil"
        print("   Data store: \(dataStoreDescription)")
    }

    /// Verify extension storage is working properly
    private func verifyExtensionStorage(_ profileId: UUID? = nil) {
        guard let controller = extensionController else { return }

        guard let dataStore = controller.configuration.defaultWebsiteDataStore
        else {
            print("❌ Extension Storage Verification: No data store available.")
            return
        }
        if let pid = profileId {
            print(
                "📊 Extension Storage Verification (profile=\(pid.uuidString)):"
            )
        } else {
            print("📊 Extension Storage Verification:")
        }
        print("   Data store is persistent: \(dataStore.isPersistent)")
        print(
            "   Data store identifier: \(dataStore.identifier?.uuidString ?? "nil")"
        )

        // Test storage accessibility
        dataStore.fetchDataRecords(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
        ) { records in
            DispatchQueue.main.async {
                print("   Storage records available: \(records.count)")
                if records.count > 0 {
                    print("   ✅ Extension storage appears to be working")
                } else {
                    print(
                        "   ⚠️ No storage records found - this may be normal for new installations"
                    )
                }
            }
        }
    }

    // MARK: - Profile-aware Data Store Management
    private func getExtensionDataStore(for profileId: UUID)
        -> WKWebsiteDataStore
    {
        if let store = profileExtensionStores[profileId] {
            return store
        }
        // Use a persistent store identified by the profile UUID for deterministic mapping when available
        let store = WKWebsiteDataStore(forIdentifier: profileId)
        profileExtensionStores[profileId] = store
        print(
            "🔧 [ExtensionManager] Created/loaded extension data store for profile=\(profileId.uuidString) (persistent=\(store.isPersistent))"
        )
        return store
    }

    func switchProfile(_ profileId: UUID) {
        guard let controller = extensionController else { return }
        let store = getExtensionDataStore(for: profileId)
        controller.configuration.defaultWebsiteDataStore = store
        currentProfileId = profileId
        print(
            "🔁 [ExtensionManager] Switched controller data store to profile=\(profileId.uuidString)"
        )
        // Verify storage on the new profile
        verifyExtensionStorage(profileId)
    }

    func clearExtensionData(for profileId: UUID) {
        let store = getExtensionDataStore(for: profileId)
        store.fetchDataRecords(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
        ) { records in
            Task { @MainActor in
                if records.isEmpty {
                    print(
                        "🧹 [ExtensionManager] No extension data records to clear for profile=\(profileId.uuidString)"
                    )
                } else {
                    print(
                        "🧹 [ExtensionManager] Clearing \(records.count) extension data records for profile=\(profileId.uuidString)"
                    )
                }
                await store.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    for: records
                )
            }
        }
    }

    // MARK: - WebView Extension Controller Association

    /// Update existing WebViews to use the extension controller
    /// This fixes content script injection issues for tabs created before extension setup
    @available(macOS 15.5, *)
    private func updateExistingWebViewsWithController(
        _ controller: WKWebExtensionController
    ) {
        guard let bm = browserManagerRef else { return }

        print("🔧 Updating existing WebViews with extension controller...")

        let allTabs = bm.tabManager.pinnedTabs + bm.tabManager.tabs
        var updatedCount = 0

        for tab in allTabs {
            guard let webView = tab.webView else { continue }

            if webView.configuration.webExtensionController !== controller {
                print("  📝 Updating WebView for tab: \(tab.name)")
                webView.configuration.webExtensionController = controller
                updatedCount += 1

                webView.configuration.defaultWebpagePreferences
                    .allowsContentJavaScript = true
            }
        }

        print(
            "✅ Updated \(updatedCount) existing WebViews with extension controller"
        )

        if updatedCount > 0 {
            print("💡 Content script injection should now work on existing tabs")
        }
    }

    // MARK: - MV3 Support Methods

    // Note: commonPermissions array removed - now using minimalSafePermissions for better security

    /// Grant only minimal safe permissions by default - all others require user consent
    private func grantMinimalSafePermissions(
        to extensionContext: WKWebExtensionContext,
        webExtension: WKWebExtension,
        isExisting: Bool = false
    ) {
        let existingLabel = isExisting ? " for existing extension" : ""

        // SECURITY FIX: Only grant absolutely essential permissions by default
        // These are required for basic extension functionality and are considered safe

        // Grant only basic permissions that are essential for extension operation
        let minimalSafePermissions: Set<WKWebExtension.Permission> = [
            .storage,  // Required for basic extension storage
            .alarms,  // Required for basic extension functionality
        ]

        for permission in minimalSafePermissions {
            if webExtension.requestedPermissions.contains(permission) {
                if !isExisting
                    || !extensionContext.currentPermissions.contains(permission)
                {
                    extensionContext.setPermissionStatus(
                        .grantedExplicitly,
                        for: permission
                    )
                    print(
                        "   ✅ Granted minimal safe permission: \(permission)\(existingLabel)"
                    )
                }
            }
        }

        // SECURITY FIX: Do NOT auto-grant potentially dangerous permissions
        // These require explicit user consent:
        // - .tabs (can access all tab data)
        // - .activeTab (can access current tab)
        // - .scripting (can inject scripts)
        // - .contextMenus (can modify browser UI)
        // - .declarativeNetRequest (can modify network requests)
        // - .webNavigation (can monitor navigation)
        // - .cookies (can access cookies)

        print("   🔒 Potentially sensitive permissions require user consent:")
        let sensitivePermissions = webExtension.requestedPermissions
            .subtracting(minimalSafePermissions)
        for permission in sensitivePermissions {
            print("      - \(permission) (requires user approval)")
        }

        // Note: All other permissions will be handled by user consent prompts
    }

    /// Grant common permissions and MV2 compatibility for an extension context (DEPRECATED - use grantMinimalSafePermissions)
    private func grantCommonPermissions(
        to extensionContext: WKWebExtensionContext,
        webExtension: WKWebExtension,
        isExisting: Bool = false
    ) {
        // This method is kept for backward compatibility but should not be used
        // Use grantMinimalSafePermissions instead for better security
        grantMinimalSafePermissions(
            to: extensionContext,
            webExtension: webExtension,
            isExisting: isExisting
        )
    }

    /// Validate MV3-specific requirements
    private func validateMV3Requirements(manifest: [String: Any], baseURL: URL)
        throws
    {
        // Check for service worker
        if let background = manifest["background"] as? [String: Any] {
            if let serviceWorker = background["service_worker"] as? String {
                let serviceWorkerPath = baseURL.appendingPathComponent(
                    serviceWorker
                )
                if !FileManager.default.fileExists(
                    atPath: serviceWorkerPath.path
                ) {
                    throw ExtensionError.installationFailed(
                        "MV3 service worker not found: \(serviceWorker)"
                    )
                }
                print("   ✅ MV3 service worker found: \(serviceWorker)")
            }
        }

        // Validate content scripts with world parameter
        if let contentScripts = manifest["content_scripts"] as? [[String: Any]]
        {
            for script in contentScripts {
                if let world = script["world"] as? String {
                    print("   🌍 Content script with world: \(world)")
                    if world == "MAIN" {
                        print(
                            "   ⚠️  MAIN world content script - requires macOS 15.5+ for full support"
                        )
                    }
                }
            }
        }

        // Validate host_permissions vs permissions
        if let hostPermissions = manifest["host_permissions"] as? [String] {
            print("   🏠 MV3 host_permissions: \(hostPermissions)")
        }
    }

    /// Configure MV3-specific extension features
    private func configureMV3Extension(
        webExtension: WKWebExtension,
        context: WKWebExtensionContext,
        manifest: [String: Any]
    ) async throws {
        // MV3: Service worker background handling
        if webExtension.hasBackgroundContent {
            print("   🔧 MV3 service worker background detected")
        }

        // MV3: Enhanced content script injection support
        if webExtension.hasInjectedContent {
            print(
                "   💉 MV3 content scripts detected - ensuring MAIN/ISOLATED world support"
            )
        }

        // MV3: Action popup validation
        if let action = manifest["action"] as? [String: Any] {
            if let popup = action["default_popup"] as? String {
                print("   🔧 MV3 action popup: \(popup)")
            }
        }
    }

    // MARK: - Extension Installation

    func installExtension(
        from url: URL,
        completionHandler:
            @escaping (Result<InstalledExtension, ExtensionError>) -> Void
    ) {
        guard isExtensionSupportAvailable else {
            completionHandler(.failure(.unsupportedOS))
            return
        }
        
        Task {
            do {
                let installedExtension = try await performInstallation(
                    from: url
                )
                await MainActor.run {
                    self.installedExtensions.append(installedExtension)
                    completionHandler(.success(installedExtension))
                }
            } catch let error as ExtensionError {
                await MainActor.run {
                    completionHandler(.failure(error))
                }
            } catch {
                await MainActor.run {
                    completionHandler(
                        .failure(
                            .installationFailed(error.localizedDescription)
                        )
                    )
                }
            }
        }
    }

    private func performInstallation(from sourceURL: URL) async throws
        -> InstalledExtension
    {
        let extensionsDir = getExtensionsDirectory()
        try FileManager.default.createDirectory(
            at: extensionsDir,
            withIntermediateDirectories: true
        )

        let extensionId = ExtensionUtils.generateExtensionId()
        let destinationDir = extensionsDir.appendingPathComponent(extensionId)

        // Handle ZIP files and directories
        if sourceURL.pathExtension.lowercased() == "zip" {
            try await extractZip(from: sourceURL, to: destinationDir)
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: destinationDir)
        }

        // Validate manifest exists
        let manifestURL = destinationDir.appendingPathComponent("manifest.json")
        let manifest = try ExtensionUtils.validateManifest(at: manifestURL)

        // MV3 Validation: Ensure proper manifest version support
        if let manifestVersion = manifest["manifest_version"] as? Int {
            print("ExtensionManager: Installing MV\(manifestVersion) extension")
            if manifestVersion == 3 {
                try validateMV3Requirements(
                    manifest: manifest,
                    baseURL: destinationDir
                )
            }
        }

        // Use native WKWebExtension for loading with explicit manifest parsing
        print("🔧 [ExtensionManager] Initializing WKWebExtension...")
        print("   Resource base URL: \(destinationDir.path)")
        print(
            "   Manifest version: \(manifest["manifest_version"] ?? "unknown")"
        )

        // Try the recommended initialization method with proper manifest parsing
        let webExtension = try await WKWebExtension(
            resourceBaseURL: destinationDir
        )
        let extensionContext = WKWebExtensionContext(for: webExtension)

        // Debug the loaded extension
        print("✅ WKWebExtension created successfully")
        print("   Display name: \(webExtension.displayName ?? "Unknown")")
        print("   Version: \(webExtension.version ?? "Unknown")")
        print("   Unique ID: \(extensionContext.uniqueIdentifier)")

        // MV3: Enhanced permission validation and service worker support
        if let manifestVersion = manifest["manifest_version"] as? Int,
            manifestVersion == 3
        {
            try await configureMV3Extension(
                webExtension: webExtension,
                context: extensionContext,
                manifest: manifest
            )
        }

        // Debug extension details and permissions
        print(
            "ExtensionManager: Installing extension '\(webExtension.displayName ?? "Unknown")'"
        )
        print("   Version: \(webExtension.version ?? "Unknown")")
        print("   Requested permissions: \(webExtension.requestedPermissions)")
        print(
            "   Requested match patterns: \(webExtension.requestedPermissionMatchPatterns)"
        )

        // SECURITY FIX: Only grant minimal safe permissions by default
        // All other permissions require explicit user consent
        grantMinimalSafePermissions(
            to: extensionContext,
            webExtension: webExtension
        )

        // SECURITY FIX: Do NOT auto-grant host permissions - require user consent
        print("   🔒 Host permissions require user consent - not auto-granted")
        let hasAllUrls = webExtension.requestedPermissionMatchPatterns.contains(
            where: { $0.description.contains("all_urls") })
        let hasWildcardHosts = webExtension.requestedPermissionMatchPatterns
            .contains(where: { $0.description.contains("*://*/*") })

        if hasAllUrls || hasWildcardHosts {
            print(
                "   ⚠️ Extension requests broad host permissions - will prompt user"
            )
            // MV3: Log host_permissions from manifest for transparency
            if let hostPermissions = manifest["host_permissions"] as? [String] {
                print("   📝 MV3 host_permissions found: \(hostPermissions)")
            }
        }

        // Store context
        extensionContexts[extensionId] = extensionContext
        
        // Phase 3.10: Set unsupported APIs
        setUnsupportedAPIs(for: extensionContext)
        
        // Phase 3.11: Configure inspection settings
        configureInspectionSettings(for: extensionContext, webExtension: webExtension)

        // Load with native controller
        try extensionController?.load(extensionContext)

        // Debug: Check if this is Dark Reader and log additional info
        if webExtension.displayName?.lowercased().contains("dark") == true
            || webExtension.displayName?.lowercased().contains("reader") == true
        {
            print("🌙 DARK READER DETECTED - Adding comprehensive API debugging")
            print(
                "   Has background content: \(webExtension.hasBackgroundContent)"
            )
            print("   Has injected content: \(webExtension.hasInjectedContent)")
            print(
                "   Current permissions after loading: \(extensionContext.currentPermissions)"
            )

            // Test if Dark Reader can access current tab URL
            if let windowAdapter = windowAdapter,
                let activeTab = windowAdapter.activeTab(for: extensionContext),
                let url = activeTab.url?(for: extensionContext)
            {
                print("   🔍 Dark Reader can see active tab URL: \(url)")
                // Phase 3.5: Use per-tab permission check
                let hasAccess = extensionContext.hasAccess(to: url, in: activeTab)
                print("   🔐 Has access to current URL: \(hasAccess)")
            }

            // WKWebExtension automatically provides Chrome APIs - no manual bridging needed
        }

        func getLocaleText(key: String) -> String? {
            guard let manifestValue = manifest[key] as? String else {
                return nil
            }

            if manifestValue.hasPrefix("__MSG_") {
                let localesDirectory = destinationDir.appending(
                    path: "_locales"
                )
                guard
                    FileManager.default.fileExists(
                        atPath: localesDirectory.path(percentEncoded: false)
                    )
                else {
                    return nil
                }

                var pathToDirectory: URL? = nil

                do {
                    let items = try FileManager.default.contentsOfDirectory(
                        at: localesDirectory,
                        includingPropertiesForKeys: nil
                    )
                    for item in items {
                        // TODO: Get user locale
                        if item.lastPathComponent.hasPrefix("en") {
                            pathToDirectory = item
                            break
                        }
                    }
                } catch {
                    return nil
                }

                guard let pathToDirectory = pathToDirectory else {
                    return nil
                }

                let messagesPath = pathToDirectory.appending(
                    path: "messages.json"
                )
                guard
                    FileManager.default.fileExists(
                        atPath: messagesPath.path(percentEncoded: false)
                    )
                else {
                    return nil
                }

                do {
                    let data = try Data(contentsOf: messagesPath)
                    guard
                        let manifest = try JSONSerialization.jsonObject(
                            with: data
                        ) as? [String: [String: String]]
                    else {
                        throw ExtensionError.invalidManifest(
                            "Invalid JSON structure"
                        )
                    }

                    // Remove the __MSG_ from the start and the __ at the end
                    let formattedManifestValue = String(
                        manifestValue.dropFirst(6).dropLast(2)
                    )

                    guard
                        let messageText = manifest[formattedManifestValue]?[
                            "message"
                        ] as? String
                    else {
                        return nil
                    }

                    return messageText
                } catch {
                    return nil
                }

            }

            return nil
        }

        // Create extension entity for persistence
        let entity = ExtensionEntity(
            id: extensionId,
            name: manifest["name"] as? String ?? "Unknown Extension",
            version: manifest["version"] as? String ?? "1.0",
            manifestVersion: manifest["manifest_version"] as? Int ?? 3,
            extensionDescription: getLocaleText(key: "description") ?? "",
            isEnabled: true,
            packagePath: destinationDir.path,
            iconPath: findExtensionIcon(in: destinationDir, manifest: manifest)
        )

        // Save to database
        self.context.insert(entity)
        try self.context.save()

        let installedExtension = InstalledExtension(
            from: entity,
            manifest: manifest
        )
        print(
            "ExtensionManager: Successfully installed extension '\(installedExtension.name)' with native WKWebExtension"
        )

        // SECURITY FIX: Always prompt for permissions that require user consent
        if #available(macOS 15.5, *),
            let displayName = extensionContext.webExtension.displayName
        {
            let requestedPermissions = extensionContext.webExtension
                .requestedPermissions
            let optionalPermissions = extensionContext.webExtension
                .optionalPermissions
            let requestedMatches = extensionContext.webExtension
                .requestedPermissionMatchPatterns
            let optionalMatches = extensionContext.webExtension
                .optionalPermissionMatchPatterns

            // Filter out permissions that were already granted as minimal safe permissions
            let minimalSafePermissions: Set<WKWebExtension.Permission> = [
                .storage, .alarms,
            ]
            let permissionsNeedingConsent = requestedPermissions.subtracting(
                minimalSafePermissions
            )

            // Always show permission prompt if there are any permissions or host patterns that need consent
            if !permissionsNeedingConsent.isEmpty || !requestedMatches.isEmpty
                || !optionalPermissions.isEmpty || !optionalMatches.isEmpty
            {

                self.presentPermissionPrompt(
                    requestedPermissions: permissionsNeedingConsent,
                    optionalPermissions: optionalPermissions,
                    requestedMatches: requestedMatches,
                    optionalMatches: optionalMatches,
                    extensionDisplayName: displayName,
                    extensionId: extensionId, // Phase 12.2: Pass extension ID for icon loading
                    onDecision: { grantedPerms, grantedMatches in
                        // Apply permission decisions
                        for p in permissionsNeedingConsent.union(
                            optionalPermissions
                        ) {
                            extensionContext.setPermissionStatus(
                                grantedPerms.contains(p)
                                    ? .grantedExplicitly : .deniedExplicitly,
                                for: p
                            )
                        }
                        for m in requestedMatches.union(optionalMatches) {
                            extensionContext.setPermissionStatus(
                                grantedMatches.contains(m)
                                    ? .grantedExplicitly : .deniedExplicitly,
                                for: m
                            )
                        }
                        print("   ✅ User granted permissions: \(grantedPerms)")
                        print(
                            "   ✅ User granted host patterns: \(grantedMatches)"
                        )
                    },
                    onCancel: {
                        // SECURITY FIX: Default deny all sensitive permissions if user cancels
                        for p in permissionsNeedingConsent {
                            extensionContext.setPermissionStatus(
                                .deniedExplicitly,
                                for: p
                            )
                        }
                        for m in requestedMatches {
                            extensionContext.setPermissionStatus(
                                .deniedExplicitly,
                                for: m
                            )
                        }
                        print(
                            "   ❌ User denied permissions - extension installed with minimal permissions only"
                        )
                    },
                    extensionLogo: extensionContext.webExtension.icon(
                        for: .init(width: 64, height: 64)
                    ) // Phase 12.2: Pass nil to allow dynamic loading
                )
            } else {
                print(
                    "   ✅ Extension only requests minimal safe permissions - no prompt needed"
                )
            }
        }

        return installedExtension
    }

    private func extractZip(from zipURL: URL, to destinationURL: URL)
        async throws
    {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-q", zipURL.path, "-d", destinationURL.path]

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            throw ExtensionError.installationFailed(
                "Failed to extract ZIP file"
            )
        }
    }

    private func findExtensionIcon(in directory: URL, manifest: [String: Any])
        -> String?
    {
        if let icons = manifest["icons"] as? [String: String] {
            for size in ["128", "64", "48", "32", "16"] {
                if let iconPath = icons[size] {
                    let fullPath = directory.appendingPathComponent(iconPath)
                    if FileManager.default.fileExists(atPath: fullPath.path) {
                        return fullPath.path
                    }
                }
            }
        }

        let commonIconNames = [
            "icon.png", "logo.png", "icon128.png", "icon64.png",
        ]
        for iconName in commonIconNames {
            let iconURL = directory.appendingPathComponent(iconName)
            if FileManager.default.fileExists(atPath: iconURL.path) {
                return iconURL.path
            }
        }

        return nil
    }

    // MARK: - Extension Management

    func enableExtension(_ extensionId: String) {
        guard let context = extensionContexts[extensionId] else { return }

        do {
            try extensionController?.load(context)
            updateExtensionEnabled(extensionId, enabled: true)
        } catch {
            print(
                "ExtensionManager: Failed to enable extension: \(error.localizedDescription)"
            )
        }
    }

    func disableExtension(_ extensionId: String) {
        guard let context = extensionContexts[extensionId] else { return }

        // Close popup for this extension before unloading
        closeExtensionPopup(for: extensionId)

        do {
            try extensionController?.unload(context)
            updateExtensionEnabled(extensionId, enabled: false)
        } catch {
            print(
                "ExtensionManager: Failed to disable extension: \(error.localizedDescription)"
            )
        }
    }

    /// Disable all extensions (used when experimental extension support is disabled)
    func disableAllExtensions() {
        print("🔌 [ExtensionManager] Disabling all extensions...")

        // Close all extension popups first
        closeAllExtensionPopups()

        let enabledExtensions = installedExtensions.filter { $0.isEnabled }

        for ext in enabledExtensions {
            disableExtension(ext.id)
            print("   Disabled: \(ext.name)")
        }

        print(
            "🔌 [ExtensionManager] Disabled \(enabledExtensions.count) extensions"
        )
    }

    /// Enable all previously enabled extensions (used when experimental extension support is re-enabled)
    func enableAllExtensions() {
        print(
            "🔌 [ExtensionManager] Re-enabling previously enabled extensions..."
        )

        let disabledExtensions = installedExtensions.filter { !$0.isEnabled }

        for ext in disabledExtensions {
            // Only enable extensions that were previously enabled (check database)
            do {
                let id = ext.id
                let predicate = #Predicate<ExtensionEntity> { $0.id == id }
                let entities = try self.context.fetch(
                    FetchDescriptor<ExtensionEntity>(predicate: predicate)
                )

                if let entity = entities.first, entity.isEnabled {
                    enableExtension(ext.id)
                    print("   Re-enabled: \(ext.name)")
                }
            } catch {
                print("   Failed to check extension \(ext.name): \(error)")
            }
        }

        print("🔌 [ExtensionManager] Re-enabled extensions complete")
    }

    func uninstallExtension(_ extensionId: String) {
        if let context = extensionContexts[extensionId] {
            do {
                try extensionController?.unload(context)
            } catch {
                print(
                    "ExtensionManager: Failed to unload extension context: \(error.localizedDescription)"
                )
            }
            extensionContexts.removeValue(forKey: extensionId)
            
            // Phase 12.2: Clear icon cache
            clearIconCache(for: extensionId)
            
            // Phase 13.2: Invalidate all caches
            invalidateAllCaches()
        }
        
        // Clean up action reference (Phase 2.1)
        extensionActions.removeValue(forKey: extensionId)

        // Remove from database and filesystem
        do {
            let id = extensionId
            let predicate = #Predicate<ExtensionEntity> { $0.id == id }
            let entities = try self.context.fetch(
                FetchDescriptor<ExtensionEntity>(predicate: predicate)
            )

            for entity in entities {
                let packageURL = URL(fileURLWithPath: entity.packagePath)
                try? FileManager.default.removeItem(at: packageURL)
                self.context.delete(entity)
            }

            try self.context.save()

            installedExtensions.removeAll { $0.id == extensionId }
        } catch {
            print("ExtensionManager: Failed to uninstall extension: \(error)")
        }
    }

    private func updateExtensionEnabled(_ extensionId: String, enabled: Bool) {
        do {
            let id = extensionId
            let predicate = #Predicate<ExtensionEntity> { $0.id == id }
            let entities = try self.context.fetch(
                FetchDescriptor<ExtensionEntity>(predicate: predicate)
            )

            if let entity = entities.first {
                entity.isEnabled = enabled
                try self.context.save()

                // Update UI
                if let index = installedExtensions.firstIndex(where: {
                    $0.id == extensionId
                }) {
                    let updatedExtension = InstalledExtension(
                        from: entity,
                        manifest: installedExtensions[index].manifest
                    )
                    installedExtensions[index] = updatedExtension
                }
            }
        } catch {
            print(
                "ExtensionManager: Failed to update extension enabled state: \(error)"
            )
        }
    }

    // MARK: - File Picker

    func showExtensionInstallDialog() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Install Extension"
        openPanel.message = "Select an extension folder or ZIP file to install"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.zip, .directory]

        if openPanel.runModal() == .OK, let url = openPanel.url {
            installExtension(from: url) { result in
                switch result {
                case .success(let ext):
                    print("Successfully installed extension: \(ext.name)")
                case .failure(let error):
                    print(
                        "Failed to install extension: \(error.localizedDescription)"
                    )
                    self.showErrorAlert(error)
                }
            }
        }
    }

    private func showErrorAlert(_ error: ExtensionError) {
        let alert = NSAlert()
        alert.messageText = "Extension Installation Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Persistence

    private func loadInstalledExtensions() {
        do {
            let entities = try self.context.fetch(
                FetchDescriptor<ExtensionEntity>()
            )
            var loadedExtensions: [InstalledExtension] = []

            for entity in entities {
                let manifestURL = URL(fileURLWithPath: entity.packagePath)
                    .appendingPathComponent("manifest.json")

                do {
                    let manifest = try ExtensionUtils.validateManifest(
                        at: manifestURL
                    )
                    let installedExtension = InstalledExtension(
                        from: entity,
                        manifest: manifest
                    )
                    loadedExtensions.append(installedExtension)

                    // Recreate native extension if enabled
                    if entity.isEnabled {
                        Task {
                            do {
                                print(
                                    "🔧 [ExtensionManager] Re-loading existing extension..."
                                )
                                print("   Package path: \(entity.packagePath)")

                                let webExtension = try await WKWebExtension(
                                    resourceBaseURL: URL(
                                        fileURLWithPath: entity.packagePath
                                    )
                                )
                                let extensionContext = WKWebExtensionContext(
                                    for: webExtension
                                )

                                print("✅ Existing extension re-loaded")
                                print(
                                    "   Display name: \(webExtension.displayName ?? "Unknown")"
                                )
                                print(
                                    "   Version: \(webExtension.version ?? "Unknown")"
                                )
                                print(
                                    "   Unique ID: \(extensionContext.uniqueIdentifier)"
                                )

                                // Debug extension details and permissions
                                print(
                                    "ExtensionManager: Loading existing extension '\(webExtension.displayName ?? entity.name)'"
                                )
                                print(
                                    "   Version: \(webExtension.version ?? entity.version)"
                                )
                                print(
                                    "   Requested permissions: \(webExtension.requestedPermissions)"
                                )
                                print(
                                    "   Current permissions: \(extensionContext.currentPermissions)"
                                )

                                // Pre-grant common permissions for existing extensions (like Dark Reader)
                                grantCommonPermissions(
                                    to: extensionContext,
                                    webExtension: webExtension,
                                    isExisting: true
                                )

                                // Pre-grant match patterns for existing extensions
                                for matchPattern in webExtension
                                    .requestedPermissionMatchPatterns
                                {
                                    extensionContext.setPermissionStatus(
                                        .grantedExplicitly,
                                        for: matchPattern
                                    )
                                    print(
                                        "   ✅ Pre-granted match pattern for existing extension: \(matchPattern)"
                                    )
                                }

                                extensionContexts[entity.id] = extensionContext
                                
                                // Phase 3.10: Set unsupported APIs
                                setUnsupportedAPIs(for: extensionContext)
                                
                                // Phase 3.11: Configure inspection settings
                                configureInspectionSettings(for: extensionContext, webExtension: webExtension)
                                
                                try extensionController?.load(extensionContext)
                                
                                // Phase 3.1: Load background content if needed
                                loadBackgroundContent(for: entity.id, extensionContext: extensionContext, webExtension: webExtension)
                                
                                // Phase 3.2: Set up command handler
                                setupCommandHandler(for: entity.id, extensionContext: extensionContext)

                                // If extension defines requested/optional permissions but none decided yet, prompt.
                                if extensionContext.currentPermissions.isEmpty
                                    && (extensionContext.webExtension
                                        .requestedPermissions.isEmpty == false
                                        || extensionContext.webExtension
                                            .optionalPermissions.isEmpty
                                            == false
                                        || extensionContext.webExtension
                                            .requestedPermissionMatchPatterns
                                            .isEmpty == false
                                        || extensionContext.webExtension
                                            .optionalPermissionMatchPatterns
                                            .isEmpty == false),
                                    let displayName = extensionContext
                                        .webExtension.displayName
                                {
                                    self.presentPermissionPrompt(
                                        requestedPermissions: extensionContext
                                            .webExtension.requestedPermissions,
                                        optionalPermissions: extensionContext
                                            .webExtension.optionalPermissions,
                                        requestedMatches: extensionContext
                                            .webExtension
                                            .requestedPermissionMatchPatterns,
                                        optionalMatches: extensionContext
                                            .webExtension
                                            .optionalPermissionMatchPatterns,
                                        extensionDisplayName: displayName,
                                        extensionId: self.getExtensionId(from: extensionContext), // Phase 12.2: Get extension ID
                                        onDecision: {
                                            grantedPerms,
                                            grantedMatches in
                                            for p in extensionContext
                                                .webExtension
                                                .requestedPermissions.union(
                                                    extensionContext
                                                        .webExtension
                                                        .optionalPermissions
                                                )
                                            {
                                                extensionContext
                                                    .setPermissionStatus(
                                                        grantedPerms.contains(p)
                                                            ? .grantedExplicitly
                                                            : .deniedExplicitly,
                                                        for: p
                                                    )
                                            }
                                            for m in extensionContext
                                                .webExtension
                                                .requestedPermissionMatchPatterns
                                                .union(
                                                    extensionContext
                                                        .webExtension
                                                        .optionalPermissionMatchPatterns
                                                )
                                            {
                                                extensionContext
                                                    .setPermissionStatus(
                                                        grantedMatches.contains(
                                                            m
                                                        )
                                                            ? .grantedExplicitly
                                                            : .deniedExplicitly,
                                                        for: m
                                                    )
                                            }
                                        },
                                        onCancel: {
                                            for p in extensionContext
                                                .webExtension
                                                .requestedPermissions
                                            {
                                                extensionContext
                                                    .setPermissionStatus(
                                                        .deniedExplicitly,
                                                        for: p
                                                    )
                                            }
                                            for m in extensionContext
                                                .webExtension
                                                .requestedPermissionMatchPatterns
                                            {
                                                extensionContext
                                                    .setPermissionStatus(
                                                        .deniedExplicitly,
                                                        for: m
                                                    )
                                            }
                                        },
                                        extensionLogo: extensionContext
                                            .webExtension.icon(
                                                for: .init(
                                                    width: 64,
                                                    height: 64
                                                )
                                            ) // Phase 12.2: Pass nil to allow dynamic loading
                                    )
                                }
                            } catch {
                                print(
                                    "ExtensionManager: Failed to reload extension '\(entity.name)': \(error)"
                                )
                            }
                        }
                    }

                } catch {
                    print(
                        "ExtensionManager: Failed to load manifest for extension '\(entity.name)': \(error)"
                    )
                }
            }

            self.installedExtensions = loadedExtensions
            print(
                "ExtensionManager: Loaded \(loadedExtensions.count) extensions using native WKWebExtension"
            )

        } catch {
            print(
                "ExtensionManager: Failed to load installed extensions: \(error)"
            )
        }
    }

    private func getExtensionsDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Nook").appendingPathComponent(
            "Extensions"
        )
    }

    // MARK: - Native Extension Access

    /// Get the native WKWebExtensionContext for an extension

    /// Get the native WKWebExtensionAction for an extension (Phase 2.1)
    @available(macOS 15.5, *)
    func getExtensionAction(for extensionId: String) -> WKWebExtension.Action? {
        return extensionActions[extensionId]
    }

    /// Get the native WKWebExtensionController
    var nativeController: WKWebExtensionController? {
        return extensionController
    }
    
    // MARK: - Phase 3.1: Background Content Loading
    
    /// Load background content for an extension if it has background content
    private func loadBackgroundContent(for extensionId: String, extensionContext: WKWebExtensionContext, webExtension: WKWebExtension) {
        // Check if extension has background content
        guard webExtension.hasBackgroundContent else {
            return
        }
        
        print("🔄 [Phase 3.1] Loading background content for extension: \(webExtension.displayName ?? extensionId)")
        
        extensionContext.loadBackgroundContent { [weak self] error in
            if let error = error {
                print("❌ [Phase 3.1] Failed to load background content for extension '\(extensionId)': \(error.localizedDescription)")
            } else {
                print("✅ [Phase 3.1] Successfully loaded background content for extension: \(webExtension.displayName ?? extensionId)")
            }
        }
    }
    
    // MARK: - Phase 3.2: Command Handling
    
    /// Set up command handler for an extension
    private func setupCommandHandler(for extensionId: String, extensionContext: WKWebExtensionContext) {
        let handler = ExtensionCommandHandler(extensionContext: extensionContext, extensionId: extensionId)
        // Phase 6: Set extension manager reference for context access
        handler.extensionManager = self
        commandHandlers[extensionId] = handler
        print("⌨️ [Phase 3.2] Set up command handler for extension: \(extensionId)")
        
        // Phase 6: Update menu after a short delay to allow commands to be registered
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            if #available(macOS 15.4, *) {
                updateExtensionCommandsMenu()
            }
        }
    }
    
    /// Get command handler for an extension
    func getCommandHandler(for extensionId: String) -> ExtensionCommandHandler? {
        return commandHandlers[extensionId]
    }
    
    /// Phase 6: Get all extension commands organized by extension for menu integration
    @available(macOS 15.4, *)
    func getAllExtensionCommands() -> [(extensionId: String, extensionName: String, handler: ExtensionCommandHandler)] {
        var result: [(extensionId: String, extensionName: String, handler: ExtensionCommandHandler)] = []
        
        for (extensionId, handler) in commandHandlers {
            // Get extension name from installed extensions
            if let installedExtension = installedExtensions.first(where: { $0.id == extensionId }) {
                result.append((extensionId: extensionId, extensionName: installedExtension.name, handler: handler))
            } else {
                // Fallback to extension ID if name not found
                result.append((extensionId: extensionId, extensionName: extensionId, handler: handler))
            }
        }
        
        return result.sorted(by: { $0.extensionName < $1.extensionName })
    }
    
    /// Phase 6: Update the application menu with extension commands
    @available(macOS 15.4, *)
    func updateExtensionCommandsMenu() {
        guard let appMenu = NSApp.mainMenu else { return }
        
        // Find or create Extensions menu
        var extensionsMenuItem: NSMenuItem?
        var extensionsMenu: NSMenu?
        
        // Look for existing Extensions menu
        if let existingItem = appMenu.item(withTitle: "Extensions") {
            extensionsMenuItem = existingItem
            extensionsMenu = existingItem.submenu
        } else {
            // Create new Extensions menu
            extensionsMenuItem = NSMenuItem(title: "Extensions", action: nil, keyEquivalent: "")
            extensionsMenu = NSMenu(title: "Extensions")
            extensionsMenuItem?.submenu = extensionsMenu
            // Insert before Window menu if it exists, otherwise at the end
            if let windowIndex = appMenu.items.firstIndex(where: { $0.title == "Window" }) {
                appMenu.insertItem(extensionsMenuItem!, at: windowIndex)
            } else {
                appMenu.addItem(extensionsMenuItem!)
            }
        }
        
        guard let menu = extensionsMenu else { return }
        
        // Remove existing extension command items (keep non-command items like "Install Extension...")
        let itemsToRemove = menu.items.filter { item in
            // Keep items that don't have representedObject set to a command identifier
            // or items that are dividers
            if item.isSeparatorItem { return false }
            if item.representedObject is String {
                // Check if it's a command identifier (starts with extension ID pattern)
                return true
            }
            return false
        }
        for item in itemsToRemove {
            menu.removeItem(item)
        }
        
        // Add extension commands organized by extension
        let allCommands = getAllExtensionCommands()
        
        for (extensionId, extensionName, handler) in allCommands {
            let menuItems = handler.getAllMenuItems()
            
            if !menuItems.isEmpty {
                // Add divider before extension group if not first
                if menu.items.count > 0 && !menu.items.last!.isSeparatorItem {
                    menu.addItem(NSMenuItem.separator())
                }
                
                // Add extension submenu or individual items
                if menuItems.count > 1 {
                    // Multiple commands: create submenu
                    let extensionSubmenuItem = handler.getMenuItemsForExtension(extensionName: extensionName)
                    menu.addItem(extensionSubmenuItem)
                } else {
                    // Single command: add directly
                    for menuItem in menuItems {
                        menu.addItem(menuItem)
                    }
                }
            }
        }
        
        print("⌨️ [Phase 6] Updated extension commands menu with \(allCommands.count) extensions")
    }
    
    // MARK: - Phase 3.3: Context Menu Items
    
    /// Get context menu items for a tab from all loaded extensions
    func getContextMenuItems(for tab: Tab) -> [NSMenuItem] {
        guard let tabAdapter = stableAdapter(for: tab) else {
            return []
        }
        
        var allMenuItems: [NSMenuItem] = []
        
        // Get menu items from all loaded extension contexts
        for (extensionId, extensionContext) in extensionContexts {
            let menuItems = extensionContext.menuItems(for: tabAdapter)
            
            // Add separator before extension items if we have items already
            if !allMenuItems.isEmpty && !menuItems.isEmpty {
                allMenuItems.append(NSMenuItem.separator())
            }
            
            // Add extension name as section header if multiple extensions
            if extensionContexts.count > 1 && !menuItems.isEmpty {
                let headerItem = NSMenuItem(
                    title: extensionContext.webExtension.displayName ?? extensionId,
                    action: nil,
                    keyEquivalent: ""
                )
                headerItem.isEnabled = false
                allMenuItems.append(headerItem)
            }
            
            // Add menu items from this extension
            allMenuItems.append(contentsOf: menuItems)
        }
        
        return allMenuItems
    }
    
    // MARK: - Phase 3.4: User Gesture Tracking
    
    /// Record that a user gesture was performed in a tab
    func userGesturePerformed(in tab: Tab) {
        guard let tabAdapter = stableAdapter(for: tab) else {
            return
        }
        
        // Record gesture timestamp
        activeUserGestures[tab.id] = Date()
        
        // Notify all extension contexts
        for (_, extensionContext) in extensionContexts {
            extensionContext.userGesturePerformed(in: tabAdapter)
        }
        
        print("👆 [Phase 3.4] User gesture recorded for tab: \(tab.name)")
    }
    
    /// Check if a tab has an active user gesture
    func hasActiveUserGesture(in tab: Tab) -> Bool {
        guard let tabAdapter = stableAdapter(for: tab) else {
            return false
        }
        
        // Check if any extension context reports an active gesture
        for (_, extensionContext) in extensionContexts {
            if extensionContext.hasActiveUserGesture(in: tabAdapter) {
                return true
            }
        }
        
        // Also check our internal tracking (gestures expire after 5 seconds)
        if let gestureTime = activeUserGestures[tab.id],
           Date().timeIntervalSince(gestureTime) < 5.0 {
            return true
        }
        
        return false
    }
    
    /// Clear user gesture state for a tab
    func clearUserGesture(in tab: Tab) {
        guard let tabAdapter = stableAdapter(for: tab) else {
            return
        }
        
        activeUserGestures.removeValue(forKey: tab.id)
        
        // Clear gesture in all extension contexts
        for (_, extensionContext) in extensionContexts {
            extensionContext.clearUserGesture(in: tabAdapter)
        }
        
        print("🧹 [Phase 3.4] User gesture cleared for tab: \(tab.name)")
    }
    
    // MARK: - Phase 3.5: Per-Tab Permission Status Queries
    
    /// Check if extension has permission in a specific tab
    func hasPermission(_ permission: WKWebExtension.Permission, in tab: Tab, for extensionId: String) -> Bool {
        guard let extensionContext = extensionContexts[extensionId],
              let tabAdapter = stableAdapter(for: tab) else {
            return false
        }
        return extensionContext.hasPermission(permission, in: tabAdapter)
    }
    
    /// Check if extension has access to URL in a specific tab
    /// Uses match pattern validation for enhanced logging
    func hasAccessToURL(_ url: URL, in tab: Tab, for extensionId: String) -> Bool {
        guard let extensionContext = extensionContexts[extensionId],
              let tabAdapter = stableAdapter(for: tab) else {
            return false
        }
        
        let hasAccess = extensionContext.hasAccess(to: url, in: tabAdapter)
        
        // Phase 10.1: Log match pattern validation
        if #available(macOS 15.4, *) {
            let grantedPatterns = extensionContext.grantedPermissionMatchPatterns
            for (pattern, _) in grantedPatterns {
                if ExtensionUtils.urlMatchesPattern(url, pattern: pattern) {
                    print("✅ [Phase 10.1] URL \(url.absoluteString) matches granted pattern: \(pattern.description)")
                }
            }
        }
        
        return hasAccess
    }
    
    /// Get permission status for a permission in a specific tab
    func permissionStatus(for permission: WKWebExtension.Permission, in tab: Tab, for extensionId: String) -> WKWebExtensionContext.PermissionStatus {
        guard let extensionContext = extensionContexts[extensionId],
              let tabAdapter = stableAdapter(for: tab) else {
            return .deniedExplicitly
        }
        return extensionContext.permissionStatus(for: permission, in: tabAdapter)
    }
    
    /// Get permission status for a match pattern in a specific tab
    /// Uses match pattern validation for enhanced logging
    func permissionStatus(for matchPattern: WKWebExtension.MatchPattern, in tab: Tab, for extensionId: String) -> WKWebExtensionContext.PermissionStatus {
        guard let extensionContext = extensionContexts[extensionId],
              let tabAdapter = stableAdapter(for: tab) else {
            return .deniedExplicitly
        }
        
        // Phase 10.1: Validate match pattern before checking status
        if #available(macOS 15.4, *) {
            let normalizedPattern = ExtensionUtils.normalizeMatchPattern(matchPattern.description)
            if normalizedPattern != matchPattern.description {
                print("ℹ️ [Phase 10.1] Normalized match pattern: \(matchPattern.description) -> \(normalizedPattern)")
            }
        }
        
        return extensionContext.permissionStatus(for: matchPattern, in: tabAdapter)
    }
    
    // MARK: - Phase 3.6: Permission Expiration Dates
    
    /// Set up periodic checking for expired permissions
    private func setupPermissionExpirationChecking() {
        // Check for expired permissions every 5 minutes
        Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissionExpirations()
            }
        }
    }
    
    /// Set permission status with optional expiration date
    func setPermissionStatus(_ status: WKWebExtensionContext.PermissionStatus, for permission: WKWebExtension.Permission, expirationDate: Date? = nil, extensionId: String) {
        guard let extensionContext = extensionContexts[extensionId] else {
            return
        }
        
        if let expirationDate = expirationDate {
            extensionContext.setPermissionStatus(status, for: permission, expirationDate: expirationDate)
            
            // Track expiration date
            if permissionExpirations[extensionId] == nil {
                permissionExpirations[extensionId] = [:]
            }
            permissionExpirations[extensionId]?["permission:\(String(describing: permission))"] = expirationDate
        } else {
            extensionContext.setPermissionStatus(status, for: permission)
        }
    }
    
    /// Set match pattern permission status with optional expiration date
    func setPermissionStatus(_ status: WKWebExtensionContext.PermissionStatus, for matchPattern: WKWebExtension.MatchPattern, expirationDate: Date? = nil, extensionId: String) {
        guard let extensionContext = extensionContexts[extensionId] else {
            return
        }
        
        if let expirationDate = expirationDate {
            extensionContext.setPermissionStatus(status, for: matchPattern, expirationDate: expirationDate)
            
            // Track expiration date
            if permissionExpirations[extensionId] == nil {
                permissionExpirations[extensionId] = [:]
            }
            permissionExpirations[extensionId]?["matchPattern:\(matchPattern.description)"] = expirationDate
        } else {
            extensionContext.setPermissionStatus(status, for: matchPattern)
        }
    }
    
    /// Check for expired permissions and re-prompt if needed
    func checkPermissionExpirations() {
        let now = Date()
        
        for (extensionId, expirations) in permissionExpirations {
            guard let extensionContext = extensionContexts[extensionId] else {
                continue
            }
            
            var expiredMatchPatterns: Set<WKWebExtension.MatchPattern> = []
            var keysToRemove: [String] = []
            
            for (key, expirationDate) in expirations {
                if expirationDate < now {
                    // Permission expired
                    if key.hasPrefix("permission:") {
                        print("⏰ [Phase 3.6] Permission expired for extension \(extensionId): \(key)")
                        keysToRemove.append(key)
                    } else if key.hasPrefix("matchPattern:") {
                        let patternString = String(key.dropFirst("matchPattern:".count))
                        if let matchPattern = try? WKWebExtension.MatchPattern(string: patternString) {
                            expiredMatchPatterns.insert(matchPattern)
                            keysToRemove.append(key)
                        }
                    }
                }
            }
            
            // Remove expired entries
            for key in keysToRemove {
                permissionExpirations[extensionId]?.removeValue(forKey: key)
            }
            
            // Clear expired match patterns
            for matchPattern in expiredMatchPatterns {
                extensionContext.setPermissionStatus(.deniedExplicitly, for: matchPattern)
                print("⏰ [Phase 3.6] Cleared expired match pattern for extension \(extensionId): \(matchPattern)")
            }
        }
    }

    // MARK: - Phase 3.8: Context Notifications Observation
    
    /// Set up NotificationCenter observers for extension context notifications
    private func setupContextNotificationObservers() {
        // Note: These notification names may not be available in the current WebKit API
        // Permission notifications are handled via delegate methods instead
        // If notifications become available, uncomment and use the correct notification names:
        /*
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionsWereGranted(_:)),
            name: WKWebExtensionContext.permissionsWereGrantedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionsWereDenied(_:)),
            name: WKWebExtensionContext.permissionsWereDeniedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGrantedPermissionsWereRemoved(_:)),
            name: WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeniedPermissionsWereRemoved(_:)),
            name: WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            object: nil
        )
        
        // Match pattern permission notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionMatchPatternsWereGranted(_:)),
            name: WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionMatchPatternsWereDenied(_:)),
            name: WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGrantedPermissionMatchPatternsWereRemoved(_:)),
            name: WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeniedPermissionMatchPatternsWereRemoved(_:)),
            name: WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
            object: nil
        )
        
        // Error notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleErrorsDidUpdate(_:)),
            name: WKWebExtensionContext.errorsDidUpdateNotification,
            object: nil
        )
        */
    }
    
    @objc private func handlePermissionsWereGranted(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            print("✅ [Phase 3.8] Permissions were granted for extension: \(extensionId)")
            // Update UI if needed
        }
    }
    
    @objc private func handlePermissionsWereDenied(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            print("❌ [Phase 3.8] Permissions were denied for extension: \(extensionId)")
            // Update UI if needed
        }
    }
    
    @objc private func handleGrantedPermissionsWereRemoved(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            print("🗑️ [Phase 3.8] Granted permissions were removed for extension: \(extensionId)")
            // Update UI if needed
        }
    }
    
    @objc private func handleDeniedPermissionsWereRemoved(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            print("🔄 [Phase 3.8] Denied permissions were removed for extension: \(extensionId)")
            // Update UI if needed
        }
    }
    
    @objc private func handlePermissionMatchPatternsWereGranted(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            print("✅ [Phase 3.8] Permission match patterns were granted for extension: \(extensionId)")
            // Update UI if needed
        }
    }
    
    @objc private func handlePermissionMatchPatternsWereDenied(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            print("❌ [Phase 3.8] Permission match patterns were denied for extension: \(extensionId)")
            // Update UI if needed
        }
    }
    
    @objc private func handleGrantedPermissionMatchPatternsWereRemoved(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            print("🗑️ [Phase 3.8] Granted permission match patterns were removed for extension: \(extensionId)")
            // Update UI if needed
        }
    }
    
    @objc private func handleDeniedPermissionMatchPatternsWereRemoved(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            print("🔄 [Phase 3.8] Denied permission match patterns were removed for extension: \(extensionId)")
            // Update UI if needed
        }
    }
    
    @objc private func handleErrorsDidUpdate(_ notification: Notification) {
        guard let extensionContext = notification.object as? WKWebExtensionContext else { return }
        if let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key {
            let errors: [WKWebExtension.Error] = extensionContext.errors.compactMap { $0 as? WKWebExtension.Error }
            extensionErrors[extensionId] = errors.isEmpty ? nil : errors
            if !errors.isEmpty {
                print("⚠️ [Phase 13.1] Extension errors updated for extension: \(extensionId)")
                // Phase 13.1: Use error handler for logging
                for error in errors {
                    ExtensionUtils.ExtensionErrorHandler.logError(error, extensionId: extensionId)
                }
            }
        }
    }
    
    // MARK: - Phase 3.9: Context Error Monitoring
    
    /// Periodically check for extension errors
    private func checkExtensionErrors() {
        for (extensionId, extensionContext) in extensionContexts {
            let errors: [WKWebExtension.Error] = extensionContext.errors.compactMap { $0 as? WKWebExtension.Error }
            extensionErrors[extensionId] = errors.isEmpty ? nil : errors
            
            // Phase 13.1: Log errors with proper severity
            if !errors.isEmpty {
                for error in errors {
                    ExtensionUtils.ExtensionErrorHandler.logError(error, extensionId: extensionId)
                }
            }
        }
    }
    
    /// Get errors for a specific extension
    func getErrors(for extensionId: String) -> [WKWebExtension.Error] {
        return extensionErrors[extensionId] ?? []
    }
    
    /// Clear errors for a specific extension
    func clearErrors(for extensionId: String) {
        extensionErrors[extensionId] = nil
    }
    
    // MARK: - Phase 13.1: Error Recovery
    
    /// Attempt to recover from an error for a specific extension
    /// - Parameters:
    ///   - error: The error to recover from
    ///   - extensionId: The extension ID
    @available(macOS 15.4, *)
    func attemptErrorRecovery(for error: WKWebExtension.Error, extensionId: String) {
        guard ExtensionUtils.ExtensionErrorHandler.shouldRecover(from: error) else {
            print("⚠️ [Phase 13.1] Error is not recoverable: \(error.localizedDescription)")
            return
        }
        
        let errorDescription = error.localizedDescription.lowercased()
        
        // Phase 13.1: Handle different error types
        if errorDescription.contains("load") || errorDescription.contains("context") {
            // Try to reload the extension
            print("🔄 [Phase 13.1] Attempting to reload extension: \(extensionId)")
            if let context = extensionContexts[extensionId] {
                // Unload and reload
                do {
                    try extensionController?.unload(context)
                    // Small delay before reload
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                        await MainActor.run {
                            do {
                                try self.extensionController?.load(context)
                                print("✅ [Phase 13.1] Successfully reloaded extension: \(extensionId)")
                            } catch {
                                print("❌ [Phase 13.1] Failed to reload extension: \(error.localizedDescription)")
                            }
                        }
                    }
                } catch {
                    print("❌ [Phase 13.1] Failed to unload extension for recovery: \(error.localizedDescription)")
                }
            }
        } else if errorDescription.contains("permission") {
            // Permission errors - user needs to grant permissions
            print("ℹ️ [Phase 13.1] Permission error - user action required for extension: \(extensionId)")
            // Could trigger permission prompt here if needed
        } else if errorDescription.contains("network") || errorDescription.contains("connection") {
            // Network errors - just log, user needs to fix connection
            print("ℹ️ [Phase 13.1] Network error - check connection for extension: \(extensionId)")
        }
    }
    
    /// Attempt to recover from all recoverable errors for an extension
    /// - Parameter extensionId: The extension ID
    @available(macOS 15.4, *)
    func attemptAllErrorRecoveries(for extensionId: String) {
        guard let errors = extensionErrors[extensionId] else { return }
        
        for error in errors where ExtensionUtils.ExtensionErrorHandler.shouldRecover(from: error) {
            attemptErrorRecovery(for: error, extensionId: extensionId)
        }
    }
    
    /// Set up periodic error monitoring
    private func setupErrorMonitoring() {
        // Check for errors every minute
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkExtensionErrors()
            }
        }
        // Initial check
        checkExtensionErrors()
    }
    
    // MARK: - Phase 3.10: Context Unsupported APIs
    
    /// Get list of APIs that are not yet supported
    private func getUnsupportedAPIs() -> Set<String> {
        // List APIs that we haven't implemented yet
        // This should be updated as more APIs are implemented
        var unsupported: Set<String> = []
        
        // Add APIs that are known to be unsupported
        // Note: This is a placeholder - update as implementation progresses
        // unsupported.insert("chrome.identity.getAuthToken")
        // unsupported.insert("chrome.identity.removeCachedAuthToken")
        
        return unsupported
    }
    
    /// Set unsupported APIs on extension context
    private func setUnsupportedAPIs(for extensionContext: WKWebExtensionContext) {
        let unsupported = getUnsupportedAPIs()
        if !unsupported.isEmpty {
            extensionContext.unsupportedAPIs = unsupported
            print("🚫 [Phase 3.10] Set unsupported APIs for extension: \(unsupported.joined(separator: ", "))")
        }
    }
    
    // MARK: - Phase 3.11: Context Inspection Settings
    
    /// Configure inspection settings for an extension context
    private func configureInspectionSettings(for extensionContext: WKWebExtensionContext, webExtension: WKWebExtension) {
        // Check user preference for inspectability (default to true for development)
        let isInspectable = UserDefaults.standard.bool(forKey: "Nook.ExtensionInspectable.\(extensionContext.uniqueIdentifier)")
        if UserDefaults.standard.object(forKey: "Nook.ExtensionInspectable.\(extensionContext.uniqueIdentifier)") == nil {
            // Default to true if not set
            extensionContext.isInspectable = true
        } else {
            extensionContext.isInspectable = isInspectable
        }
        
        // Set inspection name for better debugging experience
        let displayName = webExtension.displayName ?? "Unknown Extension"
        extensionContext.inspectionName = "Extension: \(displayName)"
        
        print("🔍 [Phase 3.11] Configured inspection settings for extension: \(displayName)")
        print("   Inspectable: \(extensionContext.isInspectable)")
        print("   Inspection Name: \(extensionContext.inspectionName ?? "nil")")
    }
    
    /// Toggle inspectability for an extension
    func setInspectable(_ inspectable: Bool, for extensionId: String) {
        guard let extensionContext = extensionContexts[extensionId] else {
            return
        }
        
        extensionContext.isInspectable = inspectable
        UserDefaults.standard.set(inspectable, forKey: "Nook.ExtensionInspectable.\(extensionContext.uniqueIdentifier)")
        print("🔍 [Phase 3.11] Set inspectable=\(inspectable) for extension: \(extensionId)")
    }
    
    // MARK: - Phase 4.3: Data Record Management
    
    /// Fetch all extension data records
    @available(macOS 15.4, *)
    func fetchExtensionDataRecords(
        ofTypes dataTypes: Set<WKWebExtension.DataType>? = nil,
        completionHandler: @escaping ([WKWebExtension.DataRecord], Error?) -> Void
    ) {
        guard let controller = extensionController else {
            completionHandler([], NSError(domain: "ExtensionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Extension controller not available"]))
            return
        }
        
        // Use provided types or default to all available types
        let typesToFetch: Set<WKWebExtension.DataType> = dataTypes ?? [
            .local, .session, .synchronized
        ]
        
        controller.fetchDataRecords(ofTypes: typesToFetch) { dataRecords in
            print("✅ [Phase 4.3] Fetched \(dataRecords.count) extension data records")
            completionHandler(dataRecords, nil)
        }
    }
    
    /// Fetch data record for a specific extension
    @available(macOS 15.4, *)
    func fetchExtensionDataRecord(
        for extensionId: String,
        ofTypes dataTypes: Set<WKWebExtension.DataType>? = nil,
        completionHandler: @escaping (WKWebExtension.DataRecord?, Error?) -> Void
    ) {
        guard let controller = extensionController,
              let webExtension = extensionContexts[extensionId]?.webExtension else {
            completionHandler(nil, NSError(domain: "ExtensionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Extension not found"]))
            return
        }
        
        // Use provided types or default to all available types
        let typesToFetch: Set<WKWebExtension.DataType> = dataTypes ?? [
            .local, .session, .synchronized
        ]
        
        guard let extensionContext = extensionContexts[extensionId] else {
            completionHandler(nil, NSError(domain: "ExtensionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Extension context not found"]))
            return
        }
        
        controller.fetchDataRecord(ofTypes: typesToFetch, for: extensionContext) { dataRecord in
            print("✅ [Phase 4.3] Fetched data record for extension: \(extensionId)")
            completionHandler(dataRecord, nil)
        }
    }

    // MARK: - Debugging Utilities

    /// Show debugging console for popup troubleshooting
    func showPopupConsole() {
        PopupConsole.shared.show()
    }

    // Action popups remain popovers; options page behavior adjusted below

    /// Connect the browser manager so we can expose tabs/windows and present UI.
    func attach(browserManager: BrowserManager) {
        self.browserManagerRef = browserManager
        // Ensure a stable window adapter and notify controller about the window
        if #available(macOS 15.5, *), let controller = extensionController {
            let adapter =
                self.windowAdapter
                ?? ExtensionWindowAdapter(browserManager: browserManager)
            self.windowAdapter = adapter

            print(
                "ExtensionManager: Notifying controller about window and tabs..."
            )

            // Important: Notify about window FIRST
            // Phase 3.7: Use context-specific notifications
            for (_, extensionContext) in extensionContexts {
                extensionContext.didOpenWindow(adapter)
                extensionContext.didFocusWindow(adapter)
            }
            // Also notify controller for backward compatibility
            controller.didOpenWindow(adapter)
            controller.didFocusWindow(adapter)

            // Notify about existing tabs
            let allTabs =
                browserManager.tabManager.pinnedTabs
                + browserManager.tabManager.tabs
            for tab in allTabs {
                let tabAdapter = self.adapter(
                    for: tab,
                    browserManager: browserManager
                )
                // Phase 3.7: Use context-specific notifications
                for (_, extensionContext) in extensionContexts {
                    extensionContext.didOpenTab(tabAdapter)
                }
                // Also notify controller for backward compatibility
                controller.didOpenTab(tabAdapter)
            }

            // Notify about current active tab
            if let currentTab = browserManager.currentTabForActiveWindow() {
                let tabAdapter = self.adapter(
                    for: currentTab,
                    browserManager: browserManager
                )
                // Phase 3.7: Use context-specific notifications
                for (_, extensionContext) in extensionContexts {
                    extensionContext.didActivateTab(tabAdapter, previousActiveTab: nil)
                    extensionContext.didSelectTabs([tabAdapter])
                }
                // Also notify controller for backward compatibility
                controller.didActivateTab(tabAdapter, previousActiveTab: nil)
                controller.didSelectTabs([tabAdapter])
            }

            print(
                "ExtensionManager: Attached to browser manager and synced \(allTabs.count) tabs in window"
            )
        }
    }

    // MARK: - Controller event notifications for tabs
    private var lastCachedAdapterLog: Date = Date.distantPast

    @available(macOS 15.5, *)
    private func adapter(for tab: Tab, browserManager: BrowserManager)
        -> ExtensionTabAdapter
    {
        // Phase 13.2: Enhanced adapter caching - reuse adapters across contexts
        if let existing = tabAdapters[tab.id] {
            // Only log cached adapter access every 10 seconds to prevent spam
            let now = Date()
            if now.timeIntervalSince(lastCachedAdapterLog) > 10.0 {
                print(
                    "[ExtensionManager] Returning CACHED adapter for '\(tab.name)': \(ObjectIdentifier(existing))"
                )
                lastCachedAdapterLog = now
            }
            return existing
        }
        
        // Phase 13.2: Create new adapter and cache it
        let created = ExtensionTabAdapter(
            tab: tab,
            browserManager: browserManager
        )
        tabAdapters[tab.id] = created
        print(
            "[ExtensionManager] Created NEW adapter for '\(tab.name)': \(ObjectIdentifier(created))"
        )
        return created
    }
    
    // Phase 13.2: Invalidate adapter cache when tab is closed
    @available(macOS 15.5, *)
    func invalidateAdapter(for tabId: UUID) {
        tabAdapters.removeValue(forKey: tabId)
        // Also invalidate tab list cache
        tabListCache = nil
    }

    // Expose a stable adapter getter for window adapters
    @available(macOS 15.4, *)
    func stableAdapter(for tab: Tab) -> ExtensionTabAdapter? {
        guard let bm = browserManagerRef else { return nil }
        return adapter(for: tab, browserManager: bm)
    }
    
    /// Phase 6: Get active tab adapter for command execution context
    @available(macOS 15.4, *)
    func getActiveTabAdapter() -> ExtensionTabAdapter? {
        guard let bm = browserManagerRef else { return nil }
        guard let activeTab = bm.currentTabForActiveWindow() else { return nil }
        return stableAdapter(for: activeTab)
    }

    @available(macOS 15.4, *)
    func notifyTabOpened(_ tab: Tab) {
        guard let bm = browserManagerRef, let controller = extensionController
        else { return }
        let a = adapter(for: tab, browserManager: bm)
        
        // Phase 3.7: Use context-specific notifications
        for (_, extensionContext) in extensionContexts {
            extensionContext.didOpenTab(a)
        }
        // Also notify controller for backward compatibility
        controller.didOpenTab(a)
    }

    @available(macOS 15.4, *)
    func notifyTabActivated(newTab: Tab, previous: Tab?) {
        guard let bm = browserManagerRef, let controller = extensionController
        else { return }
        let newA = adapter(for: newTab, browserManager: bm)
        let oldA = previous.map { adapter(for: $0, browserManager: bm) }
        
        // Phase 3.7: Use context-specific notifications
        for (_, extensionContext) in extensionContexts {
            extensionContext.didActivateTab(newA, previousActiveTab: oldA)
            extensionContext.didSelectTabs([newA])
            if let oldA { extensionContext.didDeselectTabs([oldA]) }
        }
        // Also notify controller for backward compatibility
        controller.didActivateTab(newA, previousActiveTab: oldA)
        controller.didSelectTabs([newA])
        if let oldA { controller.didDeselectTabs([oldA]) }
    }

    @available(macOS 15.4, *)
    func notifyTabClosed(_ tab: Tab) {
        guard let bm = browserManagerRef, let controller = extensionController
        else { return }
        let a = adapter(for: tab, browserManager: bm)
        
        // Phase 3.7: Use context-specific notifications
        for (_, extensionContext) in extensionContexts {
            extensionContext.didCloseTab(a, windowIsClosing: false)
        }
        // Also notify controller for backward compatibility
        controller.didCloseTab(a, windowIsClosing: false)
        tabAdapters[tab.id] = nil
    }

    @available(macOS 15.4, *)
    func notifyTabPropertiesChanged(
        _ tab: Tab,
        properties: WKWebExtension.TabChangedProperties
    ) {
        guard let bm = browserManagerRef, let controller = extensionController
        else { return }
        let a = adapter(for: tab, browserManager: bm)
        
        // Phase 3.7: Use context-specific notifications
        for (_, extensionContext) in extensionContexts {
            extensionContext.didChangeTabProperties(properties, for: a)
        }
        // Also notify controller for backward compatibility
        controller.didChangeTabProperties(properties, for: a)
    }
    
    // Phase 3.7: Additional context-specific notification methods
    
    @available(macOS 15.4, *)
    func notifyTabMoved(_ tab: Tab, fromIndex: Int, inWindow windowAdapter: ExtensionWindowAdapter) {
        guard let bm = browserManagerRef, let controller = extensionController else { return }
        let a = adapter(for: tab, browserManager: bm)
        
        // Phase 4.1: Use controller-level notification for all extensions
        controller.didMoveTab(a, from: fromIndex, in: windowAdapter)
        
        // Also use context-specific notifications (Phase 3.7)
        for (_, extensionContext) in extensionContexts {
            extensionContext.didMoveTab(a, from: fromIndex, in: windowAdapter)
        }
    }
    
    @available(macOS 15.4, *)
    func notifyTabReplaced(oldTab: Tab, with newTab: Tab) {
        guard let bm = browserManagerRef, let controller = extensionController else { return }
        let oldA = adapter(for: oldTab, browserManager: bm)
        let newA = adapter(for: newTab, browserManager: bm)
        
        // Phase 4.2: Use controller-level notification for all extensions
        controller.didReplaceTab(oldA, with: newA)
        
        // Also use context-specific notifications (Phase 3.7)
        for (_, extensionContext) in extensionContexts {
            extensionContext.didReplaceTab(oldA, with: newA)
        }
        
        print("🔄 [Phase 4.2] Tab replaced: \(oldTab.name) -> \(newTab.name)")
    }
    
    // MARK: - Phase 9.1: Data Record Management
    
    /// Fetch all extension data records
    /// - Parameters:
    ///   - ofTypes: Set of data types to fetch. Defaults to all available types.
    ///   - completionHandler: Completion handler with array of data records or error
    @available(macOS 15.4, *)
    func fetchExtensionDataRecords(
        ofTypes dataTypes: Set<WKWebExtension.DataType>? = nil,
        completionHandler: @escaping ([WKWebExtension.DataRecord]?, Error?) -> Void
    ) {
        guard let controller = extensionController else {
            completionHandler(nil, NSError(domain: "ExtensionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Extension controller not available"]))
            return
        }
        
        // Use provided types or default to all available types
        let typesToFetch: Set<WKWebExtension.DataType> = dataTypes ?? [
            .local, .session, .synchronized
        ]
        
        controller.fetchDataRecords(ofTypes: typesToFetch) { records in
            print("✅ [Phase 9.1] Fetched \(records.count) extension data records")
            completionHandler(records, nil)
        }
    }
    
    /// Remove extension data
    /// - Parameters:
    ///   - ofTypes: Set of data types to remove
    ///   - from: Extension ID, or nil to remove from all extensions
    ///   - completionHandler: Completion handler with error if any
    @available(macOS 15.4, *)
    func removeExtensionData(
        ofTypes dataTypes: Set<WKWebExtension.DataType>,
        from extensionId: String?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let controller = extensionController else {
            completionHandler(NSError(domain: "ExtensionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Extension controller not available"]))
            return
        }
        
        if let extensionId = extensionId {
            // Fetch data records for the specific extension first
            controller.fetchDataRecord(ofTypes: dataTypes, for: extensionContexts[extensionId]!) { dataRecord in
                if let dataRecord = dataRecord {
                    controller.removeData(ofTypes: dataTypes, from: [dataRecord]) {
                        print("✅ [Phase 9.1] Removed data from extension: \(extensionId)")
                        completionHandler(nil)
                    }
                } else {
                    print("⚠️ [Phase 9.1] No data record found for extension: \(extensionId)")
                    completionHandler(nil)
                }
            }
        } else {
            // Remove data from all extensions (extensionId is nil) - fetch all records first
            controller.fetchDataRecords(ofTypes: dataTypes) { dataRecords in
                controller.removeData(ofTypes: dataTypes, from: dataRecords) {
                    print("✅ [Phase 9.1] Removed data from all extensions")
                    completionHandler(nil)
                }
            }
        }
    }
    
    @available(macOS 15.4, *)
    func notifyWindowClosed(_ windowAdapter: ExtensionWindowAdapter) {
        // Use context-specific notifications
        for (_, extensionContext) in extensionContexts {
            extensionContext.didCloseWindow(windowAdapter)
        }
    }
    
    // MARK: - Phase 4.4: Extension Context Lookup
    
    /// Get extension ID for a specific unique identifier (UUID)
    @available(macOS 15.4, *)
    func getExtensionId(for uniqueIdentifier: UUID) -> String? {
        for (id, context) in extensionContexts {
            if context.uniqueIdentifier == uniqueIdentifier.uuidString {
                return id
            }
        }
        return nil
    }
    
    /// Get extension ID for a specific unique identifier (String)
    /// Attempts to match by UUID string representation or by direct string comparison
    @available(macOS 15.4, *)
    func getExtensionId(for uniqueIdentifier: String) -> String? {
        // First try to convert to UUID and use the UUID overload
        if let uuid = UUID(uuidString: uniqueIdentifier) {
            return getExtensionId(for: uuid)
        }
        
        // If not a valid UUID, try string comparison with UUID string representations
        for (id, context) in extensionContexts {
            if context.uniqueIdentifier == uniqueIdentifier {
                return id
            }
        }
        return nil
    }
    
    /// Get extension context for a specific extension ID
    @available(macOS 15.4, *)
    func getExtensionContext(for extensionId: String) -> WKWebExtensionContext? {
        // First check our internal cache
        if let context = extensionContexts[extensionId] {
            return context
        }
        
        // Fallback to controller lookup
        guard let controller = extensionController,
              let webExtension = extensionContexts[extensionId]?.webExtension else {
            return nil
        }
        
        return controller.extensionContext(for: webExtension)
    }
    
    /// Get extension context for a specific extension
    @available(macOS 15.4, *)
    func getExtensionContext(for webExtension: WKWebExtension) -> WKWebExtensionContext? {
        guard let controller = extensionController else { return nil }
        return controller.extensionContext(for: webExtension)
    }
    
    /// Get extension context for a specific URL (if it's an extension URL)
    @available(macOS 15.4, *)
    func getExtensionContext(for url: URL) -> WKWebExtensionContext? {
        guard let controller = extensionController else { return nil }
        
        // Check if URL is an extension URL
        if url.scheme == "chrome-extension" || url.scheme == "moz-extension" || url.scheme == "safari-extension" || url.scheme == "nook" {
            return controller.extensionContext(for: url)
        }
        
        return nil
    }
    
    /// Get web view configuration for an extension URL
    @available(macOS 15.4, *)
    func getWebViewConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard let extensionContext = getExtensionContext(for: url) else { return nil }
        return extensionContext.webViewConfiguration
    }
    
    // MARK: - Phase 11.1: Extension Property Queries
    
    /// Get a specific extension property value
    /// - Parameters:
    ///   - property: The property name to query
    ///   - extensionId: The extension ID
    /// - Returns: The property value, or nil if not found
    @available(macOS 15.4, *)
    func getExtensionProperty(_ property: String, for extensionId: String) -> Any? {
        guard let extensionContext = extensionContexts[extensionId] else {
            return nil
        }
        
        let webExtension = extensionContext.webExtension
        
        switch property {
        case "hasBackgroundContent":
            return webExtension.hasBackgroundContent
        case "hasPersistentBackgroundContent":
            return webExtension.hasPersistentBackgroundContent
        case "hasInjectedContent":
            return webExtension.hasInjectedContent
        case "hasOptionsPage":
            return webExtension.hasOptionsPage
        case "hasOverrideNewTabPage":
            return webExtension.hasOverrideNewTabPage
        case "displayName":
            return webExtension.displayName
        case "version":
            return webExtension.version
        case "description":
            return webExtension.description
        case "uniqueIdentifier":
            return extensionContext.uniqueIdentifier
        default:
            return nil
        }
    }
    
    /// Get all extension properties as a dictionary
    /// - Parameter extensionId: The extension ID
    /// - Returns: Dictionary of property names to values
    @available(macOS 15.4, *)
    func getAllExtensionProperties(for extensionId: String) -> [String: Any] {
        guard let extensionContext = extensionContexts[extensionId] else {
            return [:]
        }
        
        let webExtension = extensionContext.webExtension
        
        return [
            "hasBackgroundContent": webExtension.hasBackgroundContent,
            "hasPersistentBackgroundContent": webExtension.hasPersistentBackgroundContent,
            "hasInjectedContent": webExtension.hasInjectedContent,
            "hasOptionsPage": webExtension.hasOptionsPage,
            "hasOverrideNewTabPage": webExtension.hasOverrideNewTabPage,
            "displayName": webExtension.displayName ?? "",
            "version": webExtension.version ?? "",
            "description": webExtension.description ?? "",
            "uniqueIdentifier": extensionContext.uniqueIdentifier
        ]
    }
    
    /// Check if extension can access a URL
    /// - Parameters:
    ///   - url: The URL to check
    ///   - extensionId: The extension ID
    /// - Returns: true if extension can access the URL
    @available(macOS 15.4, *)
    func canAccessURL(_ url: URL, for extensionId: String) -> Bool {
        guard let extensionContext = extensionContexts[extensionId] else {
            return false
        }
        
        // Check if URL matches any granted match patterns
        let grantedPatterns = extensionContext.grantedPermissionMatchPatterns
        for (pattern, _) in grantedPatterns {
            if pattern.matches(url) {
                return true
            }
        }
        
        // Check if extension has <all_urls> permission
        if let allURLsPattern = ExtensionUtils.allURLsMatchPattern,
           grantedPatterns.keys.contains(allURLsPattern) {
            return true
        }
        
        return false
    }
    
    /// Get all requested permissions for an extension
    /// - Parameter extensionId: The extension ID
    /// - Returns: Set of requested permissions
    @available(macOS 15.4, *)
    func getRequestedPermissions(for extensionId: String) -> Set<WKWebExtension.Permission> {
        guard let extensionContext = extensionContexts[extensionId] else {
            return []
        }
        return extensionContext.webExtension.requestedPermissions
    }
    
    /// Get all optional permissions for an extension
    /// - Parameter extensionId: The extension ID
    /// - Returns: Set of optional permissions
    @available(macOS 15.4, *)
    func getOptionalPermissions(for extensionId: String) -> Set<WKWebExtension.Permission> {
        guard let extensionContext = extensionContexts[extensionId] else {
            return []
        }
        return extensionContext.webExtension.optionalPermissions
    }
    
    /// Get currently granted permissions for an extension
    /// - Parameter extensionId: The extension ID
    /// - Returns: Set of granted permissions
    @available(macOS 15.4, *)
    func getCurrentPermissions(for extensionId: String) -> Set<WKWebExtension.Permission> {
        guard let extensionContext = extensionContexts[extensionId] else {
            return []
        }
        return Set(extensionContext.grantedPermissions.keys)
    }
    
    /// Get extension display name
    /// - Parameter extensionId: The extension ID
    /// - Returns: Display name, or nil if not found
    @available(macOS 15.4, *)
    func getExtensionDisplayName(for extensionId: String) -> String? {
        guard let extensionContext = extensionContexts[extensionId] else {
            return nil
        }
        return extensionContext.webExtension.displayName
    }
    
    /// Get extension version
    /// - Parameter extensionId: The extension ID
    /// - Returns: Version string, or nil if not found
    @available(macOS 15.4, *)
    func getExtensionVersion(for extensionId: String) -> String? {
        guard let extensionContext = extensionContexts[extensionId] else {
            return nil
        }
        return extensionContext.webExtension.version
    }
    
    /// Get extension description
    /// - Parameter extensionId: The extension ID
    /// - Returns: Description string, or nil if not found
    @available(macOS 15.4, *)
    func getExtensionDescription(for extensionId: String) -> String? {
        guard let extensionContext = extensionContexts[extensionId] else {
            return nil
        }
        return extensionContext.webExtension.description
    }
    
    /// Get extension icons at different sizes with caching
    /// - Parameters:
    ///   - extensionId: The extension ID
    ///   - size: The desired icon size
    /// - Returns: NSImage if available, nil otherwise
    @available(macOS 15.4, *)
    func getExtensionIcons(for extensionId: String, size: NSSize) -> NSImage? {
        // Phase 12.2: Check cache first
        if let cachedIcons = iconCache[extensionId],
           let cachedIcon = cachedIcons[size] {
            return cachedIcon
        }
        
        guard let extensionContext = extensionContexts[extensionId] else {
            return nil
        }
        
        // Load icon from extension
        guard let icon = extensionContext.webExtension.icon(for: size) else {
            return nil
        }
        
        // Phase 12.2: Cache the icon
        cacheIcon(icon, for: extensionId, size: size)
        
        return icon
    }
    
    // MARK: - Phase 13.2: Performance Optimization Methods
    
    /// Batch update permissions for an extension
    /// - Parameters:
    ///   - permissions: Set of permissions to update
    ///   - status: The status to set
    ///   - extensionId: The extension ID
    @available(macOS 15.4, *)
    func batchUpdatePermissions(_ permissions: Set<WKWebExtension.Permission>, status: WKWebExtensionContext.PermissionStatus, for extensionId: String) {
        guard let extensionContext = extensionContexts[extensionId] else { return }
        
        // Phase 13.2: Add to pending updates
        if pendingPermissionUpdates[extensionId] == nil {
            pendingPermissionUpdates[extensionId] = []
        }
        pendingPermissionUpdates[extensionId]?.formUnion(permissions)
        
        // Phase 13.2: Schedule batch update if not already scheduled
        if permissionUpdateTimer == nil {
            permissionUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                self?.processPendingPermissionUpdates()
            }
        }
    }
    
    /// Process pending permission updates in batch
    @available(macOS 15.4, *)
    private func processPendingPermissionUpdates() {
        permissionUpdateTimer?.invalidate()
        permissionUpdateTimer = nil
        
        for (extensionId, permissions) in pendingPermissionUpdates {
            guard let extensionContext = extensionContexts[extensionId] else { continue }
            
            // Apply all pending updates
            for permission in permissions {
                // Get the status from cache or use default
                let status = permissionStatusCache[extensionId]?[String(describing: permission)]?.status ?? .deniedExplicitly
                extensionContext.setPermissionStatus(status, for: permission)
            }
            
            // Invalidate permission cache
            permissionStatusCache[extensionId] = nil
        }
        
        pendingPermissionUpdates.removeAll()
    }
    
    /// Get cached property value or fetch and cache it
    /// - Parameters:
    ///   - property: Property name
    ///   - extensionId: Extension ID
    /// - Returns: Property value or nil
    @available(macOS 15.4, *)
    func getCachedProperty(_ property: String, for extensionId: String) -> Any? {
        let now = Date()
        
        // Check cache
        if let cache = propertyCache[extensionId],
           now.timeIntervalSince(cache.timestamp) < propertyCacheTTL,
           let value = cache.properties[property] {
            return value
        }
        
        // Fetch and cache
        let value = getExtensionProperty(property, for: extensionId)
        if var cache = propertyCache[extensionId] {
            cache.properties[property] = value
            cache.timestamp = now
            propertyCache[extensionId] = cache
        } else {
            propertyCache[extensionId] = (properties: [property: value as Any], timestamp: now)
        }
        
        return value
    }
    
    /// Invalidate property cache for an extension
    /// - Parameter extensionId: Extension ID
    @available(macOS 15.4, *)
    func invalidatePropertyCache(for extensionId: String) {
        propertyCache.removeValue(forKey: extensionId)
    }
    
    /// Invalidate all caches (call when extensions are loaded/unloaded)
    @available(macOS 15.4, *)
    func invalidateAllCaches() {
        propertyCache.removeAll()
        tabListCache = nil
        windowListCache = nil
        permissionStatusCache.removeAll()
    }
    
    /// Get cached icon for an extension
    /// - Parameters:
    ///   - extensionId: The extension ID
    ///   - size: The desired icon size
    /// - Returns: Cached NSImage if available, nil otherwise
    @available(macOS 15.4, *)
    func getCachedIcon(for extensionId: String, size: NSSize) -> NSImage? {
        return iconCache[extensionId]?[size]
    }
    
    /// Cache an icon for an extension
    /// - Parameters:
    ///   - icon: The icon to cache
    ///   - extensionId: The extension ID
    ///   - size: The icon size
    @available(macOS 15.4, *)
    func cacheIcon(_ icon: NSImage, for extensionId: String, size: NSSize) {
        if iconCache[extensionId] == nil {
            iconCache[extensionId] = [:]
        }
        iconCache[extensionId]?[size] = icon
    }
    
    /// Clear icon cache for an extension
    /// - Parameter extensionId: The extension ID
    @available(macOS 15.4, *)
    func clearIconCache(for extensionId: String) {
        iconCache.removeValue(forKey: extensionId)
    }
    
    /// Check if extension is inspectable
    /// - Parameter extensionId: The extension ID
    /// - Returns: true if inspectable, false otherwise
    @available(macOS 15.4, *)
    func isExtensionInspectable(_ extensionId: String) -> Bool {
        guard let extensionContext = extensionContexts[extensionId] else {
            return false
        }
        return extensionContext.isInspectable
    }
    
    /// Set extension inspectable state
    /// - Parameters:
    ///   - inspectable: Whether the extension should be inspectable
    ///   - extensionId: The extension ID
    @available(macOS 15.4, *)
    func setExtensionInspectable(_ inspectable: Bool, for extensionId: String) {
        setInspectable(inspectable, for: extensionId)
    }
    
    /// Get extension manifest data
    /// - Parameter extensionId: The extension ID
    /// - Returns: Manifest dictionary, or nil if not found
    @available(macOS 15.4, *)
    func getExtensionManifest(for extensionId: String) -> [String: Any]? {
        guard let extensionContext = extensionContexts[extensionId] else {
            return nil
        }
        
        // WKWebExtension doesn't directly expose manifest, but we can reconstruct key info
        let webExtension = extensionContext.webExtension
        var manifest: [String: Any] = [:]
        
        if let displayName = webExtension.displayName {
            manifest["name"] = displayName
        }
        if let version = webExtension.version {
            manifest["version"] = version
        }
        manifest["description"] = webExtension.description
        
        manifest["hasBackgroundContent"] = webExtension.hasBackgroundContent
        manifest["hasPersistentBackgroundContent"] = webExtension.hasPersistentBackgroundContent
        manifest["hasInjectedContent"] = webExtension.hasInjectedContent
        manifest["hasOptionsPage"] = webExtension.hasOptionsPage
        manifest["hasOverrideNewTabPage"] = webExtension.hasOverrideNewTabPage
        
        return manifest
    }
    
    /// Get extension installation state
    /// - Parameter extensionId: The extension ID
    /// - Returns: Installation state string, or nil if not found
    @available(macOS 15.4, *)
    func getExtensionInstallationState(for extensionId: String) -> String? {
        guard let extensionContext = extensionContexts[extensionId] else {
            return "not_installed"
        }
        
        // Check if extension is loaded
        if extensionContexts[extensionId] != nil {
            return "installed"
        }
        
        return "unknown"
    }

    /// Register a UI anchor view for an extension action button to position popovers.
    func setActionAnchor(for extensionId: String, anchorView: NSView) {
        let anchor = WeakAnchor(view: anchorView, window: anchorView.window)
        if actionAnchors[extensionId] == nil { actionAnchors[extensionId] = [] }
        // Remove stale anchors
        actionAnchors[extensionId]?.removeAll { $0.view == nil }
        if let idx = actionAnchors[extensionId]?.firstIndex(where: {
            $0.view === anchorView
        }) {
            actionAnchors[extensionId]?[idx] = anchor
        } else {
            actionAnchors[extensionId]?.append(anchor)
        }
        if anchor.window == nil {
            DispatchQueue.main.async { [weak self, weak anchorView] in
                guard let view = anchorView else { return }
                let updated = WeakAnchor(view: view, window: view.window)
                if let idx = self?.actionAnchors[extensionId]?.firstIndex(
                    where: { $0.view === view })
                {
                    self?.actionAnchors[extensionId]?[idx] = updated
                }
            }
        }
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Present the extension's action popover; keep behavior minimal and stable

        // Ensure critical permissions at popup time (user-invoked -> activeTab should be granted)
        extensionContext.setPermissionStatus(
            .grantedExplicitly,
            for: .activeTab
        )
        extensionContext.setPermissionStatus(
            .grantedExplicitly,
            for: .scripting
        )
        extensionContext.setPermissionStatus(.grantedExplicitly, for: .tabs)

        // Find the extension ID for this context to track popup lifecycle
        guard let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key else {
            print("❌ DELEGATE: Could not find extension ID for popup context")
            completionHandler(
                NSError(
                    domain: "ExtensionManager",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not find extension ID"]
                )
            )
            return
        }

        // Close any existing popup for this extension
        if let existingPopover = activePopovers[extensionId] {
            print("🔄 Closing existing popup for extension: \(extensionId)")
            existingPopover.close()
            activePopovers.removeValue(forKey: extensionId)
        }

        // Clean up any existing popup WebView for this extension
        if let existingWebView = popupWebViews[extensionId] {
            existingWebView.configuration.webExtensionController = nil
            popupWebViews.removeValue(forKey: extensionId)
        }

        // No additional diagnostics

        // No extension-specific diagnostics

        // Focus state should already be correct, avoid re-notifying controller during delegate callback

        guard let popover = action.popupPopover else {
            print("❌ DELEGATE: No popover available on action")
            completionHandler(
                NSError(
                    domain: "ExtensionManager",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No popover available"
                    ]
                )
            )
            return
        }

        print(
            "✅ DELEGATE: Native popover available - configuring and presenting!"
        )

        if let webView = action.popupWebView {

            // Ensure the WebView has proper configuration for extension resources
            if webView.configuration.webExtensionController == nil {
                webView.configuration.webExtensionController = controller
                print("   Attached extension controller to popup WebView")
            }

            // Track the popup WebView for lifecycle management
            popupWebViews[extensionId] = webView

            // Enable inspection for debugging
            webView.isInspectable = true

            // Temporarily disable console helper to test if it's causing container errors
            // PopupConsole.shared.attach(to: webView)

            // No custom message handlers; rely on native MV3 APIs

            if shouldAutoSizeActionPopups {
                // Install a light ResizeObserver to autosize the popover to content
                let resizeScript = """
                    (function(){
                      try {
                        const post = (label, payload) => { try { webkit.messageHandlers.NookDiag.postMessage({label, payload, phase:'resize'}); } catch(_){} };
                        const measure = () => {
                          const d=document, e=d.documentElement, b=d.body;
                          const w = Math.ceil(Math.max(e.scrollWidth, b?b.scrollWidth:0, e.clientWidth));
                          const h = Math.ceil(Math.max(e.scrollHeight, b?b.scrollHeight:0, e.clientHeight));
                          post('popupSize', {w, h});
                        };
                        new ResizeObserver(measure).observe(document.documentElement);
                        window.addEventListener('load', measure);
                        setTimeout(measure, 50); setTimeout(measure, 250); setTimeout(measure, 800);
                      } catch(_){}
                    })();
                    """
                let user = WKUserScript(
                    source: resizeScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
                webView.configuration.userContentController.addUserScript(user)
            }

            // Minimal polyfills for Chromium-only APIs some extensions feature-detect
            let polyfillScript = """
                (function(){
                  try {
                    window.chrome = window.chrome || {};
                    var chromeNS = window.chrome;
                    chromeNS.identity = chromeNS.identity || {};

                    var pendingIdentityRequests = Object.create(null);
                    var identityCounter = 0;

                    chromeNS.identity.launchWebAuthFlow = function(details, callback){
                      var url = details && details.url ? String(details.url) : null;
                      if (!url) {
                        var missingUrlError = new Error('launchWebAuthFlow requires a url');
                        if (typeof callback === 'function') {
                          try { callback(null); } catch (_) {}
                        }
                        return Promise.reject(missingUrlError);
                      }

                      var interactive = !!(details && details.interactive);
                      var prefersEphemeral = !!(details && details.useEphemeralSession);
                      var callbackScheme = null;
                      if (details && typeof details.callbackURLScheme === 'string' && details.callbackURLScheme.length > 0) {
                        callbackScheme = details.callbackURLScheme;
                      }

                      var requestId = 'nook-auth-' + (++identityCounter);
                      var entry = {
                        resolve: null,
                        reject: null,
                        callback: (typeof callback === 'function') ? callback : null
                      };

                      var promise = new Promise(function(resolve, reject){
                        entry.resolve = resolve;
                        entry.reject = reject;
                      });

                      pendingIdentityRequests[requestId] = entry;

                      try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.NookIdentity) {
                          window.webkit.messageHandlers.NookIdentity.postMessage({
                            requestId: requestId,
                            url: url,
                            interactive: interactive,
                            prefersEphemeral: prefersEphemeral,
                            callbackScheme: callbackScheme
                          });
                        } else {
                          throw new Error('Native identity bridge unavailable');
                        }
                      } catch (error) {
                        delete pendingIdentityRequests[requestId];
                        if (entry.reject) { entry.reject(error); }
                        if (entry.callback) {
                          try { entry.callback(null); } catch (_) {}
                        }
                        return Promise.reject(error);
                      }

                      return promise;
                    };

                    if (typeof window.__nookCompleteIdentityFlow !== 'function') {
                      window.__nookCompleteIdentityFlow = function(result) {
                        if (!result || !result.requestId) { return; }
                        var entry = pendingIdentityRequests[result.requestId];
                        if (!entry) { return; }
                        delete pendingIdentityRequests[result.requestId];

                        var status = result.status || 'failure';
                        if (status === 'success') {
                          var payload = result.url || null;
                          if (entry.resolve) { entry.resolve(payload); }
                          if (entry.callback) {
                            try { entry.callback(payload); } catch (_) {}
                          }
                        } else {
                          var errMessage = result.message || 'Authentication failed';
                          var error = new Error(errMessage);
                          if (result.code) { error.code = result.code; }
                          if (entry.reject) { entry.reject(error); }
                          if (entry.callback) {
                            try { entry.callback(null); } catch (_) {}
                          }
                        }
                      };
                    }

                    if (typeof chromeNS.webRequestAuthProvider === 'undefined') {
                      chromeNS.webRequestAuthProvider = {
                        addListener: function(){},
                        removeListener: function(){}
                      };
                    }
                  } catch(_){}
                })();
                """
            let polyfill = WKUserScript(
                source: polyfillScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(polyfill)

            let worldProbe = """
                (async function(){
                  try {
                    const tabsNS = (browser?.tabs || chrome?.tabs);
                    const scriptingNS = (browser?.scripting || chrome?.scripting);
                    if (!tabsNS || !scriptingNS) return 'no-apis';
                    let tabs;
                    try { tabs = await tabsNS.query({active:true, currentWindow:true}); } catch(_) {
                      // callback fallback
                      tabs = await new Promise((resolve,reject)=>{ try { tabsNS.query({active:true,currentWindow:true}, (t)=>resolve(t)); } catch(e){ reject(e); } });
                    }
                    const t = tabs && tabs[0];
                    if (!t || t.id == null) return 'no-tab';
                    const res = await scriptingNS.executeScript({ target: { tabId: t.id }, world: 'MAIN', func: function(){ try { document.documentElement.setAttribute('data-Nook-probe','1'); return 'ok'; } catch(e){ return 'err:'+String(e); } } });
                    return 'ok:' + (res && res.length ? 'len='+res.length : 'nores');
                  } catch(e) {
                    return 'err:' + (e && (e.message||String(e)));
                  }
                })();
                """

            webView.evaluateJavaScript(worldProbe) { result, error in
                if let error = error {
                    print("   World probe error: \(error.localizedDescription)")
                } else {
                    print(
                        "   World probe result: \(String(describing: result))"
                    )
                }
            }

            // After a short delay, verify in the page WebView whether the probe attribute was set
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                [weak self] in
                guard let self = self else { return }
                if let windowAdapter = self.windowAdapter,
                    let activeTab = windowAdapter.activeTab(
                        for: extensionContext
                    ),
                    let tabAdapter = activeTab as? ExtensionTabAdapter
                {
                    guard let pageWV = tabAdapter.tab.webView else { return }
                    pageWV.evaluateJavaScript(
                        "document.documentElement.getAttribute('data-Nook-probe')"
                    ) { val, err in
                        if let err = err {
                            print(
                                "   Page probe read error: \(err.localizedDescription)"
                            )
                        } else {
                            print(
                                "   Page probe attribute: \(String(describing: val))"
                            )
                        }
                    }
                }
            }
        } else {
            print("   No popupWebView present on action")
        }

        // Present the popover on main thread
        DispatchQueue.main.async {
            let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            // Keep popover size fixed; no autosizing bookkeeping

            // Try to use registered anchor for this extension
            if let extId = self.extensionContexts.first(where: {
                $0.value === extensionContext
            })?.key,
                var anchors = self.actionAnchors[extId]
            {
                // Clean up stale anchors
                anchors.removeAll { $0.view == nil }
                self.actionAnchors[extId] = anchors

                // Find anchor in current window
                if let win = targetWindow,
                    let match = anchors.first(where: { $0.window === win }),
                    let view = match.view
                {
                    print("   Using registered anchor in current window")

                    // Track the popover for lifecycle management
                    self.activePopovers[extensionId] = popover
                    
                    // Phase 5.3: Set up popover delegate to call action.closePopup() when closed
                    if #available(macOS 15.5, *) {
                        let delegate = ExtensionActionPopoverDelegate(
                            action: action,
                            extensionId: extensionId,
                            extensionManager: self
                        )
                        popover.delegate = delegate
                        self.popoverDelegates[extensionId] = delegate
                    }

                    popover.show(
                        relativeTo: view.bounds,
                        of: view,
                        preferredEdge: .maxY
                    )
                    completionHandler(nil)
                    return
                }

                // Use first available anchor
                if let view = anchors.first?.view {
                    print("   Using first available anchor")

                    // Track the popover for lifecycle management
                    self.activePopovers[extensionId] = popover
                    
                    // Phase 5.3: Set up popover delegate to call action.closePopup() when closed
                    if #available(macOS 15.5, *) {
                        let delegate = ExtensionActionPopoverDelegate(
                            action: action,
                            extensionId: extensionId,
                            extensionManager: self
                        )
                        popover.delegate = delegate
                        self.popoverDelegates[extensionId] = delegate
                    }

                    popover.show(
                        relativeTo: view.bounds,
                        of: view,
                        preferredEdge: .maxY
                    )
                    completionHandler(nil)
                    return
                }
            }

            // Fallback to center of window
            if let window = targetWindow, let contentView = window.contentView {
                let rect = CGRect(
                    x: contentView.bounds.midX - 10,
                    y: contentView.bounds.maxY - 50,
                    width: 20,
                    height: 20
                )
                print("   Using fallback anchor in center of window")

                // Track the popover for lifecycle management
                self.activePopovers[extensionId] = popover
                
                // Phase 5.3: Set up popover delegate to call action.closePopup() when closed
                if #available(macOS 15.5, *) {
                    let delegate = ExtensionActionPopoverDelegate(
                        action: action,
                        extensionId: extensionId,
                        extensionManager: self
                    )
                    popover.delegate = delegate
                    self.popoverDelegates[extensionId] = delegate
                }

                popover.show(
                    relativeTo: rect,
                    of: contentView,
                    preferredEdge: .minY
                )
                completionHandler(nil)
                return
            }

            print("❌ DELEGATE: No anchor or contentView available")
            completionHandler(
                NSError(
                    domain: "ExtensionManager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No window available"]
                )
            )
        }
    }

    // MARK: - Popup Lifecycle Management (Phase 5.3)

    /// Close the popup for a specific extension (called by action.closePopup())
    func closeExtensionPopup(for extensionId: String) {
        print("🔐 [Phase 5.3] Closing popup for extension: \(extensionId)")

        // Phase 5.3: Call action.closePopup() if we have the action
        if #available(macOS 15.5, *), let action = extensionActions[extensionId] {
            action.closePopup()
            print("   Called action.closePopup()")
        }

        // Close and remove popover
        if let popover = activePopovers[extensionId] {
            // Remove delegate before closing to avoid double-cleanup
            popover.delegate = nil
            popover.close()
            activePopovers.removeValue(forKey: extensionId)
            print("   Closed active popover")
        }
        
        // Clean up popover delegate
        popoverDelegates.removeValue(forKey: extensionId)

        // Clean up popup WebView
        if let webView = popupWebViews[extensionId] {
            webView.configuration.webExtensionController = nil
            popupWebViews.removeValue(forKey: extensionId)
            print("   Cleaned up popup WebView")
        }
    }

    /// Close all active extension popups (called during extension unload, etc.)
    func closeAllExtensionPopups() {
        print("🔐 [Phase 5.3] Closing all extension popups")

        // Phase 5.3: Call action.closePopup() for all active actions
        if #available(macOS 15.5, *) {
            for (extensionId, action) in extensionActions {
                if activePopovers[extensionId] != nil {
                    action.closePopup()
                    print("   Called action.closePopup() for extension: \(extensionId)")
                }
            }
        }

        // Close all popovers
        for (extensionId, popover) in activePopovers {
            popover.delegate = nil
            popover.close()
            print("   Closed popover for extension: \(extensionId)")
        }
        activePopovers.removeAll()
        popoverDelegates.removeAll()

        // Clean up all popup WebViews
        for (extensionId, webView) in popupWebViews {
            webView.configuration.webExtensionController = nil
            print("   Cleaned up WebView for extension: \(extensionId)")
        }
        popupWebViews.removeAll()
    }

    /// Check if an extension currently has an active popup
    func hasActivePopup(for extensionId: String) -> Bool {
        return activePopovers[extensionId] != nil
    }

    // MARK: - Action Update Delegate (Phase 2.1)
    /// Called when an action's properties are updated (icon, label, badgeText, enabled state, menuItems)
    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext extensionContext: WKWebExtensionContext
    ) {
        // Find the extension ID for this context
        guard let extensionId = extensionContexts.first(where: { $0.value === extensionContext })?.key else {
            print("⚠️ [Action Update] Could not find extension ID for context")
            return
        }

        // Store the action reference for this extension
        extensionActions[extensionId] = action

        print("🔄 [Action Update] Extension: \(extensionId)")
        print("   Label: \(action.label)")
        print("   Badge Text: \(action.badgeText)")
        print("   Enabled: \(action.isEnabled)")
        print("   Has Unread Badge: \(action.hasUnreadBadgeText)")
        print("   Menu Items Count: \(action.menuItems.count)")

        // Post notification so UI can update
        NotificationCenter.default.post(
            name: NSNotification.Name("ExtensionActionDidUpdate"),
            object: nil,
            userInfo: [
                "extensionId": extensionId,
                "action": action
            ]
        )
    }

    // MARK: - Native Messaging Delegate (Phase 2.2)
    /// Called when an extension wants to send a one-time message to native application code
    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        print("📨 [NativeMessaging] Received message from extension")
        print("   Extension: \(extensionContext.webExtension.displayName ?? "Unknown")")
        print("   Application Identifier: \(applicationIdentifier ?? "nil")")
        print("   Message: \(message)")
        
        // Validate message is JSON-serializable
        guard JSONSerialization.isValidJSONObject(message) else {
            print("❌ [NativeMessaging] Message is not JSON-serializable")
            replyHandler(
                nil,
                NSError(
                    domain: "NativeMessaging",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Message must be JSON-serializable"
                    ]
                )
            )
            return
        }
        
        // Process message asynchronously
        Task { @MainActor in
            do {
                let reply = try await NativeMessagingManager.shared.processMessage(
                    message,
                    applicationIdentifier: applicationIdentifier,
                    extensionContext: extensionContext
                )
                print("✅ [NativeMessaging] Message processed successfully")
                replyHandler(reply, nil)
            } catch {
                print("❌ [NativeMessaging] Error processing message: \(error.localizedDescription)")
                replyHandler(nil, error)
            }
        }
    }

    // MARK: - Native Messaging Port Delegate (Phase 2.3)
    /// Called when an extension wants to establish a persistent connection to native application code
    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let extensionName = extensionContext.webExtension.displayName ?? "Unknown"
        let applicationIdentifier = port.applicationIdentifier
        print("🔌 [NativeMessaging] Extension '\(extensionName)' requesting port connection")
        print("   Application Identifier: \(applicationIdentifier ?? "nil")")
        
        // Create connection via NativeMessagingManager
        let connection = NativeMessagingManager.shared.createConnection(
            port: port,
            extensionContext: extensionContext,
            applicationIdentifier: applicationIdentifier
        )
        
        // Notify handler that connection was established
        if let handler = NativeMessagingManager.shared.getPortHandler(for: applicationIdentifier) {
            handler.portDidConnect(
                connection,
                applicationIdentifier: applicationIdentifier,
                extensionContext: extensionContext
            )
        }
        
        // Connection is ready
        print("✅ [NativeMessaging] Port connection established")
        completionHandler(nil)
    }

    // MARK: - WKScriptMessageHandler (popup bridge)
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // No custom message handling
    }

    // MARK: - WKNavigationDelegate (popup diagnostics)
    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        let urlString = webView.url?.absoluteString ?? "(nil)"
        print("[Popup] didStartProvisionalNavigation: \"\(urlString)\"")
        PopupConsole.shared.log("[Navigation] Started loading: \(urlString)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let urlString = webView.url?.absoluteString ?? "(nil)"
        print("[Popup] didCommit: \"\(urlString)\"")
        PopupConsole.shared.log("[Navigation] Committed: \(urlString)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let urlString = webView.url?.absoluteString ?? "(nil)"
        print("[Popup] didFinish: \"\(urlString)\"")
        PopupConsole.shared.log("[Navigation] Finished: \(urlString)")

        // Get document title
        webView.evaluateJavaScript("document.title") { value, _ in
            let title = (value as? String) ?? "(unknown)"
            print("[Popup] document.title: \"\(title)\"")
            PopupConsole.shared.log("[Document] Title: \(title)")
        }

        // Comprehensive capability probe for extension APIs
        let comprehensiveProbe = """
            (() => {
                const result = {
                    location: {
                        href: location.href,
                        protocol: location.protocol,
                        host: location.host
                    },
                    document: {
                        title: document.title,
                        readyState: document.readyState,
                        hasBody: !!document.body,
                        bodyText: document.body ? document.body.innerText.slice(0, 100) : null
                    },
                    apis: {
                        browser: typeof browser !== 'undefined',
                        chrome: typeof chrome !== 'undefined',
                        runtime: typeof (browser?.runtime || chrome?.runtime) !== 'undefined',
                        storage: {
                            available: typeof (browser?.storage || chrome?.storage) !== 'undefined',
                            local: typeof (browser?.storage?.local || chrome?.storage?.local) !== 'undefined',
                            sync: typeof (browser?.storage?.sync || chrome?.storage?.sync) !== 'undefined'
                        },
                        tabs: typeof (browser?.tabs || chrome?.tabs) !== 'undefined',
                        action: typeof (browser?.action || chrome?.action) !== 'undefined'
                    },
                    errors: []
                };
                
                // Check for common popup errors
                try {
                    if (typeof browser !== 'undefined' && browser.runtime) {
                        result.runtime = {
                            id: browser.runtime.id,
                            url: browser.runtime.getURL ? browser.runtime.getURL('') : 'getURL not available'
                        };
                    }
                } catch (e) {
                    result.errors.push('Runtime error: ' + e.message);
                }
                
                return result;
            })()
            """

        webView.evaluateJavaScript(comprehensiveProbe) { value, error in
            if let error = error {
                print(
                    "[Popup] comprehensive probe error: \(error.localizedDescription)"
                )
                PopupConsole.shared.log(
                    "[Error] Probe failed: \(error.localizedDescription)"
                )
            } else if let dict = value as? [String: Any] {
                print("[Popup] comprehensive probe: \(dict)")
                PopupConsole.shared.log("[Probe] APIs: \(dict)")
            } else {
                print("[Popup] comprehensive probe: unexpected result type")
                PopupConsole.shared.log(
                    "[Warning] Probe returned unexpected result"
                )
            }
        }

        // Patch scripting.executeScript in popup context to avoid hard failures on unsupported targets
        let safeScriptingPatch = """
            (function(){
              try {
                if (typeof chrome !== 'undefined' && chrome.scripting && typeof chrome.scripting.executeScript === 'function') {
                  const originalExec = chrome.scripting.executeScript.bind(chrome.scripting);
                  chrome.scripting.executeScript = async function(opts){
                    try { return await originalExec(opts); }
                    catch (e) { console.warn('shim: executeScript failed', e); return []; }
                  };
                }
                if (typeof chrome !== 'undefined' && (!chrome.tabs || typeof chrome.tabs.executeScript !== 'function') && chrome.scripting && typeof chrome.scripting.executeScript === 'function') {
                  chrome.tabs = chrome.tabs || {};
                  chrome.tabs.executeScript = function(tabIdOrDetails, detailsOrCb, maybeCb){
                    function normalize(a,b,c){ let tabId, details, cb; if (typeof a==='number'){ tabId=a; details=b; cb=c; } else { details=a; cb=b; } return {tabId, details: details||{}, cb: (typeof cb==='function')?cb:null}; }
                    const { tabId, details, cb } = normalize(tabIdOrDetails, detailsOrCb, maybeCb);
                    const target = { tabId: tabId||undefined };
                    const files = details && (details.file ? [details.file] : details.files);
                    const code = details && details.code;
                    const opts = { target };
                    if (Array.isArray(files) && files.length) opts.files = files; else if (typeof code==='string') { opts.func = function(src){ try{(0,eval)(src);}catch(e){}}; opts.args=[code]; } else { const p = Promise.resolve([]); if (cb) { try{cb([]);}catch(_){} } return p; }
                    const p = chrome.scripting.executeScript(opts);
                    if (cb) { p.then(r=>{ try{cb(r);}catch(_){} }).catch(_=>{ try{cb([]);}catch(_){} }); }
                    return p;
                  };
                }
              } catch(_){}
            })();
            """
        webView.evaluateJavaScript(safeScriptingPatch) { _, err in
            if let err = err {
                print(
                    "[Popup] safeScriptingPatch error: \(err.localizedDescription)"
                )
            }
        }

        // Note: Skipping automatic tabs.query test to avoid potential recursion issues
        // Extensions will call tabs.query naturally, and we can debug through console
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        let urlString = webView.url?.absoluteString ?? "(nil)"
        print(
            "[Popup] didFail: \(error.localizedDescription) - URL: \(urlString)"
        )
        PopupConsole.shared.log(
            "[Error] Navigation failed: \(error.localizedDescription)"
        )
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let urlString = webView.url?.absoluteString ?? "(nil)"
        print(
            "[Popup] didFailProvisional: \(error.localizedDescription) - URL: \(urlString)"
        )
        PopupConsole.shared.log(
            "[Error] Provisional navigation failed: \(error.localizedDescription)"
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("[Popup] content process terminated")
        PopupConsole.shared.log("[Critical] WebView process terminated")
    }

    // MARK: - Windows exposure (tabs/windows APIs)
    private var lastFocusedWindowCall: Date = Date.distantPast
    private var lastOpenWindowsCall: Date = Date.distantPast

    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        // Throttle logging to prevent spam
        let now = Date()
        if now.timeIntervalSince(lastFocusedWindowCall) > 10.0 {
            print("[ExtensionManager] 🎯 focusedWindowFor() called")
            lastFocusedWindowCall = now
        }

        guard let bm = browserManagerRef else {
            return nil
        }
        if windowAdapter == nil {
            windowAdapter = ExtensionWindowAdapter(browserManager: bm)
        }
        return windowAdapter
    }

    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        // Phase 13.2: Use cached window list if available and fresh
        let now = Date()
        if let cache = windowListCache,
           now.timeIntervalSince(cache.timestamp) < listCacheTTL {
            return cache.windows
        }
        
        // Throttle logging to prevent spam
        if now.timeIntervalSince(lastOpenWindowsCall) > 10.0 {
            print("[ExtensionManager] 🎯 openWindowsFor() called")
            lastOpenWindowsCall = now
        }

        guard let bm = browserManagerRef else {
            return []
        }
        if windowAdapter == nil {
            windowAdapter = ExtensionWindowAdapter(browserManager: bm)
        }
        
        let windows = windowAdapter != nil ? [windowAdapter!] : []
        
        // Phase 13.2: Cache the result
        if let adapter = windowAdapter {
            windowListCache = (windows: [adapter], timestamp: now)
        }
        
        return windows
    }

    // MARK: - Permission prompting helper (invoked by delegate when needed)
    
    /// Helper to get extension ID from extension context
    @available(macOS 15.4, *)
    private func getExtensionId(from extensionContext: WKWebExtensionContext) -> String? {
        let uniqueId = extensionContext.uniqueIdentifier
        // Find the extension ID by matching uniqueIdentifier
        for (extensionId, context) in extensionContexts {
            if context.uniqueIdentifier == uniqueId {
                return extensionId
            }
        }
        return nil
    }
    
    @available(macOS 15.4, *)
    func presentPermissionPrompt(
        requestedPermissions: Set<WKWebExtension.Permission>,
        optionalPermissions: Set<WKWebExtension.Permission>,
        requestedMatches: Set<WKWebExtension.MatchPattern>,
        optionalMatches: Set<WKWebExtension.MatchPattern>,
        extensionDisplayName: String,
        extensionId: String? = nil, // Phase 12.2: Optional extension ID for icon loading
        onDecision:
            @escaping (
                _ grantedPermissions: Set<WKWebExtension.Permission>,
                _ grantedMatches: Set<WKWebExtension.MatchPattern>
            ) -> Void,
        onCancel: @escaping () -> Void,
        extensionLogo: NSImage? = nil // Phase 12.2: Make optional, will load dynamically if nil
    ) {
        guard let bm = browserManagerRef else {
            onCancel()
            return
        }

        // Convert enums to readable strings for UI
        let reqPerms = requestedPermissions.map { String(describing: $0) }
            .sorted()
        let optPerms = optionalPermissions.map { String(describing: $0) }
            .sorted()
        let reqHosts = requestedMatches.map { String(describing: $0) }.sorted()
        let optHosts = optionalMatches.map { String(describing: $0) }.sorted()

        bm.showDialog {
            StandardDialog(
                header: {
                    EmptyView()
                },
                content: {
                    ExtensionPermissionView(
                        extensionName: extensionDisplayName,
                        extensionId: extensionId, // Phase 12.2: Pass extension ID
                        requestedPermissions: reqPerms,
                        optionalPermissions: optPerms,
                        requestedHostPermissions: reqHosts,
                        optionalHostPermissions: optHosts,
                        onGrant: {
                            let allPerms = requestedPermissions.union(
                                optionalPermissions
                            )
                            let allHosts = requestedMatches.union(
                                optionalMatches
                            )
                            bm.closeDialog()
                            onDecision(allPerms, allHosts)
                        },
                        onDeny: {
                            bm.closeDialog()
                            onCancel()
                        },
                        extensionLogo: extensionLogo // Phase 12.2: Pass optional logo
                    )
                },
                footer: { EmptyView() }
            )
        }
    }

    // Delegate entry point for permission requests from extensions at runtime
    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler:
            @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let displayName =
            extensionContext.webExtension.displayName ?? "Extension"
        presentPermissionPrompt(
            requestedPermissions: permissions,
            optionalPermissions: extensionContext.webExtension
                .optionalPermissions,
            requestedMatches: extensionContext.webExtension
                .requestedPermissionMatchPatterns,
            optionalMatches: extensionContext.webExtension
                .optionalPermissionMatchPatterns,
            extensionDisplayName: displayName,
            extensionId: getExtensionId(from: extensionContext), // Phase 12.2: Get extension ID
            onDecision: { grantedPerms, grantedMatches in
                for p in permissions.union(
                    extensionContext.webExtension.optionalPermissions
                ) {
                    extensionContext.setPermissionStatus(
                        grantedPerms.contains(p)
                            ? .grantedExplicitly : .deniedExplicitly,
                        for: p
                    )
                }
                for m in extensionContext.webExtension
                    .requestedPermissionMatchPatterns.union(
                        extensionContext.webExtension
                            .optionalPermissionMatchPatterns
                    )
                {
                    extensionContext.setPermissionStatus(
                        grantedMatches.contains(m)
                            ? .grantedExplicitly : .deniedExplicitly,
                        for: m
                    )
                }
                completionHandler(grantedPerms, nil)
            },
            onCancel: {
                for p in permissions {
                    extensionContext.setPermissionStatus(
                        .deniedExplicitly,
                        for: p
                    )
                }
                for m in extensionContext.webExtension
                    .requestedPermissionMatchPatterns
                {
                    extensionContext.setPermissionStatus(
                        .deniedExplicitly,
                        for: m
                    )
                }
                completionHandler([], nil)
            },
            extensionLogo: extensionContext.webExtension.icon(
                for: .init(width: 64, height: 64)
            ) // Phase 12.2: Pass nil to allow dynamic loading
        )
    }

    // Note: We can provide implementations for opening new tabs/windows once the
    // exact parameter types are finalized for the targeted SDK. These delegate
    // methods are optional; omitting them avoids type resolution issues across
    // SDK variations while retaining popup and permission handling.

    // MARK: - Opening tabs/windows requested by extensions
    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler:
            @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        print("🆕 [Phase 8.1] openNewTabUsing called!")
        print("   URL: \(configuration.url?.absoluteString ?? "nil")")
        print("   Should be active: \(configuration.shouldBeActive)")
        print("   Should be pinned: \(configuration.shouldBePinned)")
        print("   Index: \(configuration.index)")
        print("   Parent tab: \(configuration.parentTab != nil ? "yes" : "no")")
        print("   Should add to selection: \(configuration.shouldAddToSelection)")
        print("   Should be muted: \(configuration.shouldBeMuted)")
        print("   Should reader mode be active: \(configuration.shouldReaderModeBeActive)")
        
        // Phase 11.1: Log extension properties for debugging
        if #available(macOS 15.4, *) {
            let extensionId = extensionContext.uniqueIdentifier
            if let displayName = getExtensionDisplayName(for: extensionId) {
                print("   [Phase 11.1] Extension: \(displayName)")
            }
            if let version = getExtensionVersion(for: extensionId) {
                print("   [Phase 11.1] Version: \(version)")
            }
        }

        guard let bm = browserManagerRef else {
            print("❌ Browser manager reference is nil")
            completionHandler(
                nil,
                NSError(
                    domain: "ExtensionManager",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Browser manager not available"
                    ]
                )
            )
            return
        }

        // Phase 8.1: Determine target space based on window configuration
        let targetSpace: Space?
        if let window = configuration.window as? ExtensionWindowAdapter {
            // Use the window's current space (for now, use current space as window adapter doesn't expose space)
            targetSpace = bm.tabManager.currentSpace
        } else {
            targetSpace = bm.tabManager.currentSpace
        }

        // Special handling for extension page URLs (options, popup, etc.): use the extension's configuration
        if let url = configuration.url,
            url.scheme?.lowercased() == "safari-web-extension"
                || url.scheme?.lowercased() == "webkit-extension",
            let controller = extensionController,
            let resolvedContext = controller.extensionContext(for: url)
        {
            print(
                "🎛️ [Phase 8.1] Opening extension page in tab with extension configuration: \(url.absoluteString)"
            )
            let newTab = bm.tabManager.createNewTab(
                url: url.absoluteString,
                in: targetSpace
            )
            let cfg =
                resolvedContext.webViewConfiguration
                ?? BrowserConfiguration.shared.webViewConfiguration
            newTab.applyWebViewConfigurationOverride(cfg)
            
            // Phase 8.1: Apply all configuration parameters
            applyTabConfiguration(configuration, to: newTab, in: bm)
            
            let tabAdapter = self.stableAdapter(for: newTab)
            completionHandler(tabAdapter, nil)
            return
        }

        let targetURL = configuration.url
        let newTab: Tab
        
        if let url = targetURL {
            newTab = bm.tabManager.createNewTab(
                url: url.absoluteString,
                in: targetSpace
            )
        } else {
            // No URL specified — create a blank tab
            print("⚠️ [Phase 8.1] No URL specified, creating blank tab")
            newTab = bm.tabManager.createNewTab(in: targetSpace)
        }
        
        // Phase 8.1: Apply all configuration parameters
        applyTabConfiguration(configuration, to: newTab, in: bm)
        
        print("✅ [Phase 8.1] Created new tab: \(newTab.name)")

        // Return the created tab adapter to the extension
        let tabAdapter = self.stableAdapter(for: newTab)
        completionHandler(tabAdapter, nil)
    }
    
    /// Phase 8.1: Apply TabConfiguration parameters to a newly created tab
    @available(macOS 15.4, *)
    private func applyTabConfiguration(
        _ configuration: WKWebExtension.TabConfiguration,
        to tab: Tab,
        in browserManager: BrowserManager
    ) {
        // Phase 8.1: Handle parent tab relationship (Phase 1.1)
        if let parentTab = configuration.parentTab as? ExtensionTabAdapter {
            tab.parentTabId = parentTab.tab.id
            print("   [Phase 8.1] Set parent tab: \(parentTab.tab.id)")
        }
        
        // Phase 8.1: Handle index positioning
        if let spaceId = tab.spaceId, let arr = browserManager.tabManager.tabsBySpace[spaceId] {
            let targetIndex = min(max(configuration.index, 0), arr.count)
            if let currentIndex = arr.firstIndex(where: { $0.id == tab.id }), currentIndex != targetIndex {
                browserManager.tabManager.reorderRegularTabs(tab, in: spaceId, to: targetIndex)
                print("   [Phase 8.1] Positioned tab at index: \(targetIndex)")
            }
        }
        
        // Phase 8.1: Handle pinning
        if configuration.shouldBePinned {
            browserManager.tabManager.pinTab(tab)
            print("   [Phase 8.1] Pinned tab")
        }
        
        // Phase 8.1: Handle muting (Phase 1.3)
        if configuration.shouldBeMuted {
            tab.isAudioMuted = true
            print("   [Phase 8.1] Muted tab")
        }
        
        // Phase 8.1: Handle reader mode (Phase 1.4)
        if configuration.shouldReaderModeBeActive {
            tab.isReaderModeActive = true
            print("   [Phase 8.1] Activated reader mode")
        }
        
        // Phase 8.1: Handle selection (Phase 1.7)
        if configuration.shouldAddToSelection {
            browserManager.tabManager.setTabSelected(tab, selected: true)
            print("   [Phase 8.1] Added tab to selection")
        }
        
        // Phase 8.1: Handle active state (must be last to ensure other properties are set first)
        if configuration.shouldBeActive {
            browserManager.tabManager.setActiveTab(tab)
            print("   [Phase 8.1] Activated tab")
        }
    }

    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler:
            @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        print("🆕 [DELEGATE] openNewWindowUsing called!")
        print("   Tab URLs: \(configuration.tabURLs.map { $0.absoluteString })")

        guard let bm = browserManagerRef else {
            completionHandler(
                nil,
                NSError(
                    domain: "ExtensionManager",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Browser manager not available"
                    ]
                )
            )
            return
        }

        // OAuth flows from extensions should open in tabs to share the same data store
        // Miniwindows use separate data stores which breaks OAuth flows
        if let firstURL = configuration.tabURLs.first,
            isLikelyOAuthURL(firstURL)
        {
            print(
                "🔐 [DELEGATE] Extension OAuth window detected, opening in new tab: \(firstURL.absoluteString)"
            )
            // Create a new tab in the current space with the same profile/data store
            let newTab = bm.tabManager.createNewTab(
                url: firstURL.absoluteString,
                in: bm.tabManager.currentSpace
            )
            bm.tabManager.setActiveTab(newTab)

            // Return a dummy window adapter for OAuth flows
            if windowAdapter == nil {
                windowAdapter = ExtensionWindowAdapter(browserManager: bm)
            }
            completionHandler(windowAdapter, nil)
            return
        }

        // For regular extension windows, create a new space to emulate a separate window in our UI
        let newSpace = bm.tabManager.createSpace(name: "Window")
        if let firstURL = configuration.tabURLs.first {
            _ = bm.tabManager.createNewTab(
                url: firstURL.absoluteString,
                in: newSpace
            )
        } else {
            _ = bm.tabManager.createNewTab(in: newSpace)
        }
        bm.tabManager.setActiveSpace(newSpace)

        // Return the window adapter
        if windowAdapter == nil {
            windowAdapter = ExtensionWindowAdapter(browserManager: bm)
        }
        print("✅ Created new window (space): \(newSpace.name)")
        completionHandler(windowAdapter, nil)
    }

    private func isLikelyOAuthURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""

        // Check for OAuth-related URLs
        let oauthHosts = [
            "accounts.google.com", "login.microsoftonline.com",
            "login.live.com",
            "appleid.apple.com", "github.com", "gitlab.com", "bitbucket.org",
            "auth0.com", "okta.com", "onelogin.com", "pingidentity.com",
            "slack.com", "zoom.us", "login.cloudflareaccess.com",
            "oauth", "auth", "login", "signin",
        ]

        // Check if host contains OAuth-related terms
        if oauthHosts.contains(where: { host.contains($0) }) {
            return true
        }

        // Check for OAuth paths and query parameters
        if path.contains("/oauth") || path.contains("oauth2")
            || path.contains("/authorize") || path.contains("/signin")
            || path.contains("/login") || path.contains("/callback")
        {
            return true
        }

        if query.contains("client_id=") || query.contains("redirect_uri=")
            || query.contains("response_type=") || query.contains("scope=")
        {
            return true
        }

        return false
    }

    // Open the extension's options page (inside a browser tab)
    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        print("🆕 [DELEGATE] openOptionsPageFor called!")
        let displayName =
            extensionContext.webExtension.displayName ?? "Extension"
        print("   Extension: \(displayName)")

        // Resolve the options page URL. Prefer the SDK property when available.
        let sdkURL = extensionContext.optionsPageURL
        let manifestURL = self.computeOptionsPageURL(for: extensionContext)
        let kvcURL =
            (extensionContext as AnyObject).value(forKey: "optionsPageURL")
            as? URL
        let optionsURL: URL?
        if let u = sdkURL {
            optionsURL = u
        } else if let u = manifestURL {
            optionsURL = u
        } else if let u = kvcURL, u.scheme?.lowercased() != "file" {
            optionsURL = u
        } else if let u = kvcURL {
            optionsURL = u
        } else {
            optionsURL = nil
        }

        guard let optionsURL else {
            print("❌ No options page URL found for extension")
            completionHandler(
                NSError(
                    domain: "ExtensionManager",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No options page URL found for extension"
                    ]
                )
            )
            return
        }

        print("✅ Opening options page: \(optionsURL.absoluteString)")

        // Create a dedicated WebView using the extension's webViewConfiguration so
        // the WebExtensions environment (browser/chrome APIs) is available.
        let config =
            extensionContext.webViewConfiguration
            ?? BrowserConfiguration.shared.webViewConfiguration
        // Ensure the controller is attached for safety
        if config.webExtensionController == nil, let c = extensionController {
            config.webExtensionController = c
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        // No navigation delegate needed for options page

        // Provide a lightweight alias to help extensions that only check `chrome`.
        // This only affects the options page web view, not normal websites.
        let aliasJS = """
            if (typeof window.chrome === 'undefined' && typeof window.browser !== 'undefined') {
              try { window.chrome = window.browser; } catch (e) {}
            }
            """
        let aliasScript = WKUserScript(
            source: aliasJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(aliasScript)

        // SECURITY FIX: Load the options page with restricted file access
        if optionsURL.isFileURL {
            // SECURITY FIX: Only allow access to the specific extension directory, not the entire package
            guard
                let extId = extensionContexts.first(where: {
                    $0.value === extensionContext
                })?.key,
                let inst = installedExtensions.first(where: { $0.id == extId })
            else {
                print("❌ Could not resolve extension for secure file access")
                completionHandler(
                    NSError(
                        domain: "ExtensionManager",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not resolve extension for secure file access"
                        ]
                    )
                )
                return
            }

            // SECURITY FIX: Validate that the options URL is within the extension directory
            let extensionRoot = URL(
                fileURLWithPath: inst.packagePath,
                isDirectory: true
            )

            // SECURITY FIX: Normalize paths to prevent path traversal attacks
            let normalizedExtensionRoot = extensionRoot.standardizedFileURL
            let normalizedOptionsURL = optionsURL.standardizedFileURL

            // Check if options URL is within the extension directory (prevent path traversal)
            if !normalizedOptionsURL.path.hasPrefix(
                normalizedExtensionRoot.path
            ) {
                print(
                    "❌ SECURITY: Options URL outside extension directory: \(normalizedOptionsURL.path)"
                )
                print("   Extension root: \(normalizedExtensionRoot.path)")
                completionHandler(
                    NSError(
                        domain: "ExtensionManager",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Options URL outside extension directory"
                        ]
                    )
                )
                return
            }

            // SECURITY FIX: Additional validation - ensure no path traversal attempts
            let relativePath = String(
                normalizedOptionsURL.path.dropFirst(
                    normalizedExtensionRoot.path.count
                )
            )
            if relativePath.contains("..") || relativePath.hasPrefix("/") {
                print(
                    "❌ SECURITY: Path traversal attempt detected: \(relativePath)"
                )
                completionHandler(
                    NSError(
                        domain: "ExtensionManager",
                        code: 5,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Path traversal attempt detected"
                        ]
                    )
                )
                return
            }

            // SECURITY FIX: Only grant access to the extension's specific directory, not parent directories
            print(
                "   🔒 SECURITY: Restricting file access to extension directory only: \(extensionRoot.path)"
            )
            webView.loadFileURL(optionsURL, allowingReadAccessTo: extensionRoot)
        } else {
            // For non-file URLs (http/https), load normally
            webView.load(URLRequest(url: optionsURL))
        }

        // Present in a lightweight NSWindow to avoid coupling to Tab UI.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(displayName) – Options"

        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container

        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(
                equalTo: container.trailingAnchor
            ),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Keep window alive keyed by extension id
        if let extId = extensionContexts.first(where: {
            $0.value === extensionContext
        })?.key {
            optionsWindows[extId] = window
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    // Resolve options page URL from manifest as a fallback for SDKs that don't expose optionsPageURL
    @available(macOS 15.5, *)
    private func computeOptionsPageURL(for context: WKWebExtensionContext)
        -> URL?
    {
        print("🔍 [computeOptionsPageURL] Looking for options page...")
        print("   Extension: \(context.webExtension.displayName ?? "Unknown")")
        print("   Unique ID: \(context.uniqueIdentifier)")

        // Try to map the context back to our InstalledExtension via dictionary identity
        if let extId = extensionContexts.first(where: { $0.value === context })?
            .key,
            let inst = installedExtensions.first(where: { $0.id == extId })
        {
            print("   Found installed extension: \(inst.name)")

            // MV3/MV2: options_ui.page; MV2 legacy: options_page
            var pagePath: String?
            if let options = inst.manifest["options_ui"] as? [String: Any],
                let p = options["page"] as? String, !p.isEmpty
            {
                pagePath = p
                print("   Found options_ui.page: \(p)")
            } else if let p = inst.manifest["options_page"] as? String,
                !p.isEmpty
            {
                pagePath = p
                print("   Found options_page: \(p)")
            } else {
                print(
                    "   No options page declared in manifest, checking common paths..."
                )

                // Fallback: Check for common options page paths
                let commonPaths = [
                    "ui/options/index.html",
                    "options/index.html",
                    "options.html",
                    "settings.html",
                ]

                for path in commonPaths {
                    let fullFilePath = URL(fileURLWithPath: inst.packagePath)
                        .appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: fullFilePath.path)
                    {
                        pagePath = path
                        print("   ✅ Found options page at: \(path)")
                        break
                    }
                }
            }

            if let page = pagePath {
                // Build an extension-scheme URL using the context baseURL
                let extBase = context.baseURL
                let optionsURL = extBase.appendingPathComponent(page)
                print(
                    "✅ Generated options extension URL: \(optionsURL.absoluteString)"
                )
                return optionsURL
            } else {
                print("❌ No options page found in manifest or common paths")
                print("   Manifest keys: \(inst.manifest.keys.sorted())")
            }
        } else {
            print("❌ Could not find installed extension for context")
        }
        return nil
    }
    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<
            WKWebExtension.MatchPattern
        >,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler:
            @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let displayName =
            extensionContext.webExtension.displayName ?? "Extension"
        presentPermissionPrompt(
            requestedPermissions: [],
            optionalPermissions: [],
            requestedMatches: matchPatterns,
            optionalMatches: [],
            extensionDisplayName: displayName,
            extensionId: getExtensionId(from: extensionContext), // Phase 12.2: Get extension ID
            onDecision: { _, grantedMatches in
                for m in matchPatterns {
                    extensionContext.setPermissionStatus(
                        grantedMatches.contains(m)
                            ? .grantedExplicitly : .deniedExplicitly,
                        for: m
                    )
                }
                completionHandler(grantedMatches, nil)
            },
            onCancel: {
                for m in matchPatterns {
                    extensionContext.setPermissionStatus(
                        .deniedExplicitly,
                        for: m
                    )
                }
                completionHandler([], nil)
            },
            extensionLogo: extensionContext.webExtension.icon(
                for: .init(width: 64, height: 64)
            ) // Phase 12.2: Pass nil to allow dynamic loading
        )
    }

    // URL-specific access prompts (used for cross-origin network requests from extension contexts)
    @available(macOS 15.5, *)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        // Temporarily grant all requested URLs to unblock background networking for popular extensions
        // TODO: replace with a user-facing prompt + persistence
        print(
            "[ExtensionManager] Granting URL access to: \(urls.map{ $0.absoluteString })"
        )
        completionHandler(urls, nil)
    }

    // MARK: - URL Conversion Helpers

    /// Convert extension URL (webkit-extension:// or safari-web-extension://) to file URL
    @available(macOS 15.5, *)
    private func convertExtensionURLToFileURL(
        _ urlString: String,
        for context: WKWebExtensionContext
    ) -> URL? {
        print("🔄 [convertExtensionURLToFileURL] Converting: \(urlString)")

        // Extract the path from the extension URL
        guard let url = URL(string: urlString) else {
            print("   ❌ Invalid URL string")
            return nil
        }

        let path = url.path
        print("   📂 Extracted path: \(path)")

        // Find the corresponding installed extension
        if let extId = extensionContexts.first(where: { $0.value === context })?
            .key,
            let inst = installedExtensions.first(where: { $0.id == extId })
        {
            print("   📦 Found extension: \(inst.name)")

            // Build file URL from extension package path
            let extensionURL = URL(fileURLWithPath: inst.packagePath)
            let fileURL = extensionURL.appendingPathComponent(
                path.hasPrefix("/") ? String(path.dropFirst()) : path
            )

            // Verify the file exists
            if FileManager.default.fileExists(atPath: fileURL.path) {
                print("   ✅ File exists at: \(fileURL.path)")
                return fileURL
            } else {
                print("   ❌ File not found at: \(fileURL.path)")
            }
        } else {
            print("   ❌ Could not find installed extension for context")
        }

        return nil
    }

    // MARK: - Extension Resource Testing

    /// List all installed extensions with their UUIDs for easy testing
    func listInstalledExtensionsForTesting() {
        print("=== Installed Extensions ===")

        if installedExtensions.isEmpty {
            print("❌ No extensions installed")
            return
        }

        for (index, ext) in installedExtensions.enumerated() {
            print("\(index + 1). \(ext.name)")
            print("   UUID: \(ext.id)")
            print("   Version: \(ext.version)")
            print("   Manifest Version: \(ext.manifestVersion)")
            print("   Enabled: \(ext.isEnabled)")
            print("")
        }
    }

    // MARK: - Chrome Web Store Integration

    /// Install extension from Chrome Web Store by extension ID
    func installFromWebStore(
        extensionId: String,
        completionHandler:
            @escaping (Result<InstalledExtension, ExtensionError>) -> Void
    ) {
        WebStoreDownloader.downloadExtension(extensionId: extensionId) {
            [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let zipURL):
                // Install the downloaded extension
                self.installExtension(from: zipURL) { installResult in
                    // Clean up temporary file
                    try? FileManager.default.removeItem(at: zipURL)
                    completionHandler(installResult)
                }

            case .failure(let error):
                completionHandler(
                    .failure(.installationFailed(error.localizedDescription))
                )
            }
        }
    }
}

// MARK: - Weak View Reference Helper
final class WeakAnchor {
    weak var view: NSView?
    weak var window: NSWindow?
    init(view: NSView?, window: NSWindow?) {
        self.view = view
        self.window = window
    }
}
