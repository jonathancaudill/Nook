//
//  SpacePager.swift
//  Nook
//
//  Clean NSPageController implementation for space navigation with proper profile switching
//

import SwiftUI
import AppKit

/// A SwiftUI wrapper for NSPageController that provides native trackpad gestures for space navigation
struct SpacePager: View {
    @Binding var selection: Int
    let spaces: [Space]
    let width: CGFloat
    let onSpaceChanged: (Int) -> Void
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void
    let onTransitionStarted: () -> Void
    let onTransitionEnded: () -> Void

    // Environment objects to pass through
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var windowState: BrowserWindowState
    @EnvironmentObject var splitManager: SplitViewManager

    var body: some View {
        SpacePagerRepresentable(
            selection: $selection,
            spaces: spaces,
            width: width,
            onSpaceChanged: onSpaceChanged,
            onDragStarted: onDragStarted,
            onDragEnded: onDragEnded,
            onTransitionStarted: onTransitionStarted,
            onTransitionEnded: onTransitionEnded,
            browserManager: browserManager,
            windowState: windowState,
            splitManager: splitManager
        )
    }
}

/// Coordinator to manage synchronization between NSPageController and SwiftUI
fileprivate class Coordinator: NSObject {
    let parent: SpacePagerRepresentable
    
    fileprivate init(_ parent: SpacePagerRepresentable) {
        self.parent = parent
    }
    
    /// Handle profile transition state changes with simple coordination
    func handleProfileTransitionChange(_ isTransitioning: Bool, controller: SpacePageController) {
        if isTransitioning {
            print("🔄 [Coordinator] Profile transition started - Disabling animations")
            controller.transitionStyle = .stackBook
        } else {
            print("✅ [Coordinator] Profile transition ended - Re-enabling animations")
            // Resume normal animations after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                controller.transitionStyle = .horizontalStrip
            }
        }
    }
}

private struct SpacePagerRepresentable: NSViewControllerRepresentable {
    @Binding var selection: Int
    let spaces: [Space]
    let width: CGFloat
    let onSpaceChanged: (Int) -> Void
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void
    let onTransitionStarted: () -> Void
    let onTransitionEnded: () -> Void

    // Environment objects
    let browserManager: BrowserManager
    let windowState: BrowserWindowState
    let splitManager: SplitViewManager

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSViewController(context: Context) -> SpacePageController {
        let controller = SpacePageController()
        controller.spaces = spaces
        controller.currentSelection = selection
        controller.currentWidth = width
        controller.onSpaceChanged = onSpaceChanged
        controller.onDragStarted = onDragStarted
        controller.onDragEnded = onDragEnded
        controller.onTransitionStarted = onTransitionStarted
        controller.onTransitionEnded = onTransitionEnded
        controller.browserManager = browserManager
        controller.windowState = windowState
        controller.splitManager = splitManager
        return controller
    }

    func updateNSViewController(_ controller: SpacePageController, context: Context) {
        // Simple coordination: defer updates during profile transitions
        if browserManager.isTransitioningProfile {
            print("🔄 [SpacePagerRepresentable] Deferring updateNSViewController during profile transition")
            // Defer the update until after the profile transition completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.updateNSViewController(controller, context: context)
            }
            return
        }
        
        // Update spaces and selection
        controller.spaces = spaces
        controller.browserManager = browserManager
        controller.windowState = windowState
        controller.splitManager = splitManager
        
        // Set coordinator for proper synchronization
        controller.coordinator = context.coordinator
        
        // TOTAL CONTROL: Monitor profile transitions and freeze/unfreeze accordingly
        context.coordinator.handleProfileTransitionChange(browserManager.isTransitioningProfile, controller: controller)
        
        // Ensure selection is within bounds before setting it
        let safeSelection = spaces.isEmpty ? 0 : max(0, min(selection, spaces.count - 1))
        
        // Only update currentSelection if it's different to avoid unnecessary updates
        if controller.currentSelection != safeSelection {
            controller.currentSelection = safeSelection
        }
        
        // NEVER update arrangedObjects during SwiftUI layout - this causes crashes
        // The arrangedObjects will be updated later when the controller is fully ready and not in layout
        
        // Update width of existing hosting controllers
        controller.updateWidth(width)
    }
}

