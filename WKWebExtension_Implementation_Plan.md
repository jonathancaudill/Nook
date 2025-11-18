# Comprehensive WKWebExtension API Implementation Plan

This document outlines a step-by-step plan to implement every remaining WKWebExtension* API that Nook currently doesn't hook up. The plan is organized by API surface area and includes dependencies, implementation details, and testing considerations.

## Current Status Summary

### ✅ Already Implemented
- **WKWebExtensionWindow**: All methods implemented in `ExtensionWindowAdapter`
- **WKWebExtensionTab**: Basic methods (url, title, isSelected, indexInWindow, isLoadingComplete, isPinned, isMuted, isPlayingAudio, isReaderModeActive, webView, activate, close, window)
- **WKWebExtensionController**: Core lifecycle (load/unload), event notifications (didOpenTab, didCloseTab, didActivateTab, didSelectTabs, didDeselectTabs, didChangeTabProperties, didOpenWindow, didFocusWindow)
- **WKWebExtensionControllerDelegate**: Most delegate methods (focusedWindowFor, openWindowsFor, openNewTabUsing, openNewWindowUsing, openOptionsPageFor, promptForPermissions, promptForPermissionMatchPatterns, promptForPermissionToAccess, presentActionPopup)
- **WKWebExtensionContext**: Basic usage (creation, permission management, performAction)

### ❌ Missing Implementations

---

## Phase 1: WKWebExtensionTab Protocol - Advanced Methods

### 1.1 Parent Tab Management
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`

**Steps**:
1. Add `parentTab` property to `ExtensionTabAdapter` to track parent-child relationships
2. Implement `parentTab(for:)` method returning the parent tab adapter if one exists
3. Implement `setParentTab(_:for:completionHandler:)` to establish/clear parent relationships
4. Update `Tab` model or `TabManager` to track parent tab relationships when tabs are opened from other tabs
5. Wire up parent tracking in `BrowserManager` when creating tabs from links/scripts

**Dependencies**: None
**Estimated effort**: 2-3 hours

### 1.2 Tab Pinning Management
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`, `Nook/Managers/TabManager.swift`

**Steps**:
1. Implement `setPinned(_:for:completionHandler:)` in `ExtensionTabAdapter`
2. Wire to `TabManager.pinTab()` / `TabManager.unpinTab()` methods
3. Ensure pinning state changes trigger `didChangeTabProperties` notifications with `.pinned` flag

**Dependencies**: None
**Estimated effort**: 1 hour

### 1.3 Tab Muting Management
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`, `Nook/Models/Tab/Tab.swift`

**Steps**:
1. Add `isMuted` property to `Tab` model if not already present
2. Implement `setMuted(_:for:completionHandler:)` in `ExtensionTabAdapter`
3. Wire to WebView's audio muting capabilities (if available) or track state internally
4. Update `isMuted(for:)` to return actual state instead of hardcoded `false`
5. Trigger `didChangeTabProperties` with `.muted` flag when muting state changes

**Dependencies**: None
**Estimated effort**: 2 hours

### 1.4 Reader Mode Support
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`, `Nook/Models/Tab/Tab.swift`

**Steps**:
1. Add reader mode state tracking to `Tab` model
2. Implement `isReaderModeAvailable(for:)` - check if WKWebView supports reader mode
3. Implement `setReaderModeActive(_:for:completionHandler:)` - toggle reader mode via WKWebView
4. Update `isReaderModeActive(for:)` to return actual state instead of hardcoded `false`
5. Trigger `didChangeTabProperties` with `.readerMode` flag when reader mode changes

**Dependencies**: None
**Estimated effort**: 2-3 hours

### 1.5 Tab Size and Zoom Management
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`, `Nook/Models/Tab/Tab.swift`

**Steps**:
1. Implement `size(for:)` - return WebView's frame size or content size
2. Implement `zoomFactor(for:)` - return WebView's `pageZoom` property
3. Implement `setZoomFactor(_:for:completionHandler:)` - set WebView's `pageZoom`
4. Track zoom changes and trigger `didChangeTabProperties` with `.zoomFactor` flag
5. Track size changes and trigger `didChangeTabProperties` with `.size` flag

**Dependencies**: None
**Estimated effort**: 2 hours

### 1.6 Tab Navigation Methods
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`

