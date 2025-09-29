//
//  JobBoardConfigSheet.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI

struct JobBoardConfigSheet: View {
    @StateObject private var monitor = JobBoardMonitor.shared
    @EnvironmentObject var jobManager: JobManager
    @State private var newBoardName = ""
    @State private var newBoardURL = ""
    @State private var testingBoardId: UUID?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            SheetHeader(title: "Configure Job Boards") {
                dismiss()
            }
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    // Add New Board Section
                    AddBoardSection(
                        newBoardName: $newBoardName,
                        newBoardURL: $newBoardURL,
                        testingBoardId: $testingBoardId
                    )
                    
                    // Configured Boards List
                    if !monitor.boardConfigs.isEmpty {
                        ConfiguredBoardsList(testingBoardId: $testingBoardId)
                    }
                    
                    // Supported Platforms Info
                    SupportedPlatformsInfo()
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            SheetFooter(dismiss: { dismiss() })
        }
        .frame(width: 650, height: 550)
    }
}

struct SheetHeader: View {
    let title: String
    let onClose: () -> Void
    
    var body: some View {
        HStack {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

struct AddBoardSection: View {
    @Binding var newBoardName: String
    @Binding var newBoardURL: String
    @Binding var testingBoardId: UUID?
    @StateObject private var monitor = JobBoardMonitor.shared
    @EnvironmentObject var jobManager: JobManager
    
    private var detectedSource: JobSource? {
        JobSource.detectFromURL(newBoardURL)
    }
    
    private var isValidBoard: Bool {
        !newBoardURL.isEmpty && detectedSource != nil && (detectedSource?.isSupported ?? false)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add Job Board", systemImage: "plus.circle.fill")
                .font(.headline)
            
            // Name Field
            TextField("Board Name (e.g., GitLab, Stripe)", text: $newBoardName)
                .textFieldStyle(.roundedBorder)
            
            // URL Field with Detection
            VStack(alignment: .leading, spacing: 4) {
                TextField("Board URL (job listing page)", text: $newBoardURL)
                    .textFieldStyle(.roundedBorder)
                
                if !newBoardURL.isEmpty {
                    SourceDetectionBadge(source: detectedSource)
                }
            }
            
            // Helper Text
            Text("Currently supported: Greenhouse • Coming soon: Workable, Lever, Jobvite, and more")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Button("Add & Test Board") {
                    addBoard(andTest: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidBoard || testingBoardId != nil)
                
                // Show loading state
                if testingBoardId != nil {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Testing board...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Show test results more prominently
            if !monitor.testResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Recent Test Results", systemImage: "checkmark.circle")
                        .font(.headline)
                    
                    ForEach(Array(monitor.testResults.keys), id: \.self) { boardId in
                        if let result = monitor.testResults[boardId],
                           let boardName = monitor.boardConfigs.first(where: { $0.id == boardId })?.displayName {
                            HStack {
                                Text(boardName)
                                    .font(.callout)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(result)
                                    .font(.callout)
                                    .foregroundColor(result.hasPrefix("✅") ? .green : .red)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(4)
                        }
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }
    
    private func addBoard(andTest: Bool) {
        guard isValidBoard,
              let config = JobBoardConfig(
                name: newBoardName.isEmpty ? "" : newBoardName,
                url: newBoardURL
              ) else { return }
        
        monitor.addBoardConfig(config)
        
        // Always test the board when adding it
        testingBoardId = config.id
        Task {
            await monitor.testSingleBoard(config)
            await MainActor.run {
                testingBoardId = nil
            }
        }
        
        // Clear fields
        newBoardName = ""
        newBoardURL = ""
    }
}

struct SourceDetectionBadge: View {
    let source: JobSource?
    
    var body: some View {
        HStack {
            if let source = source {
                Image(systemName: source.icon)
                    .foregroundColor(source.color)
                if source.isSupported {
                    Text("Detected: \(source.rawValue)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Text("Detected: \(source.rawValue) (Coming Soon)")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Image(systemName: "clock.circle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Unsupported platform")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct ConfiguredBoardsList: View {
    @Binding var testingBoardId: UUID?
    @StateObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Configured Boards", systemImage: "list.bullet")
                .font(.headline)
            
            ForEach(monitor.boardConfigs) { config in
                BoardConfigRow(config: config, testingBoardId: $testingBoardId)
            }
        }
    }
}

struct BoardConfigRow: View {
    let config: JobBoardConfig
    @Binding var testingBoardId: UUID?
    @StateObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        HStack {
            // Icon and Info
            Image(systemName: config.source.icon)
                .foregroundColor(config.source.color)
                .frame(width: 30)
            
            VStack(alignment: .leading) {
                HStack {
                    Text(config.displayName)
                        .font(.headline)
                    if !config.isSupported {
                        Badge(text: "Coming Soon", color: .orange)
                    }
                }
                
                Text(config.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                HStack {
                    Text(config.source.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(config.source.color.opacity(0.2))
                        .cornerRadius(4)
                    
                    if let lastFetched = config.lastFetched {
                        Text("Last: \(lastFetched, style: .relative)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Test result
                    if let testResult = monitor.testResults[config.id] {
                        HStack {
                            if testResult == "Testing..." {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else if testResult.hasPrefix("✅") {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            }
                            
                            Text(testResult.replacingOccurrences(of: "✅ ", with: "").replacingOccurrences(of: "❌ ", with: ""))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(testResult.hasPrefix("✅") ? .green : testResult == "Testing..." ? .blue : .red)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(testResult.hasPrefix("✅") ? Color.green.opacity(0.1) :
                                      testResult == "Testing..." ? Color.blue.opacity(0.1) :
                                      Color.red.opacity(0.1))
                        )
                    }
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                // Test Button
                Button(action: {
                    testBoard()
                }) {
                    if testingBoardId == config.id {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: config.isSupported ? "play.circle" : "clock.circle")
                            .foregroundColor(config.isSupported ? .blue : .orange)
                    }
                }
                .buttonStyle(.plain)
                .help(config.isSupported ? "Test this job board" : "Coming soon")
                .disabled(!config.isSupported || testingBoardId != nil)
                
                // Enable Toggle
                Toggle("", isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in
                        var updatedConfig = config
                        updatedConfig.isEnabled = newValue
                        monitor.updateBoardConfig(updatedConfig)
                    }
                ))
                .toggleStyle(.switch)
                .disabled(!config.isSupported)
                
                // Delete Button
                Button(action: {
                    deleteBoard()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .opacity(config.isSupported ? 1.0 : 0.6)
    }
    
    private func testBoard() {
        testingBoardId = config.id
        Task {
            await monitor.testSingleBoard(config)
            await MainActor.run {
                testingBoardId = nil
            }
        }
    }
    
    private func deleteBoard() {
        if let index = monitor.boardConfigs.firstIndex(where: { $0.id == config.id }) {
            monitor.removeBoardConfig(at: index)
        }
    }
}

struct SupportedPlatformsInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Platform Support", systemImage: "info.circle")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(JobSource.allCases, id: \.self) { source in
                    if source != .microsoft && source != .tiktok {
                        HStack {
                            Image(systemName: source.icon)
                                .foregroundColor(source.color)
                                .frame(width: 20)
                            Text(source.rawValue)
                            Spacer()
                            if source.isSupported {
                                Label("Supported", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else {
                                Label("Coming Soon", systemImage: "clock.circle")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        }
    }
}

struct SheetFooter: View {
    let dismiss: () -> Void
    @StateObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        HStack {
            if let error = monitor.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
            }
            
            Spacer()
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
        }
        .padding()
    }
}