/// Custom NSPageController that handles space navigation with clean profile switching
private class SpacePageController: NSPageController, NSPageControllerDelegate {
    // Coordinator for SwiftUI synchronization
    weak var coordinator: Coordinator?
    
    
    var spaces: [Space] = [] {
        didSet {
            print("🔍 [SpacePageController] spaces didSet: \(oldValue.count) -> \(spaces.count), isControllerReady: \(isControllerReady), isViewLoaded: \(isViewLoaded), isTransitioning: \(isTransitioning)")
            
            // Simple approach: just defer during profile transitions
            if browserManager?.isTransitioningProfile == true {
                print("🔄 [SpacePageController] Deferring spaces update during profile transition")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.spaces = self?.spaces ?? []
                }
                return
            }
            
            // Always defer the update to avoid race conditions during initialization
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Only update arrangedObjects if the controller is ready and not in layout
                if self.isControllerReady && self.isViewLoaded && !self.isTransitioning {
                    self.updatePages()
                    // Only try to set selected index if we have valid spaces
                    if !self.spaces.isEmpty {
                        self.setSelectedIndexSafely()
                    }
                } else {
                    print("🔍 [SpacePageController] Deferring updatePages - not ready yet")
                }
            }
        }
    }
    var currentSelection: Int = 0 {
        didSet {
            print("🔍 [SpacePageController] currentSelection didSet: \(oldValue) -> \(currentSelection)")
            
            // Simple approach: just defer during profile transitions
            if browserManager?.isTransitioningProfile == true {
                print("🔄 [SpacePageController] Deferring currentSelection update during profile transition")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.currentSelection = self?.currentSelection ?? 0
                }
                return
            }
            
            // Only update selectedIndex if the controller is ready and not transitioning
            if isControllerReady && !isTransitioning && isViewLoaded {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Only try to set selected index if we have valid spaces
                    if !self.spaces.isEmpty {
                        self.setSelectedIndexSafely()
                    }
                }
            }
        }
    }
    
    var currentWidth: CGFloat = 400.0
    
    // Environment objects - use weak to avoid retain cycles and prevent crashes
    weak var browserManager: BrowserManager?
    weak var windowState: BrowserWindowState?
    weak var splitManager: SplitViewManager?
    
    // Callbacks - use weak self to avoid retain cycles
    var onSpaceChanged: ((Int) -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onTransitionStarted: (() -> Void)?
    var onTransitionEnded: (() -> Void)?
    
    // Track hosting controllers for width updates
    private var hostingControllers: [String: NSHostingController<SpaceContentView>] = [:]
    
    // Prevent duplicate calls during transitions
    private var isTransitioning = false
    
    // Track if the controller is ready to handle selectedIndex changes
    var isControllerReady = false
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    deinit {
        // Clean up hosting controllers to prevent memory leaks
        hostingControllers.removeAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        transitionStyle = .horizontalStrip
        // Don't call updatePages() here - wait until we have valid spaces
        // updatePages() will be called from updateNSViewController when spaces are available
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        // Mark controller as ready after view appears
        isControllerReady = true
        
        print("🔍 [SpacePageController] viewDidAppear - controller is now ready")
        
        // Now we can safely update pages if we have spaces
        if !spaces.isEmpty {
            // Use a small delay to ensure layout is complete before updating arrangedObjects
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                print("🔍 [SpacePageController] viewDidAppear - updating pages with \(self.spaces.count) spaces")
                self.updatePages()
                self.setSelectedIndexSafely()
            }
        } else {
            print("🔍 [SpacePageController] viewDidAppear - no spaces to update")
        }
    }
    
    /// Call this method when spaces change but the controller might not be ready yet
    func updatePagesIfReady() {
        guard isControllerReady && isViewLoaded && !isTransitioning else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.updatePages()
            self?.setSelectedIndexSafely()
        }
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        
        // Simple approach: disable animations during profile transitions
        if browserManager?.isTransitioningProfile == true {
            print("🔄 [SpacePageController] Disabling animations during profile transition")
            self.transitionStyle = .stackBook
            return
        }
        
        // Normal layout with animations when not transitioning
        self.transitionStyle = .horizontalStrip
        
        // NSPageController is now a completely dumb container
        // NO frame management - parent handles everything
        // Just complete any pending transitions for smooth resizing
        self.completeTransition()
    }
    
    func updatePages() {
        print("🔍 [SpacePageController] updatePages called with \(spaces.count) spaces, current selectedIndex: \(selectedIndex)")
        
        guard !spaces.isEmpty else { 
            print("🔍 [SpacePageController] No spaces, setting up empty state")
            // Clean up hosting controllers when no spaces
            hostingControllers.removeAll()
            
            // Set arrangedObjects to a single dummy object to prevent NSPageController crash
            // We'll handle the empty state in the view controller delegate
            arrangedObjects = ["empty"]
            selectedIndex = 0
            return 
        }
        
        // Create simple identifiers for each space
        let identifiers = spaces.map { $0.id.uuidString }
        
        // CRITICAL: Reset selectedIndex to 0 before setting arrangedObjects to prevent crash
        // NSPageController automatically tries to maintain selectedIndex when arrangedObjects changes
        // If the current selectedIndex is out of bounds for the new array, it crashes
        let currentSelectedIndex = selectedIndex
        if currentSelectedIndex >= identifiers.count {
            print("🔧 [SpacePageController] Resetting selectedIndex from \(currentSelectedIndex) to 0 before updating arrangedObjects")
            selectedIndex = 0
        }
        
        arrangedObjects = identifiers
        
        // Clean up hosting controllers for spaces that no longer exist
        let currentSpaceIds = Set(spaces.map { $0.id.uuidString })
        hostingControllers = hostingControllers.filter { currentSpaceIds.contains($0.key) }
        
        print("📋 [SpacePageController] Updated arrangedObjects with \(arrangedObjects.count) items, selectedIndex is now \(selectedIndex)")
    }
    
    /// Safely set the selected index only when the controller is fully ready
    func setSelectedIndexSafely() {
        guard !spaces.isEmpty,
              !arrangedObjects.isEmpty,
              isViewLoaded,
              isControllerReady,
              !isTransitioning else {
            print("⚠️ [SpacePageController] Cannot set selectedIndex - not ready")
            return
        }
        
        // Calculate safe selection based on both spaces and arrangedObjects bounds
        let spacesSafeSelection = max(0, min(currentSelection, spaces.count - 1))
        let arrangedObjectsSafeSelection = max(0, min(spacesSafeSelection, arrangedObjects.count - 1))
        
        // Update currentSelection if it was out of bounds
        if arrangedObjectsSafeSelection != currentSelection {
            print("🔧 [SpacePageController] Correcting currentSelection from \(currentSelection) to \(arrangedObjectsSafeSelection)")
            currentSelection = arrangedObjectsSafeSelection
        }
        
        // Final safety check - ensure selectedIndex is within arrangedObjects bounds
        if arrangedObjectsSafeSelection < arrangedObjects.count {
            print("✅ [SpacePageController] Setting selectedIndex to \(arrangedObjectsSafeSelection)")
            selectedIndex = arrangedObjectsSafeSelection
        } else {
            print("⚠️ [SpacePageController] Safe selection \(arrangedObjectsSafeSelection) is out of bounds for \(arrangedObjects.count) arranged objects")
        }
    }
    
    func updateWidth(_ newWidth: CGFloat) {
        guard newWidth != currentWidth else { return }
        
        // Simple approach: just defer during profile transitions
        if browserManager?.isTransitioningProfile == true {
            print("🔄 [SpacePageController] Deferring width update during profile transition")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateWidth(newWidth)
            }
            return
        }
        
        // Disable animations during width updates to prevent conflicts
        let originalTransitionStyle = self.transitionStyle
        self.transitionStyle = .stackBook
        
        currentWidth = newWidth
        
        // Only update hosting controllers if we have valid references
        guard browserManager != nil && windowState != nil && splitManager != nil else {
            print("⚠️ [SpacePageController] Skipping width update - weak references are nil")
            return
        }
        
        // Update all existing hosting controllers with the new width
        for (_, hostingController) in hostingControllers {
            hostingController.rootView = SpaceContentView(
                space: hostingController.rootView.space,
                width: newWidth,
                browserManager: browserManager,
                windowState: windowState,
                splitManager: splitManager
            )
        }
        
        // Force refresh of current page - only if we have spaces
        guard !spaces.isEmpty else { return }
        let currentIndex = selectedIndex
        
        // Additional safety check - ensure currentIndex is within bounds
        let safeIndex = max(0, min(currentIndex, spaces.count - 1))
        if safeIndex >= 0 && safeIndex < spaces.count && safeIndex < arrangedObjects.count {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.selectedIndex = safeIndex
                
                // NSPageController is now a completely dumb container
                // NO frame management - parent handles everything
            }
        }
        
        // Restore original transition style after width update
        self.transitionStyle = originalTransitionStyle
    }
    
    // MARK: - NSPageControllerDelegate
    
    func pageController(_ pageController: NSPageController, identifierFor object: Any) -> NSPageController.ObjectIdentifier {
        return object as? String ?? ""
    }
    
    func pageController(_ pageController: NSPageController, viewControllerForIdentifier identifier: NSPageController.ObjectIdentifier) -> NSViewController {
        // Handle empty state
        if identifier == "empty" {
            let emptyController = NSViewController()
            emptyController.view = NSView()
            return emptyController
        }
        
        // Find the space for this identifier
        guard let spaceId = UUID(uuidString: identifier),
              let space = spaces.first(where: { $0.id == spaceId }) else {
            return NSViewController()
        }
        
        // Only create hosting controller if we have valid references
        guard browserManager != nil && windowState != nil && splitManager != nil else {
            print("⚠️ [SpacePageController] Skipping hosting controller creation - weak references are nil")
            let fallbackController = NSViewController()
            fallbackController.view = NSView()
            return fallbackController
        }
        
        // Create hosting controller with current environment objects
        let hostingController = NSHostingController(rootView: SpaceContentView(
            space: space,
            width: currentWidth,
            browserManager: browserManager,
            windowState: windowState,
            splitManager: splitManager
        ))
        
        // Store for width updates
        hostingControllers[identifier] = hostingController
        
        return hostingController
    }
    
    func pageController(_ pageController: NSPageController, didTransitionTo object: Any) {
        guard let identifier = object as? String else {
            return
        }
        
        // Handle empty state - don't do anything
        if identifier == "empty" {
            return
        }
        
        guard let spaceId = UUID(uuidString: identifier),
              let index = spaces.firstIndex(where: { $0.id == spaceId }) else {
            return
        }

        // Update selection and notify - use weak self to avoid retain cycles
        currentSelection = index
        
        // Consolidate async calls to avoid race conditions with profile switching
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Notify about space change
            self.onSpaceChanged?(index)
            
            // Complete transition if we were transitioning
            if self.isTransitioning {
                self.isTransitioning = false
                self.onTransitionEnded?()
                self.onDragEnded?()
            }
        }
    }

    func pageController(_ pageController: NSPageController, willTransitionTo object: Any) {
        guard let identifier = object as? String else {
            return
        }
        
        // Don't start transition for empty state
        if identifier == "empty" {
            return
        }
        
        isTransitioning = true
        
        // Notify about transition start to prevent profile switching conflicts
        DispatchQueue.main.async { [weak self] in
            self?.onTransitionStarted?()
            self?.onDragStarted?()
        }
    }
}

/// Pure SwiftUI content view for each space - no AppKit complexity
private struct SpaceContentView: View {
    let space: Space
    let width: CGFloat
    
    // Environment objects - now weak, so we need to handle nil cases
    let browserManager: BrowserManager?
    let windowState: BrowserWindowState?
    let splitManager: SplitViewManager?
    
    var body: some View {
        // Early return if any required objects are nil
        guard let browserManager = browserManager,
              let windowState = windowState,
              let splitManager = splitManager else {
            return AnyView(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: width)
            )
        }
        
        let isActive = windowState.currentSpaceId == space.id
        
        return AnyView(
            SpaceView(
                space: space,
                isActive: isActive,
                width: width,
                onActivateTab: { browserManager.selectTab($0, in: windowState) },
                onCloseTab: { browserManager.tabManager.removeTab($0.id) },
                onPinTab: { browserManager.tabManager.pinTab($0) },
                onMoveTabUp: { browserManager.tabManager.moveTabUp($0.id) },
                onMoveTabDown: { browserManager.tabManager.moveTabDown($0.id) },
                onMuteTab: { $0.toggleMute() }
            )
            .environmentObject(browserManager)
            .environmentObject(windowState)
            .environmentObject(splitManager)
            .frame(width: width)
        )
    }
}
