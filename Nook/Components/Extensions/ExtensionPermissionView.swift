//
//  ExtensionPermissionView.swift
//  Nook
//
//  Created for WKWebExtension permission management
//

import SwiftUI
import WebKit

@available(macOS 15.4, *)
struct ExtensionPermissionView: View {
    let extensionName: String
    let extensionId: String?
    let requestedPermissions: [String]
    let optionalPermissions: [String]
    let requestedHostPermissions: [String]
    let optionalHostPermissions: [String]
    let onGrant: () -> Void
    let onDeny: () -> Void
    let extensionLogo: NSImage? // Phase 12.2: Make optional, will load dynamically if nil
    
    @State private var loadedIcon: NSImage?
    @State private var isLoadingIcon: Bool = false

    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 8) {
                HStack(spacing: 24) {
                    Image("nook-logo-1024")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                    Image(systemName: "arrow.left")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    // Phase 12.2: Load icon dynamically
                    Group {
                        if let icon = loadedIcon ?? extensionLogo {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                        } else if isLoadingIcon {
                            ProgressView()
                                .frame(width: 64, height: 64)
                        } else {
                            Image(systemName: "puzzlepiece.extension")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                
            
            }
            Text("Add the \"\(extensionName)\"extension to Nook?")
                .font(.system(size: 16, weight: .semibold))
            
            Text("It can:")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(requestedPermissions, id: \.self) { permission in
                    let message = getPermissionDescription(permission)
                    Text("•  \(message)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack{
                Button("Cancel") {
                    onDeny()
                }
                Spacer()
                Button("Add Extension") {
                    onGrant()
                }
            }
        }
        .padding(20)
        .onAppear {
            // Phase 12.2: Load extension icon if not provided and extensionId is available
            if extensionLogo == nil, let extensionId = extensionId {
                loadExtensionIcon(extensionId: extensionId)
            } else {
                loadedIcon = extensionLogo
            }
        }
    }
    
    // Phase 12.2: Load extension icon dynamically
    private func loadExtensionIcon(extensionId: String) {
        guard #available(macOS 15.4, *) else { return }
        
        isLoadingIcon = true
        
        let iconSize = NSSize(width: 64, height: 64)
        
        // Try to get from cache first
        if let cachedIcon = ExtensionManager.shared.getCachedIcon(for: extensionId, size: iconSize) {
            loadedIcon = cachedIcon
            isLoadingIcon = false
            return
        }
        
        // Try to load from extension context
        if let extensionIcon = ExtensionManager.shared.getExtensionIcons(for: extensionId, size: iconSize) {
            loadedIcon = extensionIcon
            isLoadingIcon = false
            return
        }
        
        // If no icon found, use placeholder
        isLoadingIcon = false
    }
    
    private func getPermissionDescription(_ permission: String) -> String {
        switch permission {
        case "storage":
            return "Store and retrieve data locally"
        case "activeTab":
            return "Access the currently active tab when you click the extension"
        case "tabs":
            return "Access basic information about all tabs"
        case "bookmarks":
            return "Read and modify your bookmarks"
        case "history":
            return "Access your browsing history"
        case "cookies":
            return "Access cookies for websites"
        case "webNavigation":
            return "Monitor and analyze web page navigation"
        case "scripting":
            return "Inject scripts into web pages"
        case "notifications":
            return "Display notifications"
        default:
            return "Access \(permission) functionality"
        }
    }
}

#Preview {
    ExtensionPermissionView(
        extensionName: "Sample Extension",
        extensionId: nil,
        requestedPermissions: ["storage", "activeTab", "tabs"],
        optionalPermissions: ["notifications"],
        requestedHostPermissions: ["https://*.google.com/*"],
        optionalHostPermissions: ["https://github.com/*"],
        onGrant: { },
        onDeny: { },
        extensionLogo: NSImage(imageLiteralResourceName: "nook-logo-1024")
    )
}
