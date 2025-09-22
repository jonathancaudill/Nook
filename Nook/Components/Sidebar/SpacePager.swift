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
        // Update spaces and selection
        controller.spaces = spaces
        controller.browserManager = browserManager
        controller.windowState = windowState
        controller.splitManager = splitManager
        
        // Ensure selection is within bounds before setting it
        let safeSelection = spaces.isEmpty ? 0 : max(0, min(selection, spaces.count - 1))
        controller.currentSelection = safeSelection
        
        // NEVER update arrangedObjects during SwiftUI layout - this causes crashes
        // The arrangedObjects will be updated later when the controller is fully ready and not in layout
        
        // Update width of existing hosting controllers
        controller.updateWidth(width)
    }
}

/// Custom NSPageController that handles space navigation with clean profile switching
private class SpacePageController: NSPageController, NSPageControllerDelegate {
    var spaces: [Space] = [] {
        didSet {
            // Only update arrangedObjects if the controller is ready and not in layout
            if isControllerReady && isViewLoaded && !isTransitioning {
                DispatchQueue.main.async { [weak self] in
                    self?.updatePages()
                    self?.setSelectedIndexSafely()
                }
            }
        }
    }
    var currentSelection: Int = 0 {
        didSet {
            // Only update selectedIndex if the controller is ready and not transitioning
            if isControllerReady && !isTransitioning && isViewLoaded {
                DispatchQueue.main.async { [weak self] in
                    self?.setSelectedIndexSafely()
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
        
        // Now we can safely update pages if we have spaces
        if !spaces.isEmpty {
            // Use a small delay to ensure layout is complete before updating arrangedObjects
            DispatchQueue.main.async { [weak self] in
                self?.updatePages()
                self?.setSelectedIndexSafely()
            }
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
        
        // Ensure current page stays positioned at the left edge during resize
        let currentSize = self.view.bounds.size
        if let currentPageView = self.selectedViewController?.view {
            currentPageView.frame = CGRect(x: 0, y: 0, width: currentSize.width, height: currentSize.height)
        }
        
        // Complete any pending transitions for smooth resizing
        self.completeTransition()
    }
    
    func updatePages() {
        guard !spaces.isEmpty else { 
            // Clean up hosting controllers when no spaces
            hostingControllers.removeAll()
            arrangedObjects = []
            return 
        }
        
        // Create simple identifiers for each space
        let identifiers = spaces.map { $0.id.uuidString }
        arrangedObjects = identifiers
        
        // Clean up hosting controllers for spaces that no longer exist
        let currentSpaceIds = Set(spaces.map { $0.id.uuidString })
        hostingControllers = hostingControllers.filter { currentSpaceIds.contains($0.key) }
        
        // NEVER set selectedIndex during updatePages - this causes crashes during layout
        // The selectedIndex will be set later when the controller is fully ready
        print("📋 [SpacePageController] Updated arrangedObjects with \(arrangedObjects.count) items, skipping selectedIndex update")
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
        
        // Set the current selection - ensure it's within bounds
        let safeSelection = max(0, min(currentSelection, spaces.count - 1))
        if safeSelection != currentSelection {
            currentSelection = safeSelection
        }
        
        // Additional safety check - ensure selectedIndex is within arrangedObjects bounds
        if safeSelection < arrangedObjects.count {
            print("✅ [SpacePageController] Setting selectedIndex to \(safeSelection)")
            selectedIndex = safeSelection
        } else {
            print("⚠️ [SpacePageController] Safe selection \(safeSelection) is out of bounds for \(arrangedObjects.count) arranged objects")
        }
    }
    
    func updateWidth(_ newWidth: CGFloat) {
        guard newWidth != currentWidth else { return }
        currentWidth = newWidth
        
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
        if currentIndex >= 0 && currentIndex < spaces.count {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.selectedIndex = currentIndex
                
                // Ensure current page stays locked to left edge
                if let currentPageView = self.selectedViewController?.view {
                    let currentSize = self.view.bounds.size
                    currentPageView.frame = CGRect(x: 0, y: 0, width: currentSize.width, height: currentSize.height)
                }
            }
        }
    }
    
    // MARK: - NSPageControllerDelegate
    
    func pageController(_ pageController: NSPageController, identifierFor object: Any) -> NSPageController.ObjectIdentifier {
        return object as? String ?? ""
    }
    
    func pageController(_ pageController: NSPageController, viewControllerForIdentifier identifier: NSPageController.ObjectIdentifier) -> NSViewController {
        // Find the space for this identifier
        guard let spaceId = UUID(uuidString: identifier),
              let space = spaces.first(where: { $0.id == spaceId }) else {
            return NSViewController()
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
        guard let identifier = object as? String,
              let spaceId = UUID(uuidString: identifier),
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
