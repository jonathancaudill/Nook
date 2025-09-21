//
//  SpacePageView.swift
//  Nook
//
//  NSPageController-based implementation with tight SwiftUI integration
//

import SwiftUI
import AppKit

/// A NSView to exposure the `onStartLiveResize` and `onEndLiveResize` event.
private class ResizeAwareNSView: NSView {
    var onEndLiveResize: (() -> Void)?
    var onStartLiveResize: (() -> Void)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        onStartLiveResize?()
    }
}

/// A SwiftUI wrapper for NSPageController that provides native trackpad gestures for space navigation
struct SpacePager: View {
    @Binding var selection: Int
    let pages: [AnyView]
    let width: CGFloat
    let onSpaceChanged: (Int) -> Void
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void

    // Environment objects to pass through
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var windowState: BrowserWindowState
    @EnvironmentObject var splitManager: SplitViewManager

    var body: some View {
        NSPageViewRepresentable(
            selection: $selection,
            pages: pages,
            width: width,
            onSpaceChanged: onSpaceChanged,
            onDragStarted: onDragStarted,
            onDragEnded: onDragEnded,
            browserManager: browserManager,
            windowState: windowState,
            splitManager: splitManager
        )
        // Don't apply frame here - let the content handle its own width
    }
}

private struct NSPageViewRepresentable: NSViewControllerRepresentable {
    @Binding var selection: Int
    let pages: [AnyView]
    let width: CGFloat
    let onSpaceChanged: (Int) -> Void
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void

    // Explicitly accept environment objects
    let browserManager: BrowserManager
    let windowState: BrowserWindowState
    let splitManager: SplitViewManager

    func makeNSViewController(context: Context) -> SpacePageController {
        let controller = SpacePageController()
        controller.pages = pages
        controller.lastWidth = width
        controller.onSpaceChanged = onSpaceChanged
        controller.onDragStarted = onDragStarted
        controller.onDragEnded = onDragEnded
        controller.browserManager = browserManager
        controller.windowState = windowState
        controller.splitManager = splitManager
        
        // Extract spaces and callbacks from the pages
        // This is a bit of a hack, but we need to get the spaces from somewhere
        // For now, we'll use the pages array and extract the spaces from the browserManager
        controller.spaces = browserManager.tabManager.spaces
        
        return controller
    }

    func updateNSViewController(_ controller: SpacePageController, context: Context) {
        // Always update pages to ensure content is fresh
        controller.pages = pages
        controller.spaces = browserManager.tabManager.spaces

        // Only reload pages if we have spaces to avoid crashes during startup
        if !controller.spaces.isEmpty {
            // Reload pages if count changed OR if width changed (to force content recreation with new width)
            if controller.arrangedObjects.count != controller.spaces.count {
                controller.reloadPages()
            } else if controller.lastWidth != width {
                // Width changed - update stored width but don't force reload
                // The dynamic content creation will handle the new width automatically
                controller.lastWidth = width
            }
        }

        // Only update selection when spaces exist and selection is valid
        guard !controller.spaces.isEmpty, selection >= 0, selection < controller.spaces.count else {
            return
        }

        // Only update selection if it has actually changed
        guard controller.selectedIndex != selection else {
            return
        }

        let animated = context.transaction.animation != nil
        controller.updateSelectedIndex(selection, animated: animated)
    }
}

/// Custom NSPageController that handles space navigation
private class SpacePageController: NSPageController, NSPageControllerDelegate {
    var pages: [AnyView] = []
    var lastWidth: CGFloat = 0
    var lastContainerSize: NSSize = .zero
    private var previousBoundsSize: CGSize = .zero
    
    // Store spaces and callbacks directly for dynamic content creation
    var spaces: [Space] = []
    var onActivateTab: ((Tab) -> Void)?
    var onCloseTab: ((Tab) -> Void)?
    var onPinTab: ((Tab) -> Void)?
    var onMoveTabUp: ((Tab) -> Void)?
    var onMoveTabDown: ((Tab) -> Void)?
    var onMuteTab: ((Tab) -> Void)?

    // Explicitly hold weak references to managers
    weak var browserManager: BrowserManager?
    weak var windowState: BrowserWindowState?
    weak var splitManager: SplitViewManager?