**Steps**:
1. Implement `pendingURL(for:)` - return WebView's `url` during navigation or `nil` if not loading
2. Implement `loadURL(_:for:completionHandler:)` - call `tab.webView?.load(URLRequest(url:))`
3. Implement `reload(fromOrigin:for:completionHandler:)` - call `tab.webView?.reload()` or `reloadFromOrigin()`
4. Implement `goBack(for:completionHandler:)` - call `tab.webView?.goBack()`
5. Implement `goForward(for:completionHandler:)` - call `tab.webView?.goForward()`

**Dependencies**: None
**Estimated effort**: 2 hours

### 1.7 Tab Selection Management
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`, `Nook/Managers/TabManager.swift`

**Steps**:
1. Implement `setSelected(_:for:completionHandler:)` in `ExtensionTabAdapter`
2. Add multi-selection support to `TabManager` if not already present
3. Wire selection changes to `TabManager` selection state
4. Ensure selection changes trigger appropriate `didSelectTabs` / `didDeselectTabs` notifications

**Dependencies**: Multi-selection support in TabManager
**Estimated effort**: 3-4 hours

### 1.8 Tab Duplication
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`, `Nook/Managers/TabManager.swift`

**Steps**:
1. Implement `duplicate(using:for:completionHandler:)` in `ExtensionTabAdapter`
2. Create `TabManager.duplicateTab(_:configuration:)` method
3. Handle `WKWebExtension.TabConfiguration` parameters (parent tab, index, URL, pinned state, etc.)
4. Return new tab adapter in completion handler

**Dependencies**: None
**Estimated effort**: 2-3 hours

### 1.9 Tab Snapshot Capture
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`

**Steps**:
1. Implement `takeSnapshot(using:for:completionHandler:)` in `ExtensionTabAdapter`
2. Use WKWebView's `takeSnapshot(with:completionHandler:)` API
3. Convert `WKSnapshotConfiguration` parameters appropriately
4. Return NSImage in completion handler

**Dependencies**: None
**Estimated effort**: 1-2 hours

### 1.10 Tab Locale Detection
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`

**Steps**:
1. Implement `detectWebpageLocale(for:completionHandler:)` in `ExtensionTabAdapter`
2. Extract locale from WebView's document (via JavaScript evaluation or WKWebView APIs)
3. Return NSLocale or nil if detection fails

**Dependencies**: None
**Estimated effort**: 2 hours

### 1.11 Tab Permission Helpers
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionBridge.swift`

**Steps**:
1. Implement `shouldGrantPermissionsOnUserGesture(for:)` - return true if tab has active user gesture
2. Implement `shouldBypassPermissions(for:)` - return false by default, can be customized per tab
3. Wire these to `WKWebExtensionContext` permission checks

**Dependencies**: User gesture tracking (see Phase 3)
**Estimated effort**: 1 hour

---

## Phase 2: WKWebExtensionControllerDelegate - Missing Methods

### 2.1 Action Update Delegate
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Components/Extensions/ExtensionActionView.swift`

**Steps**:
1. Implement `webExtensionController(_:didUpdate:forExtensionContext:)` delegate method
2. Observe `WKWebExtensionAction` property changes (icon, label, badgeText, enabled state)
3. Update UI in `ExtensionActionView` when action properties change
4. Handle badge text updates and unread badge state
5. Refresh action button appearance when icon/label changes

**Dependencies**: None
**Estimated effort**: 3-4 hours

### 2.2 Native Messaging - Send Message
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, Create new `Nook/Managers/ExtensionManager/NativeMessagingManager.swift`

**Steps**:
1. Create `NativeMessagingManager` to handle app extension communication
2. Implement `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)` delegate method
3. Route messages to appropriate app extension handlers based on `applicationIdentifier`
4. Handle JSON serialization/deserialization for messages
5. Return replies or errors in completion handler
6. Add error handling for invalid messages or missing handlers

