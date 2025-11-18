//
//  ExtensionDataManagementView.swift
//  Nook
//
//  Phase 4.3: Extension Data Management UI
//

import SwiftUI
import WebKit

@available(macOS 15.4, *)
struct ExtensionDataManagementView: View {
    @State private var dataRecords: [WKWebExtension.DataRecord] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedExtensionId: String?
    @State private var selectedDataTypes: Set<WKWebExtension.DataType> = []
    @State private var searchText: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Extension Data Management")
                    .font(.headline)
                Spacer()
                Button(action: refreshData) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            
            // Search and filter controls
            HStack {
                TextField("Search extensions...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                
                Menu("Filter by Data Type") {
                    Button("All Types") {
                        selectedDataTypes = []
                    }
                    Divider()
                    ForEach([WKWebExtension.DataType.local, .session, .synchronized], id: \.self) { type in
                        Button(action: {
                            if selectedDataTypes.contains(type) {
                                selectedDataTypes.remove(type)
                            } else {
                                selectedDataTypes.insert(type)
                            }
                        }) {
                            HStack {
                                Text(dataTypeDescription(type))
                                if selectedDataTypes.contains(type) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if let errorMessage = errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            } else if filteredRecords.isEmpty {
                Text("No extension data found")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List(filteredRecords, id: \.uniqueIdentifier) { record in
                    ExtensionDataRecordRow(record: record)
                }
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            refreshData()
        }
    }
    
    private var filteredRecords: [WKWebExtension.DataRecord] {
        var records = dataRecords
        
        // Filter by search text
        if !searchText.isEmpty {
            records = records.filter { record in
                record.displayName.localizedCaseInsensitiveContains(searchText) ||
                record.uniqueIdentifier.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Filter by selected data types
        if !selectedDataTypes.isEmpty {
            records = records.filter { record in
                !record.containedDataTypes.isDisjoint(with: selectedDataTypes)
            }
        }
        
        return records
    }
    
    private func refreshData() {
        isLoading = true
        errorMessage = nil
        
        // Use the enhanced method with optional data types filter
        let typesToFetch: Set<WKWebExtension.DataType>? = selectedDataTypes.isEmpty ? nil : selectedDataTypes
        
        // Explicitly specify the closure type to resolve method ambiguity
        ExtensionManager.shared.fetchExtensionDataRecords(ofTypes: typesToFetch) { (records: [WKWebExtension.DataRecord]?, error: Error?) in
            DispatchQueue.main.async {
                isLoading = false
                if let error = error {
                    errorMessage = error.localizedDescription
                } else {
                    dataRecords = records ?? []
                }
            }
        }
    }
    
    private func dataTypeDescription(_ type: WKWebExtension.DataType) -> String {
        switch type {
        case .local:
            return "Local Storage"
        case .session:
            return "Session Storage"
        case .synchronized:
            return "Synchronized Storage"
        default:
            return "Unknown"
        }
    }
}

@available(macOS 15.4, *)
struct ExtensionDataRecordRow: View {
    let record: WKWebExtension.DataRecord
    @State private var isExpanded = false
    @State private var isDeleting = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayName)
                        .font(.headline)
                    Text(record.uniqueIdentifier)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Extension info
                    HStack {
                        Text("Display Name:")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(record.displayName)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Extension ID:")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(record.uniqueIdentifier)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Data types
                    if !record.containedDataTypes.isEmpty {
                        Text("Data Types:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(Array(record.containedDataTypes.sorted(by: { dataTypeDescription($0) < dataTypeDescription($1) })), id: \.self) { dataType in
                            HStack {
                                Text(dataTypeDescription(dataType))
                                Spacer()
                                Text(formatBytes(Int64(record.sizeInBytes(ofTypes: [dataType]))))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading)
                        }
                    }
                    
                    // Total size
                    Divider()
                    HStack {
                        Text("Total Size:")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(formatBytes(Int64(record.totalSizeInBytes)))
                            .foregroundColor(.secondary)
                    }
                    
                    // Errors
                    if !record.errors.isEmpty {
                        Divider()
                        Text("Errors:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.red)
                        ForEach(record.errors, id: \.localizedDescription) { error in
                            Text(error.localizedDescription)
                                .foregroundColor(.red)
                                .padding(.leading)
                        }
                    }
                    
                    // Delete button
                    Divider()
                    Button(action: deleteData) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete All Data")
                        }
                        .foregroundColor(.red)
                    }
                    .disabled(isDeleting)
                    if isDeleting {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .padding(.leading)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func dataTypeDescription(_ type: WKWebExtension.DataType) -> String {
        switch type {
        case .local:
            return "Local Storage"
        case .session:
            return "Session Storage"
        case .synchronized:
            return "Synchronized Storage"
        default:
            return "Unknown"
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func deleteData() {
        isDeleting = true
        let allTypes: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
        
        // Extract extension ID from record if possible
        // Note: WKWebExtension.DataRecord doesn't directly expose extension ID,
        // so we'll need to find it by matching uniqueIdentifier
        let extensionId = ExtensionManager.shared.getExtensionId(for: record.uniqueIdentifier)
        
        let completionHandler: (Error?) -> Void = { (error: Error?) in
            DispatchQueue.main.async {
                isDeleting = false
                if let error = error {
                    print("Failed to delete extension data: \(error.localizedDescription)")
                } else {
                    // Refresh the view
                    NotificationCenter.default.post(name: NSNotification.Name("ExtensionDataDeleted"), object: nil)
                }
            }
        }
        ExtensionManager.shared.removeExtensionData(ofTypes: allTypes, from: extensionId, completionHandler: completionHandler)
    }
}
