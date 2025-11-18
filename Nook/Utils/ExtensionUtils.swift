//
//  ExtensionUtils.swift
//  Nook
//
//  Created for WKWebExtension support
//

import Foundation
import WebKit

@MainActor
struct ExtensionUtils {
    /// Check if the current OS supports WKWebExtension APIs we rely on
    /// We target the newest OS that includes `world` support for scripting/content scripts.
    /// Requires iOS/iPadOS 18.5+ or macOS 15.5+.
    static var isExtensionSupportAvailable: Bool {
        if #available(iOS 18.5, macOS 15.5, *) { return true }
        return false
    }

    /// Whether MAIN/ISOLATED execution worlds are supported for `chrome.scripting` and content scripts.
    /// Newer WebKit builds honor `world: 'MAIN'|'ISOLATED'` and `content_scripts[].world`.
    static var isWorldInjectionSupported: Bool {
        if #available(iOS 18.5, macOS 15.5, *) { return true }
        return false
    }
    
    /// Show an alert when extensions are not available on older OS versions
    static func showUnsupportedOSAlert() {
        // This will be implemented when we add alert functionality
        print("Extensions require iOS 18.5+ or macOS 15.5+")
    }
    
    /// Validate a manifest.json file structure
    static func validateManifest(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtensionError.invalidManifest("Invalid JSON structure")
        }
        
        // Basic manifest validation
        guard let _ = manifest["manifest_version"] as? Int else {
            throw ExtensionError.invalidManifest("Missing manifest_version")
        }
        
        guard let _ = manifest["name"] as? String else {
            throw ExtensionError.invalidManifest("Missing name")
        }
        
        guard let _ = manifest["version"] as? String else {
            throw ExtensionError.invalidManifest("Missing version")
        }
        
