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
        SpacePager(
            selection: $activeSpaceIndex,
            spaces: browserManager.tabManager.spaces,
            width: effectiveWidth,
            onSpaceChanged: { newSpaceIndex in
                guard newSpaceIndex >= 0 && newSpaceIndex < browserManager.tabManager.spaces.count else {
                    print("⚠️ [SidebarView] Invalid space index: \(newSpaceIndex)")
                    return
                }
                
                // Update activeSpaceIndex and activate the space
                print("🎯 SpacePager activated space: \(browserManager.tabManager.spaces[newSpaceIndex].name) (index: \(newSpaceIndex))")
                activeSpaceIndex = newSpaceIndex
                let space = browserManager.tabManager.spaces[newSpaceIndex]
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
            },
            onTransitionStarted: {
                // Mark that we're in a transition to prevent profile switching conflicts
                print("🔄 [SpacePager] Transition started - deferring profile switches")
                browserManager.isSpaceTransitioning = true
            },
            onTransitionEnded: {
                // Allow profile switching to resume
                print("✅ [SpacePager] Transition ended - profile switches can resume")
                browserManager.isSpaceTransitioning = false
                // Process any deferred profile switches
                browserManager.processDeferredProfileSwitches()
            }
        )
        .onAppear {
            // Initialize to current active space
            activeSpaceIndex = targetScrollPosition
            print("🔄 Initialized activeSpaceIndex: \(activeSpaceIndex)")
        }
        .onChange(of: windowState.currentSpaceId) { _, _ in
            // Space was changed programmatically (e.g., clicking bottom icons)
            let newSpaceIndex = targetScrollPosition
            if newSpaceIndex != activeSpaceIndex {
                print("🎯 Programmatic space change - syncing activeSpaceIndex to \(newSpaceIndex)")
                activeSpaceIndex = newSpaceIndex
            }
        }
        .onChange(of: browserManager.tabManager.spaces.count) { _, newCount in
            // Spaces were added or deleted - ensure activeSpaceIndex is valid
            let newSpaceIndex = min(targetScrollPosition, newCount - 1)
            if newSpaceIndex != activeSpaceIndex {
                print("🔄 Spaces count changed to \(newCount) - updating activeSpaceIndex to \(newSpaceIndex)")
                activeSpaceIndex = max(0, newSpaceIndex)
            }
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