**Dependencies**: App extension infrastructure (if needed)
**Estimated effort**: 4-6 hours

### 2.3 Native Messaging - Message Port
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Managers/ExtensionManager/NativeMessagingManager.swift`

**Steps**:
1. Implement `webExtensionController(_:connectUsing:for:completionHandler:)` delegate method
2. Create `MessagePortConnection` class to manage persistent port connections
3. Store active ports in a dictionary keyed by extension context + application identifier
4. Implement message handler forwarding from port to app extension handlers
5. Implement disconnect handler cleanup
6. Handle port lifecycle (retain while connected, release on disconnect)
7. Forward messages bidirectionally between extension and native handlers

**Dependencies**: Native messaging send message implementation (2.2)
**Estimated effort**: 5-7 hours

---

## Phase 3: WKWebExtensionContext - Advanced Features

### 3.1 Background Content Loading
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Call `loadBackgroundContent(completionHandler:)` on extension contexts when needed
2. Monitor background content loading state
3. Handle errors appropriately
4. Ensure background content is loaded before extension can use background APIs

**Dependencies**: None
**Estimated effort**: 1-2 hours

### 3.2 Command Handling
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Managers/ExtensionManager/ExtensionCommandHandler.swift`

**Steps**:
1. Create `ExtensionCommandHandler` to manage extension commands
2. Observe `extensionContext.commands` property for available commands
3. Implement `performCommand(_:)` on contexts when commands are triggered
4. Implement `performCommand(for:)` for NSEvent handling (macOS)
5. Register commands in app's menu system or keyboard shortcut system
6. Handle command activation keys and modifier flags
7. Update command shortcuts when user customizes them

**Dependencies**: Menu/keyboard shortcut infrastructure
**Estimated effort**: 6-8 hours

### 3.3 Context Menu Items
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Components/Sidebar/` (wherever context menus are shown)

**Steps**:
1. Call `menuItems(for:)` on extension contexts for tabs
2. Integrate returned `NSMenuItem` array into tab context menus
3. Handle menu item selection to trigger extension actions
4. Refresh menu items dynamically when context menu is shown
5. Handle menu item updates (enable/disable, title changes)

**Dependencies**: Context menu infrastructure
**Estimated effort**: 4-5 hours

### 3.4 User Gesture Tracking
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Models/Tab/Tab.swift`

**Steps**:
1. Implement `userGesturePerformed(in:)` calls when user interacts with tabs
2. Track active user gestures per tab
3. Implement `hasActiveUserGesture(in:)` checks
4. Implement `clearUserGesture(in:)` to revoke gesture state
5. Call these methods at appropriate times (clicks, keyboard input, etc.)
6. Integrate with `activeTab` permission grants

**Dependencies**: None
**Estimated effort**: 3-4 hours

### 3.5 Permission Status Queries (Per-Tab)
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Use `hasPermission(_:in:)` instead of just `hasPermission(_:)` when tab is known
2. Use `hasAccessToURL(_:in:)` instead of just `hasAccessToURL(_:)` when tab is known
3. Use `permissionStatus(for:in:)` for detailed permission checks per tab
4. Use `permissionStatus(for:in:)` for URL/match pattern checks per tab
5. Update all permission checks throughout codebase to use tab-aware versions

**Dependencies**: None
**Estimated effort**: 2-3 hours