        return manifest
    }
    
    /// Generate a unique extension identifier
    static func generateExtensionId() -> String {
        return UUID().uuidString.lowercased()
    }
    
    // MARK: - Phase 10.1: Match Pattern Utilities
    
    /// Get the match pattern for `<all_urls>`
    @available(macOS 15.4, *)
    static var allURLsMatchPattern: WKWebExtension.MatchPattern? {
        return WKWebExtension.MatchPattern.allURLs()
    }
    
    /// Get the match pattern for all hosts and schemes
    @available(macOS 15.4, *)
    static var allHostsAndSchemesMatchPattern: WKWebExtension.MatchPattern? {
        return WKWebExtension.MatchPattern.allHostsAndSchemes()
    }
    
    /// Create a match pattern from a string
    /// - Parameter patternString: The pattern string (e.g., "https://*.example.com/*")
    /// - Returns: A match pattern if valid, nil otherwise
    @available(macOS 15.4, *)
    static func matchPatternWithString(_ patternString: String) -> WKWebExtension.MatchPattern? {
        do {
            return try WKWebExtension.MatchPattern(string: patternString)
        } catch {
            print("❌ [Phase 10.1] Invalid match pattern string: \(patternString) - \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Create a match pattern with specific scheme, host, and path
    /// - Parameters:
    ///   - scheme: URL scheme (e.g., "https", "http", "*")
    ///   - host: Host pattern (e.g., "*.example.com", "example.com")
    ///   - path: Path pattern (e.g., "/*", "/path/*")
    /// - Returns: A match pattern if valid, nil otherwise
    @available(macOS 15.4, *)
    static func matchPatternWithScheme(_ scheme: String, host: String, path: String) -> WKWebExtension.MatchPattern? {
        do {
            return try WKWebExtension.MatchPattern(scheme: scheme, host: host, path: path)
        } catch {
            print("❌ [Phase 10.1] Invalid match pattern components - scheme: \(scheme), host: \(host), path: \(path) - \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Validate a match pattern string
    /// - Parameter patternString: The pattern string to validate
    /// - Returns: true if valid, false otherwise
    @available(macOS 15.4, *)
    static func isValidMatchPattern(_ patternString: String) -> Bool {
        return matchPatternWithString(patternString) != nil
    }
    
    /// Check if two match patterns conflict (one is more restrictive than the other)
    /// - Parameters:
    ///   - pattern1: First match pattern
    ///   - pattern2: Second match pattern
    /// - Returns: true if patterns conflict, false otherwise
    @available(macOS 15.4, *)
    static func patternsConflict(_ pattern1: WKWebExtension.MatchPattern, _ pattern2: WKWebExtension.MatchPattern) -> Bool {
        // Two patterns conflict if one matches URLs that the other doesn't
        // This is a simplified check - in practice, you'd need more sophisticated logic
        return pattern1.description != pattern2.description
    }
    
    /// Normalize a match pattern string (remove redundant wildcards, etc.)
    /// - Parameter patternString: The pattern string to normalize
    /// - Returns: Normalized pattern string, or original if invalid
    @available(macOS 15.4, *)
    static func normalizeMatchPattern(_ patternString: String) -> String {
        guard let pattern = matchPatternWithString(patternString) else {
            return patternString
        }
        return pattern.description
    }
    
    /// Check if a URL matches a match pattern
    /// - Parameters:
    ///   - url: The URL to check
    ///   - pattern: The match pattern
    /// - Returns: true if URL matches pattern, false otherwise
    @available(macOS 15.4, *)
    static func urlMatchesPattern(_ url: URL, pattern: WKWebExtension.MatchPattern) -> Bool {
        return pattern.matches(url)
    }
    
    /// Check if a match pattern matches another match pattern
    /// - Parameters:
    ///   - pattern1: First match pattern
    ///   - pattern2: Second match pattern
    /// - Returns: true if patterns match, false otherwise
    @available(macOS 15.4, *)
    static func patternMatchesPattern(_ pattern1: WKWebExtension.MatchPattern, _ pattern2: WKWebExtension.MatchPattern) -> Bool {
        return pattern1.matches(pattern2)
    }
    
    /// Register a custom URL scheme for match pattern matching
    /// - Parameter scheme: The custom URL scheme to register
    @available(macOS 15.4, *)
    static func registerCustomURLScheme(_ scheme: String) {
        WKWebExtension.MatchPattern.registerCustomURLScheme(scheme)
        print("✅ [Phase 10.1] Registered custom URL scheme: \(scheme)")
    }
    
    // MARK: - Phase 13.1: Error Handling Utilities
    
    /// Error handler for WKWebExtension errors
    @available(macOS 15.4, *)
    struct ExtensionErrorHandler {
        /// Convert WKWebExtension error to user-friendly message
        /// - Parameter error: The WKWebExtension error
        /// - Returns: User-friendly error message
        static func userFriendlyMessage(for error: WKWebExtension.Error) -> String {
            // WKWebExtension.Error only has localizedDescription
            return error.localizedDescription
        }
        
        /// Determine if an error is recoverable
        /// - Parameter error: The WKWebExtension error
        /// - Returns: true if error is recoverable, false otherwise
        static func shouldRecover(from error: WKWebExtension.Error) -> Bool {
            // Check error domain/code for recoverable errors
            let errorDescription = error.localizedDescription.lowercased()
            
            // Network errors are often recoverable
            if errorDescription.contains("network") || errorDescription.contains("connection") {
                return true
            }
            
            // Permission errors might be recoverable
            if errorDescription.contains("permission") {
                return true
            }
            
            // Context loading errors might be recoverable
            if errorDescription.contains("load") || errorDescription.contains("context") {
                return true
            }
            
            return false
        }
        
        /// Get recovery action suggestion for an error
        /// - Parameter error: The WKWebExtension error
        /// - Returns: Recovery action string, or nil if no recovery available
        static func recoveryAction(for error: WKWebExtension.Error) -> String? {
            // Provide generic recovery actions based on error type
            let errorDescription = error.localizedDescription.lowercased()
            
            if errorDescription.contains("network") || errorDescription.contains("connection") {
                return "Check your internet connection and try again."
            }
            
            if errorDescription.contains("permission") {
                return "Grant the required permissions in extension settings."
            }
            
            if errorDescription.contains("load") || errorDescription.contains("context") {
                return "Try reloading the extension or restarting the browser."
            }
            
            if errorDescription.contains("manifest") {
                return "Check the extension's manifest.json file for errors."
            }
            
            return nil
        }
        
        /// Get error severity level
        /// - Parameter error: The WKWebExtension error
        /// - Returns: Error severity (info, warning, error, critical)
        static func errorSeverity(for error: WKWebExtension.Error) -> ErrorSeverity {
            let errorDescription = error.localizedDescription.lowercased()
            
            // Critical errors
            if errorDescription.contains("crash") || errorDescription.contains("terminate") {
                return .critical
            }
            
            // Errors
            if errorDescription.contains("failed") || errorDescription.contains("error") {
                return .error
            }
            
            // Warnings
            if errorDescription.contains("warning") || errorDescription.contains("deprecated") {
                return .warning
            }
            
            // Default to info
            return .info
        }
        
        /// Log error with appropriate severity
        /// - Parameters:
        ///   - error: The WKWebExtension error
        ///   - extensionId: The extension ID (optional)
        static func logError(_ error: WKWebExtension.Error, extensionId: String? = nil) {
            let severity = errorSeverity(for: error)
            let prefix = extensionId != nil ? "[Extension: \(extensionId!)]" : "[Extension]"
            
            switch severity {
            case .critical:
                print("🔴 \(prefix) CRITICAL: \(userFriendlyMessage(for: error))")
            case .error:
                print("❌ \(prefix) ERROR: \(userFriendlyMessage(for: error))")
            case .warning:
                print("⚠️ \(prefix) WARNING: \(userFriendlyMessage(for: error))")
            case .info:
                print("ℹ️ \(prefix) INFO: \(userFriendlyMessage(for: error))")
            }
            
            // Log additional error details
            // WKWebExtension.Error only provides localizedDescription
        }
    }
    
    /// Error severity levels
    @available(macOS 15.4, *)
    enum ErrorSeverity {
        case info
        case warning
        case error
        case critical
    }
}

enum ExtensionError: LocalizedError {
    case unsupportedOS
    case invalidManifest(String)
    case installationFailed(String)
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Extensions require iOS 18.5+ or macOS 15.5+"
        case .invalidManifest(let reason):
            return "Invalid manifest.json: \(reason)"
        case .installationFailed(let reason):
            return "Installation failed: \(reason)"
        case .permissionDenied:
            return "Permission denied"
        }
    }
}
