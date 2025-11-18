//
//  ExtensionErrorView.swift
//  Nook
//
//  Phase 3.9: Extension Error Display UI
//

import SwiftUI
import WebKit

@available(macOS 15.4, *)
struct ExtensionErrorView: View {
    let extensionId: String
    let errors: [WKWebExtension.Error]
    let onDismiss: () -> Void
    @State private var expandedErrors: Set<Int> = []
    
    // Phase 13.1: Group errors by severity
    private var groupedErrors: [ExtensionUtils.ErrorSeverity: [WKWebExtension.Error]] {
        var grouped: [ExtensionUtils.ErrorSeverity: [WKWebExtension.Error]] = [:]
        for error in errors {
            let severity = ExtensionUtils.ExtensionErrorHandler.errorSeverity(for: error)
            if grouped[severity] == nil {
                grouped[severity] = []
            }
            grouped[severity]?.append(error)
        }
        return grouped
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Extension Errors")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Phase 13.1: Display errors grouped by severity
            ForEach(Array(groupedErrors.keys.sorted(by: { severityOrder($0) < severityOrder($1) })), id: \.self) { severity in
                if let severityErrors = groupedErrors[severity] {
                    Section(header: Text(severityLabel(severity))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(severityColor(severity))) {
                        ForEach(Array(severityErrors.enumerated()), id: \.offset) { index, error in
                            ErrorRowView(
                                error: error,
                                index: index,
                                isExpanded: expandedErrors.contains(index),
                                onToggle: {
                                    if expandedErrors.contains(index) {
                                        expandedErrors.remove(index)
                                    } else {
                                        expandedErrors.insert(index)
                                    }
                                },
                                onRecover: {
                                    handleRecovery(for: error)
                                }
                            )
                            
                            if index < severityErrors.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            
            // Phase 13.1: Recovery actions
            if hasRecoverableErrors {
                Divider()
                HStack {
                    Button("Try Recovery Actions") {
                        handleAllRecoveries()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var hasRecoverableErrors: Bool {
        errors.contains { ExtensionUtils.ExtensionErrorHandler.shouldRecover(from: $0) }
    }
    
    private func severityOrder(_ severity: ExtensionUtils.ErrorSeverity) -> Int {
        switch severity {
        case .critical: return 0
        case .error: return 1
        case .warning: return 2
        case .info: return 3
        }
    }
    
    private func severityLabel(_ severity: ExtensionUtils.ErrorSeverity) -> String {
        switch severity {
        case .critical: return "Critical Errors"
        case .error: return "Errors"
        case .warning: return "Warnings"
        case .info: return "Information"
        }
    }
    
    private func severityColor(_ severity: ExtensionUtils.ErrorSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .error: return .orange
        case .warning: return .yellow
        case .info: return .blue
        }
    }
    
    private func handleRecovery(for error: WKWebExtension.Error) {
        // Phase 13.1: Implement recovery actions
        if let recoveryAction = ExtensionUtils.ExtensionErrorHandler.recoveryAction(for: error) {
            print("🔄 [Phase 13.1] Attempting recovery: \(recoveryAction)")
            // TODO: Implement actual recovery logic based on error type
        }
    }
    
    private func handleAllRecoveries() {
        for error in errors where ExtensionUtils.ExtensionErrorHandler.shouldRecover(from: error) {
            handleRecovery(for: error)
        }
    }
}

// Phase 13.1: Error row view with expand/collapse and recovery
@available(macOS 15.4, *)
private struct ErrorRowView: View {
    let error: WKWebExtension.Error
    let index: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRecover: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                
                // Phase 13.1: Use user-friendly message
                Text(ExtensionUtils.ExtensionErrorHandler.userFriendlyMessage(for: error))
                    .font(.body)
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Phase 13.1: Show recovery button if recoverable
                if ExtensionUtils.ExtensionErrorHandler.shouldRecover(from: error) {
                    Button("Recover") {
                        onRecover()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    // Phase 13.1: Show recovery action if available
                    if let recoveryAction = ExtensionUtils.ExtensionErrorHandler.recoveryAction(for: error) {
                        Text("Suggested Action: \(recoveryAction)")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
    }
}

@available(macOS 15.4, *)
struct ExtensionErrorBadge: View {
    let errorCount: Int
    
    var body: some View {
        if errorCount > 0 {
            Text("\(errorCount)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.red)
                .clipShape(Capsule())
        }
    }
}