### 3.6 Permission Expiration Dates
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Models/Extension/ExtensionModels.swift`

**Steps**:
1. Use `setPermissionStatus(_:for:expirationDate:)` variants instead of non-expiring versions
2. Store expiration dates in extension data model
3. Implement expiration checking and cleanup
4. Re-prompt for expired permissions when needed
5. Update permission prompt UI to show expiration options

**Dependencies**: None
**Estimated effort**: 3-4 hours

### 3.7 Context-Specific Event Notifications
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Use context-specific `didOpenTab(_:)` instead of controller-level when appropriate
2. Use context-specific `didCloseTab(_:windowIsClosing:)` for per-extension notifications
3. Use context-specific `didActivateTab(_:previousActiveTab:)` for per-extension notifications
4. Use context-specific `didSelectTabs(_:)` and `didDeselectTabs(_:)` methods
5. Use context-specific `didMoveTab(_:fromIndex:inWindow:)` for tab reordering
6. Use context-specific `didReplaceTab(_:with:)` for tab replacement scenarios
7. Use context-specific `didChangeTabProperties(_:for:)` for property updates
8. Use context-specific `didOpenWindow(_:)`, `didCloseWindow(_:)`, `didFocusWindow(_:)` methods

**Dependencies**: None
**Estimated effort**: 2-3 hours

### 3.8 Context Notifications Observation
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Observe `WKWebExtensionContextPermissionsWereGrantedNotification` to update UI
2. Observe `WKWebExtensionContextPermissionsWereDeniedNotification` to update UI
3. Observe `WKWebExtensionContextGrantedPermissionsWereRemovedNotification`
4. Observe `WKWebExtensionContextDeniedPermissionsWereRemovedNotification`
5. Observe `WKWebExtensionContextPermissionMatchPatternsWereGrantedNotification`
6. Observe `WKWebExtensionContextPermissionMatchPatternsWereDeniedNotification`
7. Observe `WKWebExtensionContextGrantedPermissionMatchPatternsWereRemovedNotification`
8. Observe `WKWebExtensionContextDeniedPermissionMatchPatternsWereRemovedNotification`
9. Observe `WKWebExtensionContextErrorsDidUpdateNotification` to show errors to users

**Dependencies**: None
**Estimated effort**: 2-3 hours

### 3.9 Context Error Monitoring
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Components/Extensions/ExtensionErrorView.swift`

**Steps**:
1. Periodically check `extensionContext.errors` property
2. Display extension errors in UI (new component or existing error display)
3. Handle different error types appropriately
4. Allow users to dismiss or act on errors

**Dependencies**: Error UI component
**Estimated effort**: 2-3 hours

### 3.10 Context Unsupported APIs
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Set `extensionContext.unsupportedAPIs` property to disable APIs we don't support
2. Create list of unsupported APIs based on our implementation status
3. Update list as we implement more APIs

**Dependencies**: None
**Estimated effort**: 1 hour

### 3.11 Context Inspection Settings
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Set `extensionContext.inspectable` to enable Web Inspector access
2. Set `extensionContext.inspectionName` for better debugging experience
3. Allow users to toggle inspectability in settings

**Dependencies**: None
**Estimated effort**: 1 hour

---

## Phase 4: WKWebExtensionController - Advanced Features

### 4.1 Tab Movement Notifications
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Managers/TabManager.swift`

**Steps**:
1. Call `controller.didMoveTab(_:fromIndex:inWindow:)` when tabs are reordered
2. Track tab index changes in `TabManager`
3. Determine old window when tabs move between windows
4. Trigger notifications for all loaded extensions

**Dependencies**: Tab reordering infrastructure
**Estimated effort**: 2-3 hours

### 4.2 Tab Replacement Notifications
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Managers/TabManager.swift`

**Steps**:
1. Call `controller.didReplaceTab(_:with:)` when tabs are replaced
2. Identify tab replacement scenarios (navigation replacement, etc.)
3. Trigger notifications for all loaded extensions

**Dependencies**: Tab replacement detection
**Estimated effort**: 2 hours

### 4.3 Data Record Management
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Components/Extensions/ExtensionDataManagementView.swift`

**Steps**:
1. Use `controller.fetchDataRecords(ofTypes:completionHandler:)` to list extension data
2. Use `controller.fetchDataRecord(ofTypes:for:completionHandler:)` for specific extensions
3. Use `controller.removeData(ofTypes:from:completionHandler:)` to clear extension data
4. Create UI for users to view and manage extension data
5. Show data sizes and types per extension
6. Allow bulk deletion of extension data

**Dependencies**: UI component for data management
**Estimated effort**: 4-5 hours

### 4.4 Extension Context Lookup
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Use `controller.extensionContext(for:)` to lookup contexts by extension
2. Use `controller.extensionContext(for:)` to lookup contexts by URL
3. Use these lookups when navigating to extension URLs
4. Ensure proper web view configuration is used for extension pages

**Dependencies**: None
**Estimated effort**: 1-2 hours

---

## Phase 5: WKWebExtensionAction - Full Support

### 5.1 Action Property Observation
**Files to modify**: `Nook/Components/Extensions/ExtensionActionView.swift`, `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Observe `WKWebExtensionAction` properties (icon, label, badgeText, enabled, menuItems)
2. Update action button UI when properties change
3. Handle badge text display and unread badge state
4. Display action menu items in context menu or dropdown