    // Callbacks to maintain existing SidebarView logic
    var onSpaceChanged: ((Int) -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var isTransitioning = false

    override func loadView() {
        let view = ResizeAwareNSView()
        view.onStartLiveResize = { [weak self] in
            self?.completeTransition()
        }
        view.onEndLiveResize = { [weak self] in
            self?.completeTransition()
        }
        self.view = view
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        view.wantsLayer = true
        
        // Configure for horizontal scrolling behavior
        transitionStyle = .horizontalStrip
        
        // Initialize container size tracking
        lastContainerSize = view.bounds.size
        
        // Only set up pages if we have spaces
        if !spaces.isEmpty {
            reloadPages()
        }
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        
        // When our container changes size due to SwiftUI layout (e.g., Split resizing),
        // NSPageController may not immediately resize its current page until a transition occurs.
        // Force-complete the transition so the current page view adopts the new bounds.
        let currentSize = self.view.bounds.size
        if currentSize != previousBoundsSize {
            previousBoundsSize = currentSize
            self.completeTransition()
        }
        
        // Also update lastContainerSize for backward compatibility
        lastContainerSize = currentSize
    }

    func reloadPages() {
        let count = spaces.count
        
        // If no spaces, don't touch NSPageController at all to avoid crashes
        guard count > 0 else {
            // Just clear arrangedObjects without touching selectedIndex
            arrangedObjects = []
            return
        }
        
        // We have spaces, so we can safely work with NSPageController
        // Ensure selectedIndex is valid for the new array size
        if selectedIndex >= count {
            selectedIndex = 0
        }
        
        // Now safely set arrangedObjects
        arrangedObjects = Array(0..<count)
    }

    func updateSelectedIndex(_ index: Int, animated: Bool) {
        // Only update if we have spaces and the index is valid
        guard !spaces.isEmpty, index >= 0, index < spaces.count else {
            return
        }

        // Only update if the index has actually changed
        guard selectedIndex != index else { 
            return 
        }

        if animated {
            // Use animator for smooth transitions
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.animator().selectedIndex = index
            }, completionHandler: nil)
        } else {
            // Disable animation for immediate updates
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                selectedIndex = index
            }
        }
    }

    // MARK: - NSPageControllerDelegate

    func pageController(_ pageController: NSPageController, viewControllerForIdentifier identifier: NSPageController.ObjectIdentifier) -> NSViewController {
        guard let index = Int(identifier), index >= 0, index < spaces.count else {
            return NSViewController()
        }

        let contentController = SpaceContentController()
        contentController.spaceIndex = index

        // Pass environment objects explicitly to content controller
        contentController.browserManager = browserManager
        contentController.windowState = windowState
        contentController.splitManager = splitManager

        // Capture the current spaces and references to ensure we get the right content
        let currentSpaces = spaces
        let currentBrowserManager = browserManager
        let currentWindowState = windowState
        contentController.allSpacesContentBuilder = { [weak self] in
            guard index < currentSpaces.count else {
                return AnyView(EmptyView())
            }
            // Create a new SpaceView with current width instead of using pre-built page
            // This ensures the width is always up-to-date
            let space = currentSpaces[index]
            let currentWidth = self?.lastWidth ?? 250.0 // Use current width from controller
            return AnyView(
                VStack(spacing: 0) {
                    SpaceView(
                        space: space,
                        isActive: currentWindowState?.currentSpaceId == space.id,
                        width: currentWidth,
                        onActivateTab: { currentBrowserManager?.selectTab($0, in: currentWindowState!) },
                        onCloseTab: { currentBrowserManager?.tabManager.removeTab($0.id) },
                        onPinTab: { currentBrowserManager?.tabManager.pinTab($0) },
                        onMoveTabUp: { currentBrowserManager?.tabManager.moveTabUp($0.id) },
                        onMoveTabDown: { currentBrowserManager?.tabManager.moveTabDown($0.id) },
                        onMuteTab: { $0.toggleMute() }
                    )
                    .id(space.id)
                }
            )
        }

        return contentController
    }

    func pageController(_ pageController: NSPageController, identifierFor object: Any) -> NSPageController.ObjectIdentifier {
        guard let index = object as? Int else { return "0" }
        return String(index)
    }

    func pageController(_ pageController: NSPageController, didTransitionTo object: Any) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.onSpaceChanged?(self.selectedIndex)

            if self.isTransitioning {
                self.isTransitioning = false
                self.onDragEnded?()
            }
        }
    }

    func pageController(_ pageController: NSPageController, willTransitionTo object: Any) {
        isTransitioning = true
        onDragStarted?()
    }

    deinit {
        delegate = nil
    }
}

/// NSViewController that hosts the SwiftUI content for each space
private class SpaceContentController: NSViewController {
    var spaceIndex: Int = 0
    var allSpacesContentBuilder: (() -> AnyView)? {
        didSet {
            updateContent()
        }
    }

    // Explicitly accept environment objects
    weak var browserManager: BrowserManager?
    weak var windowState: BrowserWindowState?
    weak var splitManager: SplitViewManager?

    private var hostingView: NSHostingView<AnyView>?
    private var containerView: NSView?

    override func loadView() {
        // Create a container view to ensure proper sizing
        let container = NSView()
        containerView = container
        view = container

        updateContent()
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        
        // Ensure the hosting view adopts the new bounds when the container resizes
        // This is crucial for SwiftUI content to resize properly
        if let hostingView = hostingView {
            hostingView.frame = view.bounds
        }
    }

    private func updateContent() {
        guard let contentBuilder = allSpacesContentBuilder,
              let container = containerView else {
            return
        }

        // Remove existing hosting view
        hostingView?.removeFromSuperview()

        // Create new hosting view with current content
        // Apply environment objects here
        let contentView = contentBuilder()
            .environmentObject(browserManager!) // Force unwrap for now, will refine
            .environmentObject(windowState!)
            .environmentObject(splitManager!)
        
        let newHostingView = NSHostingView(rootView: contentView)
        newHostingView.translatesAutoresizingMaskIntoConstraints = false
        
        // Store as AnyView to match the property type
        hostingView = newHostingView as? NSHostingView<AnyView>

        container.addSubview(newHostingView)

        NSLayoutConstraint.activate([
            newHostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            newHostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            newHostingView.topAnchor.constraint(equalTo: container.topAnchor),
            newHostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Configure hosting view for proper resizing behavior
        // Allow it to expand and contract with the container
        newHostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newHostingView.setContentHuggingPriority(.defaultLow, for: .vertical)
        newHostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newHostingView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
}

// MARK: - Preview

#Preview {
    SpacePager(
        selection: .constant(0),
        pages: [
            AnyView(Text("Space 1").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.blue)),
            AnyView(Text("Space 2").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.green)),
            AnyView(Text("Space 3").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.red))
        ],
        width: 300,
        onSpaceChanged: { _ in },
        onDragStarted: { },
        onDragEnded: { }
    )
    .frame(height: 400)
}