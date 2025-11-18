//
//  ExtensionBridge.swift
//  Nook
//
//  Lightweight adapters exposing tabs/windows to WKWebExtension.
//

import AppKit
import Foundation
import WebKit

@available(macOS 15.4, *)
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private unowned let browserManager: BrowserManager
    private var isProcessingTabsRequest = false

    init(browserManager: BrowserManager) {
        self.browserManager = browserManager
        super.init()
    }
    
    // MARK: - Window Identity
    
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ExtensionWindowAdapter else { return false }
        return other.browserManager === self.browserManager
    }
    
    override var hash: Int {
        return ObjectIdentifier(browserManager).hashValue
    }

    private var lastActiveTabCall: Date = Date.distantPast
    
    func activeTab(for extensionContext: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        let now = Date()
        if now.timeIntervalSince(lastActiveTabCall) > 2.0 {
            print("[ExtensionWindowAdapter] activeTab() called")
            lastActiveTabCall = now
        }
        
        if let t = browserManager.currentTabForActiveWindow(),
           let a = ExtensionManager.shared.stableAdapter(for: t) {
            return a
        }
        
        if let first = browserManager.tabManager.pinnedTabs.first ?? browserManager.tabManager.tabs.first,
           let a = ExtensionManager.shared.stableAdapter(for: first) {
            return a
        }
        
        return nil
    }

    private var lastTabsCall: Date = Date.distantPast
    
    func tabs(for extensionContext: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastTabsCall) > 2.0
        if shouldLog {
            let currentTabName = browserManager.currentTabForActiveWindow()?.name ?? "nil"
            print("[ExtensionWindowAdapter] tabs() called - Current tab: '\(currentTabName)'")
            lastTabsCall = now
        }
        
        let all = browserManager.tabManager.pinnedTabs + browserManager.tabManager.tabs
        let adapters = all.compactMap { ExtensionManager.shared.stableAdapter(for: $0) }
        
        return adapters
    }

    func frame(for extensionContext: WKWebExtensionContext) -> CGRect {
        if let window = NSApp.mainWindow {
            return window.frame
        }
        return .zero
    }

    func screenFrame(for extensionContext: WKWebExtensionContext) -> CGRect {
        return NSScreen.main?.frame ?? .zero
    }

    func focus(for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let window = NSApp.mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            completionHandler(nil)
        } else {
            completionHandler(NSError(domain: "ExtensionWindowAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No window to focus"]))
        }
    }

    func isPrivate(for extensionContext: WKWebExtensionContext) -> Bool {
        return false
    }

    func windowType(for extensionContext: WKWebExtensionContext) -> WKWebExtension.WindowType {
        return .normal
    }

    func windowState(for extensionContext: WKWebExtensionContext) -> WKWebExtension.WindowState {
        return .normal
    }

    func setWindowState(_ windowState: WKWebExtension.WindowState, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    func setFrame(_ frame: CGRect, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let window = NSApp.mainWindow {
            window.setFrame(frame, display: true)
            completionHandler(nil)
        } else {
            completionHandler(NSError(domain: "ExtensionWindowAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "No window to set frame on"]))
        }
    }

    func close(for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let window = NSApp.mainWindow {
            window.performClose(nil)
            completionHandler(nil)
        } else {
            completionHandler(NSError(domain: "ExtensionWindowAdapter", code: 3, userInfo: [NSLocalizedDescriptionKey: "No window to close"]))
        }
    }
}

@available(macOS 15.4, *)
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    internal let tab: Tab
    private unowned let browserManager: BrowserManager

    init(tab: Tab, browserManager: BrowserManager) {
        self.tab = tab
        self.browserManager = browserManager
        super.init()
    }

    private var lastMethodCall: Date = Date.distantPast
    
    func url(for extensionContext: WKWebExtensionContext) -> URL? {
        let now = Date()
        if now.timeIntervalSince(lastMethodCall) > 5.0 {
            print("[ExtensionTabAdapter] Methods called for tab: '\(tab.name)'")
            lastMethodCall = now
        }
        return tab.url
    }

    func title(for extensionContext: WKWebExtensionContext) -> String? {
        return tab.name
    }

    func isSelected(for extensionContext: WKWebExtensionContext) -> Bool {
        // Check multi-selection first, then fall back to active tab check
        if browserManager.tabManager.isTabSelected(tab) {
            return true
        }
        let isActive = browserManager.currentTabForActiveWindow()?.id == tab.id
        return isActive
    }

    func indexInWindow(for extensionContext: WKWebExtensionContext) -> Int {
        if browserManager.tabManager.pinnedTabs.contains(where: { $0.id == tab.id }) {
            return 0
        }
        return tab.index
    }

    func isLoadingComplete(for extensionContext: WKWebExtensionContext) -> Bool {
        return !tab.isLoading
    }

    func isPinned(for extensionContext: WKWebExtensionContext) -> Bool {
        return browserManager.tabManager.pinnedTabs.contains(where: { $0.id == tab.id })
    }

    func isMuted(for extensionContext: WKWebExtensionContext) -> Bool {
        return tab.isAudioMuted
    }

    func isPlayingAudio(for extensionContext: WKWebExtensionContext) -> Bool {
        return false
    }

    func isReaderModeActive(for extensionContext: WKWebExtensionContext) -> Bool {
        return tab.isReaderModeActive
    }
    
    func isReaderModeAvailable(for extensionContext: WKWebExtensionContext) -> Bool {
        // Check if WKWebView supports reader mode by checking if the page has reader-available content
        guard let webView = tab.webView else {
            return false
        }
        
        // WKWebView doesn't expose reader mode availability directly
        // We can check via JavaScript if the page has reader-available content
        // For now, return false as reader mode isn't fully supported in WKWebView
        // This can be enhanced later with JavaScript-based detection
        return false
    }

    func webView(for extensionContext: WKWebExtensionContext) -> WKWebView? {
        return tab.webView
    }

    func activate(for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        browserManager.tabManager.setActiveTab(tab)
        completionHandler(nil)
    }

    func close(for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        browserManager.tabManager.removeTab(tab.id)
        completionHandler(nil)
    }
    
    // MARK: - Critical Missing Method
    
    func window(for extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        let manager = ExtensionManager.shared
        if manager.windowAdapter == nil {
            manager.windowAdapter = ExtensionWindowAdapter(browserManager: browserManager)
        }
        return manager.windowAdapter
    }
    
    // MARK: - Parent Tab Management (Phase 1.1)
    
    func parentTab(for extensionContext: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let parentTabId = tab.parentTabId else {
            return nil
        }
        
        // Find parent tab in TabManager
        let allTabs = browserManager.tabManager.pinnedTabs + browserManager.tabManager.tabs
        if let parentTab = allTabs.first(where: { $0.id == parentTabId }) {
            return ExtensionManager.shared.stableAdapter(for: parentTab)
        }
        
        return nil
    }
    
    func setParentTab(_ parentTab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let parentTab = parentTab as? ExtensionTabAdapter {
            tab.parentTabId = parentTab.tab.id
        } else {
            tab.parentTabId = nil
        }
        completionHandler(nil)
    }
    
    // MARK: - Tab Pinning Management (Phase 1.2)
    
    func setPinned(_ pinned: Bool, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if pinned {
            browserManager.tabManager.pinTab(tab)
        } else {
            browserManager.tabManager.unpinTab(tab)
        }
        
        // Trigger property change notification
        ExtensionManager.shared.notifyTabPropertiesChanged(
            tab,
            properties: .pinned
        )
        
        completionHandler(nil)
    }
    
    // MARK: - Tab Muting Management (Phase 1.3)
    
    func setMuted(_ muted: Bool, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab.isAudioMuted = muted
        
        // If WebView is available, try to mute/unmute it
        if let webView = tab.webView {
            // Note: WKWebView doesn't have a direct muting API, so we track state internally
            // The actual muting would need to be handled via JavaScript or other means
        }
        
        // Trigger property change notification
        ExtensionManager.shared.notifyTabPropertiesChanged(
            tab,
            properties: .muted
        )
        
        completionHandler(nil)
    }
    
    // MARK: - Reader Mode Support (Phase 1.4)
    
    func setReaderModeActive(_ active: Bool, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab.isReaderModeActive = active
        
        // Note: WKWebView doesn't have a built-in reader mode API on macOS
        // This would need to be implemented via JavaScript or a custom reader view
        // For now, we just track the state
        
        // Trigger property change notification
        ExtensionManager.shared.notifyTabPropertiesChanged(
            tab,
            properties: .readerMode
        )
        
        completionHandler(nil)
    }
    
    // MARK: - Tab Size and Zoom Management (Phase 1.5)
    
    func size(for extensionContext: WKWebExtensionContext) -> CGSize {
        if let webView = tab.webView {
            return webView.frame.size
        }
        return .zero
    }
    
    func zoomFactor(for extensionContext: WKWebExtensionContext) -> Double {
        if let webView = tab.webView {
            return Double(webView.pageZoom)
        }
        return 1.0
    }
    
    func setZoomFactor(_ zoomFactor: Double, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = tab.webView else {
            completionHandler(NSError(domain: "ExtensionTabAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
            return
        }
        
        webView.pageZoom = CGFloat(zoomFactor)
        
        // Trigger property change notification
        ExtensionManager.shared.notifyTabPropertiesChanged(
            tab,
            properties: .zoomFactor
        )
        
        completionHandler(nil)
    }
    
    // MARK: - Tab Navigation Methods (Phase 1.6)
    
    func pendingURL(for extensionContext: WKWebExtensionContext) -> URL? {
        // Return the URL during navigation, or nil if not loading
        guard let webView = tab.webView else {
            return nil
        }
        
        // If the tab is loading, return the current URL (which may be the pending URL)
        if tab.isLoading {
            return webView.url
        }
        
        return nil
    }
    
    func loadURL(_ url: URL, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = tab.webView else {
            completionHandler(NSError(domain: "ExtensionTabAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
            return
        }
        
        let request = URLRequest(url: url)
        webView.load(request)
        completionHandler(nil)
    }
    
    func reload(fromOrigin: Bool, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = tab.webView else {
            completionHandler(NSError(domain: "ExtensionTabAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
            return
        }
        
        if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
        completionHandler(nil)
    }
    
    func goBack(for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = tab.webView else {
            completionHandler(NSError(domain: "ExtensionTabAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
            return
        }
        
        guard webView.canGoBack else {
            completionHandler(NSError(domain: "ExtensionTabAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot go back"]))
            return
        }
        
        webView.goBack()
        completionHandler(nil)
    }
    
    func goForward(for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = tab.webView else {
            completionHandler(NSError(domain: "ExtensionTabAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
            return
        }
        
        guard webView.canGoForward else {
            completionHandler(NSError(domain: "ExtensionTabAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot go forward"]))
            return
        }
        
        webView.goForward()
        completionHandler(nil)
    }
    
    // MARK: - Tab Selection Management (Phase 1.7)
    
    func setSelected(_ selected: Bool, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        browserManager.tabManager.setTabSelected(tab, selected: selected)
        
        // Selection changes are tracked via TabManager.selectedTabs
        // Extensions can query isSelected to check current state
        
        completionHandler(nil)
    }
    
    // MARK: - Tab Duplication (Phase 1.8)
    
    func duplicate(using configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        let duplicatedTab = browserManager.tabManager.duplicateTab(tab, configuration: configuration)
        let adapter = ExtensionManager.shared.stableAdapter(for: duplicatedTab)
        completionHandler(adapter, nil)
    }
    
    // MARK: - Tab Snapshot Capture (Phase 1.9)
    
    func takeSnapshot(using configuration: WKSnapshotConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (NSImage?, Error?) -> Void) {
        guard let webView = tab.webView else {
            completionHandler(nil, NSError(domain: "ExtensionTabAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
            return
        }
        
        webView.takeSnapshot(with: configuration) { image, error in
            if let error = error {
                completionHandler(nil, error)
            } else if let image = image {
                completionHandler(image, nil)
            } else {
                completionHandler(nil, NSError(domain: "ExtensionTabAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Snapshot capture returned nil"]))
            }
        }
    }
    
    // MARK: - Tab Locale Detection (Phase 1.10)
    
    func detectWebpageLocale(for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Locale?, Error?) -> Void) {
        guard let webView = tab.webView else {
            completionHandler(nil, NSError(domain: "ExtensionTabAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
            return
        }
        
        // Use JavaScript to detect the page's locale
        let script = """
            (function() {
                // Try multiple methods to detect locale
                var locale = null;
                
                // Method 1: Check document.documentElement.lang
                if (document.documentElement && document.documentElement.lang) {
                    locale = document.documentElement.lang;
                }
                // Method 2: Check html lang attribute
                else if (document.documentElement && document.documentElement.getAttribute('lang')) {
                    locale = document.documentElement.getAttribute('lang');
                }
                // Method 3: Check navigator.language
                else if (navigator.language) {
                    locale = navigator.language;
                }
                // Method 4: Check navigator.languages[0]
                else if (navigator.languages && navigator.languages.length > 0) {
                    locale = navigator.languages[0];
                }
                
                return locale;
            })();
        """
        
        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                completionHandler(nil, error)
                return
            }
            
            if let localeString = result as? String, !localeString.isEmpty {
                let locale = Locale(identifier: localeString)
                completionHandler(locale, nil)
            } else {
                // Fallback to nil if no locale detected
                completionHandler(nil, nil)
            }
        }
    }
    
    // MARK: - Tab Permission Helpers (Phase 1.11)
    
    func shouldGrantPermissionsOnUserGesture(for extensionContext: WKWebExtensionContext) -> Bool {
        // Grant permissions on user gesture if the tab is currently active/selected
        // This allows extensions to request permissions when the user interacts with the tab
        return isSelected(for: extensionContext)
    }
    
    func shouldBypassPermissions(for extensionContext: WKWebExtensionContext) -> Bool {
        // By default, don't bypass permissions - enforce standard host permission checks
        // This can be customized based on tab state, URL, or other criteria
        // For example, you might bypass for internal pages or trusted domains
        let url = tab.url
        
        // Bypass for internal/extension pages
        if url.scheme == "nook" || url.scheme == "chrome-extension" {
            return true
        }
        
        // Bypass for localhost/127.0.0.1
        if let host = url.host, (host == "localhost" || host == "127.0.0.1" || host == "::1") {
            return true
        }
        
        return false
    }
}
