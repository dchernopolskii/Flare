//
//  JobBoardsView.swift
//  MSJobMonitor
//
//  Created by mediaserver on 10/9/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct JobBoardsView: View {
    @StateObject private var monitor = JobBoardMonitor.shared
    @EnvironmentObject var jobManager: JobManager
    @State private var newBoardName = ""
    @State private var newBoardURL = ""
    @State private var testingBoardId: UUID?
    @State private var showImportDialog = false
    @State private var showExportDialog = false
    @State private var importResult: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            Text("Job Boards")
                .font(.title2)
                .fontWeight(.semibold)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Import/Export Section
                    ImportExportSection(
                        showImportDialog: $showImportDialog,
                        showExportDialog: $showExportDialog,
                        importResult: $importResult
                    )
                    
                    // Add Board Section
                    AddBoardSection(
                        newBoardName: $newBoardName,
                        newBoardURL: $newBoardURL,
                        testingBoardId: $testingBoardId
                    )
                    
                    // Configured Boards List
                    if !monitor.boardConfigs.isEmpty {
                        ConfiguredBoardsSection(testingBoardId: $testingBoardId)
                    } else {
                        EmptyBoardsView()
                    }
                    
                    // Supported Platforms Info
                    SupportedPlatformsSection()
                }
                .padding()
            }
        }
        .padding()
        .fileImporter(
            isPresented: $showImportDialog,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        .fileExporter(
            isPresented: $showExportDialog,
            document: JobBoardsDocument(content: monitor.exportBoards()),
            contentType: .plainText,
            defaultFilename: "job-boards-export.txt"
        ) { result in
            switch result {
            case .success:
                importResult = "✅ Exported successfully!"
            case .failure(let error):
                importResult = "❌ Export failed: \(error.localizedDescription)"
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                importResult = nil
            }
        }
    }
    
    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let result = monitor.importBoards(from: content)
                
                if result.failed.isEmpty {
                    importResult = "✅ Imported \(result.added) boards successfully!"
                } else {
                    importResult = "⚠️ Imported \(result.added) boards, \(result.failed.count) failed"
                }
            } catch {
                importResult = "❌ Import failed: \(error.localizedDescription)"
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                importResult = nil
            }
            
        case .failure(let error):
            importResult = "❌ Import failed: \(error.localizedDescription)"
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                importResult = nil
            }
        }
    }
}

// MARK: - Import/Export Section

struct ImportExportSection: View {
    @StateObject private var monitor = JobBoardMonitor.shared
    @Binding var showImportDialog: Bool
    @Binding var showExportDialog: Bool
    @Binding var importResult: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import / Export", systemImage: "arrow.up.arrow.down.circle")
                .font(.headline)
            
            HStack(spacing: 12) {
                Button(action: { showImportDialog = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import from File")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                
                Button(action: { showExportDialog = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export to File")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(monitor.boardConfigs.isEmpty)
            }
            
            if let result = importResult {
                HStack {
                    Text(result)
                        .font(.callout)
                        .foregroundColor(result.hasPrefix("✅") ? .green : result.hasPrefix("⚠️") ? .orange : .red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(result.hasPrefix("✅") ? Color.green.opacity(0.1) : 
                              result.hasPrefix("⚠️") ? Color.orange.opacity(0.1) : 
                              Color.red.opacity(0.1))
                )
            }
            
            Text("Export format: URL | Name | Enabled")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Add Board Section (reused from JobBoardConfigSheet)

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
            
            TextField("Board Name (e.g., GitLab, Stripe)", text: $newBoardName)
                .textFieldStyle(.roundedBorder)
            
            VStack(alignment: .leading, spacing: 4) {
                TextField("Board URL (job listing page)", text: $newBoardURL)
                    .textFieldStyle(.roundedBorder)
                
                if !newBoardURL.isEmpty {
                    SourceDetectionBadge(source: detectedSource)
                }
            }
            
            Text("Currently supported: Greenhouse, Ashbyhq, Lever, Workday • Coming soon: Workable, Jobvite, and more")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Button("Add & Test Board") {
                    addBoard()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidBoard || testingBoardId != nil)
                
                if testingBoardId != nil {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Testing the board...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if !monitor.testResults.isEmpty {
                TestResultsView()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func addBoard() {
        guard isValidBoard,
              let config = JobBoardConfig(
                name: newBoardName.isEmpty ? "" : newBoardName,
                url: newBoardURL
              ) else { return }
        
        monitor.addBoardConfig(config)
        
        testingBoardId = config.id
        Task {
            await monitor.testSingleBoard(config)
            await MainActor.run {
                testingBoardId = nil
            }
        }
        
        newBoardName = ""
        newBoardURL = ""
    }
}

struct TestResultsView: View {
    @StateObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
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

// MARK: - Configured Boards Section

struct ConfiguredBoardsSection: View {
    @Binding var testingBoardId: UUID?
    @StateObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Configured Boards (\(monitor.boardConfigs.count))", systemImage: "list.bullet")
                    .font(.headline)
                
                Spacer()
                
                Text("\(monitor.boardConfigs.filter { $0.isEnabled }.count) enabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ForEach(monitor.boardConfigs) { config in
                BoardConfigRow(config: config, testingBoardId: $testingBoardId)
            }
        }
    }
}

// MARK: - Empty State

struct EmptyBoardsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Job Boards Configured")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Add job boards above to monitor additional companies")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Supported Platforms Section

struct SupportedPlatformsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Platform Support", systemImage: "info.circle")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(JobSource.allCases, id: \.self) { source in
                    if source != .microsoft && source != .tiktok && source != .snap && source != .amd {
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

// MARK: - File Document for Export

struct JobBoardsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    
    var content: String
    
    init(content: String) {
        self.content = content
    }
    
    init(configuration: ReadConfiguration) throws {
        content = ""
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8)!
        return FileWrapper(regularFileWithContents: data)
    }
}
