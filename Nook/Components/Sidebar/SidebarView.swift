import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var windowState: BrowserWindowState
    @Environment(\.tabDragManager) private var dragManager
    @State private var activeSpaceIndex: Int = 0
    @State private var hasTriggeredHaptic = false
    @State private var spaceName = ""
    @State private var spaceIcon = ""
    @State private var showHistory = false
    @State private var sidebarDraggedItem: UUID? = nil
    // Force rendering even when the real sidebar is collapsed (used by hover overlay)
    var forceVisible: Bool = false
    // Override the width for overlay use; falls back to BrowserManager width
    var forcedWidth: CGFloat? = nil

    private var effectiveWidth: CGFloat {
        forcedWidth ?? windowState.sidebarWidth
    }

    private var targetScrollPosition: Int {
        if let currentSpaceId = windowState.currentSpaceId,
           let index = browserManager.tabManager.spaces.firstIndex(where: { $0.id == currentSpaceId }) {
            return index
        }
        return 0
    }
    
    private var visibleSpaceIndices: [Int] {
        let totalSpaces = browserManager.tabManager.spaces.count
        
        guard totalSpaces > 0 else { return [] }
        
        // Ensure activeSpaceIndex is within bounds
        let safeActiveIndex = min(max(activeSpaceIndex, 0), totalSpaces - 1)
        
        // If the activeSpaceIndex is out of bounds, update it
        if activeSpaceIndex != safeActiveIndex {
            print("⚠️ activeSpaceIndex out of bounds: \(activeSpaceIndex), correcting to: \(safeActiveIndex)")
            DispatchQueue.main.async {
                self.activeSpaceIndex = safeActiveIndex
            }
        }
        
        var indices: [Int] = []
        
        if safeActiveIndex == 0 {
            // First space: show [0, 1]
            indices.append(0)
            if totalSpaces > 1 {
                indices.append(1)
            }
        } else if safeActiveIndex == totalSpaces - 1 {
            // Last space: show [last-1, last]
            indices.append(safeActiveIndex - 1)
            indices.append(safeActiveIndex)
        } else {
            // Middle space: show [current-1, current, current+1]
            indices.append(safeActiveIndex - 1)
            indices.append(safeActiveIndex)
            indices.append(safeActiveIndex + 1)
        }
        
        print("🔍 visibleSpaceIndices - activeSpaceIndex: \(activeSpaceIndex), safeIndex: \(safeActiveIndex), totalSpaces: \(totalSpaces), result: \(indices)")
        return indices
    }
    

    var body: some View {
        if windowState.isSidebarVisible || forceVisible {
            sidebarContent
        }
    }
    
    private var sidebarContent: some View {
        let effectiveProfileId = windowState.currentProfileId ?? browserManager.currentProfile?.id
        let essentialsCount = effectiveProfileId.map { browserManager.tabManager.essentialTabs(for: $0).count } ?? 0

        let shouldAnimate = (browserManager.activeWindowState?.id == windowState.id) && !browserManager.isTransitioningProfile

        let content = VStack(spacing: 8) {
            HStack(spacing: 2) {
                NavButtonsView()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        DispatchQueue.main.async {
                            zoomCurrentWindow()
                        }
                    }
            )
            .backgroundDraggable()

            URLBarView()
                .padding(.horizontal, 8)
            // Container to support PinnedGrid slide transitions without clipping
            ZStack {
                PinnedGrid(
                    width: max(0, effectiveWidth - 16),
                    profileId: effectiveProfileId
                )
                    .environmentObject(windowState)
            }
            .padding(.horizontal, 8)
            .modifier(FallbackDropBelowEssentialsModifier())

            if showHistory {
                historyView
                    .padding(.horizontal, 8)
            } else {
                spacesScrollView
            }

            // MARK: - Bottom
            ZStack {
                // Left side icons - anchored to left
                HStack {
                    NavButton(iconName: "square.and.arrow.down") {
                        print("Downloads button pressed")
                    }

                    NavButton(iconName: "clock") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showHistory.toggle()
                        }
                    }

                    Spacer()
                }

                // Center content - space indicators or history text
                if !showHistory {
                    SpacesList()
                        .environmentObject(windowState)
                } else {
                    Text("History")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                // Right side icons - anchored to right
                HStack {
                    Spacer()

                    if !showHistory {
                        NavButton(iconName: "plus") {
                            showSpaceCreationDialog()
                        }
                    } else {
                        NavButton(iconName: "arrow.left") {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showHistory = false
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
        .frame(width: effectiveWidth)
        
        return content.animation(shouldAnimate ? .easeInOut(duration: 0.18) : nil, value: essentialsCount)
    }
    
    private var historyView: some View {
        HistoryView()
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
    }
    
    private var spacesScrollView: some View {
        ZStack {
            spacesContent
        }
        .transition(.asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        ))
    }
    
    private var spacesContent: some View {
        return SimpleSpacePager(
            selection: $activeSpaceIndex,
            spaces: browserManager.tabManager.spaces,
            width: effectiveWidth,
            onSpaceChanged: { newSpaceIndex in
                guard newSpaceIndex >= 0 && newSpaceIndex < browserManager.tabManager.spaces.count else {
                    print("⚠️ [SidebarView] Invalid space index: \(newSpaceIndex)")
                    return
                }
                
                // CRITICAL: Update activeSpaceIndex FIRST to keep UI in sync
                // This prevents the onChange(currentSpaceId) from triggering since the index is already correct
                print("🎯 Swipe gesture: updating activeSpaceIndex from \(activeSpaceIndex) to \(newSpaceIndex)")
                activeSpaceIndex = newSpaceIndex
                
                let space = browserManager.tabManager.spaces[newSpaceIndex]
                print("🎯 NSPageController activated space: \(space.name) (index: \(newSpaceIndex))")
                browserManager.setActiveSpace(space, in: windowState)
            },
            onDragStarted: {
                if !hasTriggeredHaptic {
                    hasTriggeredHaptic = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        let impact = NSHapticFeedbackManager.defaultPerformer
                        impact.perform(.alignment, performanceTime: .default)
                        print("🎯 Haptic 0.1s after drag start")
                    }
                }
            },
            onDragEnded: {
                hasTriggeredHaptic = false
            }
        )
        .onAppear {
            // Simple initialization - NSPageController handles the rest
            activeSpaceIndex = targetScrollPosition
            print("🔄 Initialized activeSpaceIndex: \(activeSpaceIndex)")
        }
        .onChange(of: windowState.currentSpaceId) { _, newSpaceId in
            // CRITICAL: Only sync activeSpaceIndex for external changes (clicks, programmatic)
            // Swipe gestures handle their own activeSpaceIndex updates via onSpaceChanged
            guard newSpaceId != nil else { return }
            
            let newSpaceIndex = targetScrollPosition
            if newSpaceIndex != activeSpaceIndex {
                print("🎯 External space change detected - syncing activeSpaceIndex from \(activeSpaceIndex) to \(newSpaceIndex)")
                
                // CRITICAL: Use immediate sync for external changes to prevent UI desync
                // The key is that swipe gestures bypass this by updating activeSpaceIndex directly in onSpaceChanged
                // Only non-swipe changes (clicks, programmatic) will trigger this onChange
                activeSpaceIndex = newSpaceIndex
            }
        }
        .onChange(of: browserManager.tabManager.spaces.count) { _, newCount in
            // Handle space count changes
            let newSpaceIndex = min(targetScrollPosition, newCount - 1)
            if newSpaceIndex != activeSpaceIndex {
                print("🔄 Spaces count changed to \(newCount) - updating activeSpaceIndex to \(newSpaceIndex)")
                // Defer the update to avoid SwiftUI view update conflicts
                DispatchQueue.main.async {
                    activeSpaceIndex = max(0, newSpaceIndex)
                }
            }
        }
    }
    
    private var spacesHStack: some View {
        LazyHStack(spacing: 0) {
            ForEach(visibleSpaceIndices, id: \.self) { spaceIndex in
                let space = browserManager.tabManager.spaces[spaceIndex]
                VStack(spacing: 0) {
                    SpaceView(
                        space: space,
                        isActive: windowState.currentSpaceId == space.id,
                        width: effectiveWidth,
                        onActivateTab: { browserManager.selectTab($0, in: windowState) },
                        onCloseTab: { browserManager.tabManager.removeTab($0.id) },
                        onPinTab: { browserManager.tabManager.pinTab($0) },
                        onMoveTabUp: { browserManager.tabManager.moveTabUp($0.id) },
                        onMoveTabDown: { browserManager.tabManager.moveTabDown($0.id) },
                        onMuteTab: { $0.toggleMute() }
                    )
                    .id(space.id)
                }
                .id(spaceIndex)
            }
        }
        .scrollTargetLayout()
    }
    


    func scrollToSpace(_ space: Space, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(space.id, anchor: .center)
        }
    }
    
    private func showSpaceCreationDialog() {
        let dialog = SpaceCreationDialog(
            spaceName: $spaceName,
            spaceIcon: $spaceIcon,
            onSave: {
                // Create the space with the name from dialog
                browserManager.tabManager.createSpace(
                    name: spaceName.isEmpty ? "New Space" : spaceName,
                    icon: spaceIcon.isEmpty ? "✨" : spaceIcon
                )
                
                // Reset form
                spaceName = ""
                spaceIcon = ""
            },
            onCancel: {
                browserManager.dialogManager.closeDialog()
                
                // Reset form
                spaceName = ""
                spaceIcon = ""
            },
            onClose: {
                browserManager.dialogManager.closeDialog()
            }
        )
        
        browserManager.dialogManager.showDialog(dialog)
    }
}

// MARK: - Private helpers