**Dependencies**: Action update delegate (Phase 2.1)
**Estimated effort**: 2-3 hours

### 5.2 Action Menu Items
**Files to modify**: `Nook/Components/Extensions/ExtensionActionView.swift`

**Steps**:
1. Access `action.menuItems` property
2. Display menu items in action button's context menu
3. Handle menu item selection
4. Update menu items dynamically

**Dependencies**: Context menu infrastructure
**Estimated effort**: 2 hours

### 5.3 Action Popup Lifecycle
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Call `action.closePopup()` when popup should be dismissed
2. Handle popup dismissal cleanup
3. Ensure popup WebView is properly unloaded

**Dependencies**: None
**Estimated effort**: 1 hour

---

## Phase 6: WKWebExtensionCommand - Full Support

### 6.1 Command Registration
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionCommandHandler.swift`, `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Observe `extensionContext.commands` array
2. Register each command's keyboard shortcut
3. Create menu items for commands
4. Handle command activation key and modifier flag customization
5. Persist user customizations

**Dependencies**: Menu/keyboard shortcut infrastructure
**Estimated effort**: 4-5 hours

### 6.2 Command Execution
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionCommandHandler.swift`

**Steps**:
1. Implement command execution via `extensionContext.performCommand(_:)`
2. Handle command events from keyboard shortcuts
3. Handle command events from menu items
4. Ensure commands execute in correct context (focused window, active tab)

**Dependencies**: Command registration (6.1)
**Estimated effort**: 2-3 hours

### 6.3 Command Menu Integration
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionCommandHandler.swift`, Menu system files

**Steps**:
1. Add extension commands to app's menu system
2. Use `command.menuItem` property for menu representation
3. Update menu items when commands change
4. Handle menu item selection

**Dependencies**: Menu system infrastructure
**Estimated effort**: 3-4 hours

---

## Phase 7: WKWebExtensionMessagePort - Full Support

### 7.1 Message Port Connection Management
**Files to modify**: `Nook/Managers/ExtensionManager/NativeMessagingManager.swift`

**Steps**:
1. Create `MessagePortConnection` class to wrap `WKWebExtensionMessagePort`
2. Store active connections in a dictionary
3. Handle connection lifecycle (connect, disconnect, error)
4. Implement message handler forwarding
5. Implement disconnect handler cleanup

**Dependencies**: Native messaging delegate (Phase 2.3)
**Estimated effort**: 3-4 hours

### 7.2 Message Port Message Handling
**Files to modify**: `Nook/Managers/ExtensionManager/NativeMessagingManager.swift`

**Steps**:
1. Implement `port.sendMessage(_:completionHandler:)` forwarding to native handlers
2. Handle incoming messages from native handlers and forward to port
3. Implement bidirectional message flow
4. Handle JSON serialization/deserialization
5. Handle errors appropriately

**Dependencies**: Message port connection management (7.1)
**Estimated effort**: 3-4 hours

### 7.3 Message Port Disconnection Handling
**Files to modify**: `Nook/Managers/ExtensionManager/NativeMessagingManager.swift`

**Steps**:
1. Implement `port.disconnect()` and `port.disconnect(throwing:)` handling
2. Clean up connection resources
3. Notify native handlers of disconnection
4. Handle disconnection errors

**Dependencies**: Message port connection management (7.1)
**Estimated effort**: 2 hours

---

## Phase 8: WKWebExtensionTabConfiguration - Full Support

### 8.1 Tab Configuration Parameter Handling
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Handle `TabConfiguration.window` parameter in `openNewTabUsing`
2. Handle `TabConfiguration.index` parameter for tab positioning
3. Handle `TabConfiguration.parentTab` parameter for parent relationships
4. Handle `TabConfiguration.shouldAddToSelection` parameter
5. Handle `TabConfiguration.shouldBeMuted` parameter
6. Handle `TabConfiguration.shouldReaderModeBeActive` parameter
7. Ensure all configuration parameters are respected

**Dependencies**: Parent tab support (Phase 1.1), selection support (Phase 1.7), muting (Phase 1.3), reader mode (Phase 1.4)
**Estimated effort**: 3-4 hours

---

## Phase 9: WKWebExtensionWindowConfiguration - Full Support

### 9.1 Window Configuration Parameter Handling
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Handle `WindowConfiguration.windowType` parameter
2. Handle `WindowConfiguration.windowState` parameter (minimized, maximized, fullscreen)
3. Handle `WindowConfiguration.frame` parameter for window positioning
4. Handle `WindowConfiguration.tabs` parameter for moving existing tabs
5. Handle `WindowConfiguration.shouldBeFocused` parameter
6. Handle `WindowConfiguration.shouldBePrivate` parameter (requires separate data store)

**Dependencies**: Window state management, private browsing support
**Estimated effort**: 4-5 hours

---

## Phase 10: WKWebExtensionDataRecord - Full Support

### 10.1 Data Record Queries
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Components/Extensions/ExtensionDataManagementView.swift`

**Steps**:
1. Use `dataRecord.containedDataTypes` to show what data types exist
2. Use `dataRecord.totalSizeInBytes` to show total storage
3. Use `dataRecord.sizeInBytes(ofTypes:)` to show per-type storage
4. Display `dataRecord.errors` if any occurred
5. Show `dataRecord.displayName` and `uniqueIdentifier` in UI

**Dependencies**: Data record management UI (Phase 4.3)
**Estimated effort**: 2 hours

---

## Phase 11: WKWebExtensionMatchPattern - Full Support

### 11.1 Match Pattern Utilities
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, `Nook/Utils/ExtensionUtils.swift`

**Steps**:
1. Use `WKWebExtensionMatchPattern.allURLsMatchPattern` for `<all_urls>` checks
2. Use `WKWebExtensionMatchPattern.allHostsAndSchemesMatchPattern` for wildcard checks
3. Use `WKWebExtensionMatchPattern.matchPatternWithString(_:)` for parsing
4. Use `WKWebExtensionMatchPattern.matchPatternWithScheme(_:host:path:)` for construction
5. Use `pattern.matches(_:)` and `pattern.matches(_:options:)` for URL matching
6. Use `pattern.matchesPattern(_:)` and `pattern.matchesPattern(_:options:)` for pattern matching
7. Handle match pattern errors appropriately

**Dependencies**: None
**Estimated effort**: 2-3 hours

### 11.2 Custom URL Scheme Registration
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`

**Steps**:
1. Call `WKWebExtensionMatchPattern.registerCustomURLScheme(_:)` for any custom schemes
2. Register schemes used by extensions if needed
3. Ensure schemes are registered before extensions are loaded

**Dependencies**: None
**Estimated effort**: 1 hour

---

## Phase 12: WKWebExtension - Advanced Properties

### 12.1 Extension Property Usage
**Files to modify**: `Nook/Managers/ExtensionManager/ExtensionManager.swift`, Various UI components

**Steps**:
1. Use `webExtension.hasBackgroundContent` to determine if background loading is needed
2. Use `webExtension.hasPersistentBackgroundContent` for macOS-specific checks
3. Use `webExtension.hasInjectedContent` to show content script status
4. Use `webExtension.hasOptionsPage` to show options button
5. Use `webExtension.hasOverrideNewTabPage` to offer new tab page override
6. Use `webExtension.hasCommands` to show commands menu
7. Use `webExtension.hasContentModificationRules` to show declarative net request status
8. Use `webExtension.allRequestedMatchPatterns` for comprehensive pattern checks
9. Use `webExtension.supportsManifestVersion(_:)` for version checks

**Dependencies**: None
**Estimated effort**: 2-3 hours

### 12.2 Extension Icon and Action Icon
**Files to modify**: `Nook/Components/Extensions/ExtensionActionView.swift`, `Nook/Components/Extensions/ExtensionPermissionView.swift`

**Steps**:
1. Use `webExtension.icon(for:)` for extension icons in UI
2. Use `webExtension.actionIconForSize(_:)` for action button icons
3. Handle icon loading failures gracefully
4. Cache icons appropriately

**Dependencies**: None
**Estimated effort**: 1-2 hours

---

## Phase 13: Integration and Polish

### 13.1 Error Handling
**Files to modify**: All extension-related files

**Steps**:
1. Handle all `WKWebExtension*Error` error types appropriately
2. Display user-friendly error messages
3. Log errors for debugging
4. Handle error recovery where possible

**Dependencies**: All previous phases
**Estimated effort**: 3-4 hours

### 13.2 Performance Optimization
**Files to modify**: All extension-related files

**Steps**:
1. Optimize adapter creation and caching
2. Minimize unnecessary delegate calls
3. Batch permission updates where possible
4. Optimize tab/window queries
5. Cache frequently accessed properties

**Dependencies**: All previous phases
**Estimated effort**: 4-5 hours

### 13.3 Testing
**Files to create**: Test files for each major feature

**Steps**:
1. Create unit tests for each implemented API
2. Create integration tests for extension loading/unloading
3. Test permission flows
4. Test native messaging
5. Test command execution
6. Test tab/window operations
7. Test error scenarios

**Dependencies**: All previous phases
**Estimated effort**: 8-10 hours

### 13.4 Documentation
**Files to create**: `Nook/Documentation/ExtensionAPISupport.md`

**Steps**:
1. Document which APIs are supported
2. Document which APIs are partially supported
3. Document known limitations
4. Document extension developer guidelines
5. Create migration guide for extensions

**Dependencies**: All previous phases
**Estimated effort**: 3-4 hours

---

## Implementation Priority

### High Priority (Core Functionality)
1. Phase 2.1 - Action Update Delegate (needed for dynamic action updates)
2. Phase 1.3 - Tab Muting (common extension feature)
3. Phase 1.7 - Tab Selection Management (multi-select support)
4. Phase 3.4 - User Gesture Tracking (needed for activeTab permissions)
5. Phase 3.5 - Permission Status Queries Per-Tab (more accurate permissions)

### Medium Priority (Enhanced Functionality)
1. Phase 1.1 - Parent Tab Management
2. Phase 1.2 - Tab Pinning Management
3. Phase 1.4 - Reader Mode Support
4. Phase 1.5 - Tab Size and Zoom Management
5. Phase 1.6 - Tab Navigation Methods
6. Phase 2.2 - Native Messaging Send Message
7. Phase 3.1 - Background Content Loading
8. Phase 3.2 - Command Handling
9. Phase 3.3 - Context Menu Items

### Lower Priority (Nice to Have)
1. Phase 1.8 - Tab Duplication
2. Phase 1.9 - Tab Snapshot Capture
3. Phase 1.10 - Tab Locale Detection
4. Phase 1.11 - Tab Permission Helpers
5. Phase 2.3 - Native Messaging Message Port
6. Phase 3.6 - Permission Expiration Dates
7. Phase 4.3 - Data Record Management
8. Phase 5.x - Action Advanced Features
9. Phase 6.x - Command Full Support
10. Phase 7.x - Message Port Full Support

---

## Estimated Total Effort

- **High Priority**: ~20-25 hours
- **Medium Priority**: ~35-45 hours  
- **Lower Priority**: ~40-50 hours
- **Integration/Polish**: ~15-20 hours

**Total**: ~110-140 hours of development time

---

## Notes

- Many implementations can be done in parallel by different developers
- Some features depend on infrastructure that may need to be built first (e.g., multi-selection, private browsing)
- Testing should be done incrementally as each phase is completed
- Consider creating feature flags for new functionality to allow gradual rollout
- Some APIs may have platform-specific considerations (iOS vs macOS)

