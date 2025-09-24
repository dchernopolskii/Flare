//
//  JobBoardMonitor.swift
//  MSJobMonitor
//
//
//
//

import SwiftUI
import Foundation

// MARK: - Job Source Enum
enum JobSource: String, Codable, CaseIterable {
    case microsoft = "Microsoft"
    case greenhouse = "Greenhouse"
    case workable = "Workable"
    case jobvite = "Jobvite"
    case lever = "Lever"
    case bamboohr = "BambooHR"
    case smartrecruiters = "SmartRecruiters"
    case ashby = "Ashby"
    case jazzhr = "JazzHR"
    case recruitee = "Recruitee"
    case breezyhr = "Breezy HR"
    
    var icon: String {
        switch self {
        case .microsoft: return "building.2.fill"
        case .greenhouse: return "leaf.fill"
        case .workable: return "briefcase.circle.fill"
        case .jobvite: return "person.3.fill"
        case .lever: return "lever.horizontal.3"
        case .bamboohr: return "bamboo"
        case .smartrecruiters: return "brain.head.profile"
        case .ashby: return "person.crop.circle.badge.plus"
        case .jazzhr: return "music.note"
        case .recruitee: return "person.2.badge.plus"
        case .breezyhr: return "wind"
        }
    }
    
    var color: Color {
        switch self {
        case .microsoft: return .blue
        case .greenhouse: return .green
        case .workable: return .purple
        case .jobvite: return .orange
        case .lever: return .pink
        case .bamboohr: return .brown
        case .smartrecruiters: return .indigo
        case .ashby: return .teal
        case .jazzhr: return .yellow
        case .recruitee: return .cyan
        case .breezyhr: return .mint
        }
    }
    
    static func detectFromURL(_ urlString: String) -> JobSource? {
        let lowercased = urlString.lowercased()
        
        if lowercased.contains("greenhouse.io") || lowercased.contains("boards.greenhouse.io") {
            return .greenhouse
        } else if lowercased.contains("workable.com") {
            return .workable
        } else if lowercased.contains("jobvite.com") {
            return .jobvite
        } else if lowercased.contains("lever.co") {
            return .lever
        } else if lowercased.contains("bamboohr.com") {
            return .bamboohr
        } else if lowercased.contains("smartrecruiters.com") {
            return .smartrecruiters
        } else if lowercased.contains("ashbyhq.com") {
            return .ashby
        } else if lowercased.contains("jazz.co") || lowercased.contains("jazzhr.com") {
            return .jazzhr
        } else if lowercased.contains("recruitee.com") {
            return .recruitee
        } else if lowercased.contains("breezy.hr") {
            return .breezyhr
        } else {
            return nil
        }
    }
    
    var isSupported: Bool {
        return self == .greenhouse
    }
}

// MARK: - Updated Job Model Extension
extension Job {
    var source: JobSource {
        if id.hasPrefix("microsoft-") { return .microsoft }
        else if id.hasPrefix("gh-") { return .greenhouse }
        else if id.hasPrefix("wk-") { return .workable }
        else if id.hasPrefix("jv-") { return .jobvite }
        else if id.hasPrefix("lv-") { return .lever }
        else if id.hasPrefix("bh-") { return .bamboohr }
        else if id.hasPrefix("sr-") { return .smartrecruiters }
        else if id.hasPrefix("ashby-") { return .ashby }
        else if id.hasPrefix("jazz-") { return .jazzhr }
        else if id.hasPrefix("recruitee-") { return .recruitee }
        else if id.hasPrefix("breezy-") { return .breezyhr }
        else {
            print("Warning: Unknown job ID format: \(id)")
            return .microsoft
        }
    }
    
    var applyButtonText: String {
        switch source {
        case .microsoft:
            return "Apply on Microsoft Careers"
        case .greenhouse, .workable, .jobvite, .lever, .bamboohr, .smartrecruiters, .ashby, .jazzhr, .recruitee, .breezyhr:
            return "Apply on Company Website"
        }
    }
}

// MARK: - Job Board Configuration
struct JobBoardConfig: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var source: JobSource
    var isEnabled: Bool = true
    var lastFetched: Date?
    
    var displayName: String {
        if name.isEmpty {
            return "\(source.rawValue) Board"
        }
        return name
    }
    
    var isSupported: Bool {
        return source.isSupported
    }
    
    init?(name: String, url: String, isEnabled: Bool = true) {
        guard let detectedSource = JobSource.detectFromURL(url) else {
            return nil // Unsupported platform
        }
        
        self.name = name
        self.url = url
        self.source = detectedSource
        self.isEnabled = isEnabled
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        source = try container.decode(JobSource.self, forKey: .source)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastFetched = try container.decodeIfPresent(Date.self, forKey: .lastFetched)
    }
}

// MARK: - Job Board Monitor
@MainActor
class JobBoardMonitor: ObservableObject {
    static let shared = JobBoardMonitor()
    
    @Published var boardConfigs: [JobBoardConfig] = []
    @Published var isMonitoring = false
    @Published var lastError: String?
    @Published var showConfigSheet = false
    @Published var testResults: [UUID: String] = [:] // Board ID -> result message
    
    @AppStorage("jobBoardConfigs") private var savedConfigsData = Data()
    
    private init() {
        loadConfigs()
    }
    
    func loadConfigs() {
        if let configs = try? JSONDecoder().decode([JobBoardConfig].self, from: savedConfigsData) {
            boardConfigs = configs
        }
    }
    
    func saveConfigs() {
        if let data = try? JSONEncoder().encode(boardConfigs) {
            savedConfigsData = data
        }
    }
    
    func addBoardConfig(_ config: JobBoardConfig) {
        boardConfigs.append(config)
        saveConfigs()
    }
    
    func removeBoardConfig(at index: Int) {
        boardConfigs.remove(at: index)
        saveConfigs()
    }
    
    func updateBoardConfig(_ config: JobBoardConfig) {
        if let index = boardConfigs.firstIndex(where: { $0.id == config.id }) {
            boardConfigs[index] = config
            saveConfigs()
        }
    }
    
    // Test a single job board
    func testSingleBoard(_ config: JobBoardConfig) async {
        testResults[config.id] = "Testing..."
        
        do {
            let jobs = try await fetchJobsFromBoard(config, titleFilter: "", locationFilter: "")
            let message = "✅ Found \(jobs.count) jobs"
            testResults[config.id] = message
            
            // Update last fetched time
            var updatedConfig = config
            updatedConfig.lastFetched = Date()
            updateBoardConfig(updatedConfig)
            
            print("✅ Test successful for \(config.displayName): \(jobs.count) jobs found")
            
        } catch {
            let message = "❌ Error: \(error.localizedDescription)"
            testResults[config.id] = message
            print("❌ Test failed for \(config.displayName): \(error)")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.testResults.removeValue(forKey: config.id)
        }
    }
    
    func fetchAllBoardJobs(titleFilter: String = "", locationFilter: String = "") async -> [Job] {
        isMonitoring = true
        lastError = nil
        var allJobs: [Job] = []
        
        for config in boardConfigs where config.isEnabled {
            do {
                let jobs = try await fetchJobsFromBoard(config, titleFilter: titleFilter, locationFilter: locationFilter)
                allJobs.append(contentsOf: jobs)
                
                var updatedConfig = config
                updatedConfig.lastFetched = Date()
                updateBoardConfig(updatedConfig)
                
            } catch {
                print("Error fetching from \(config.displayName): \(error)")
                lastError = "Failed to fetch from \(config.displayName): \(error.localizedDescription)"
            }
            
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        isMonitoring = false
        return allJobs
    }
    
    private func fetchJobsFromBoard(_ config: JobBoardConfig, titleFilter: String, locationFilter: String) async throws -> [Job] {
        guard let url = URL(string: config.url) else {
            throw FetchError.invalidURL
        }
        
        let fetcher = JobBoardFetcher()
        
        switch config.source {
        case .greenhouse:
            return try await fetcher.fetchGreenhouseJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case .workable, .jobvite, .lever, .bamboohr, .smartrecruiters, .ashby, .jazzhr, .recruitee, .breezyhr:
            // TODO: Implement these platforms
            throw FetchError.notImplemented(config.source.rawValue)
        default:
            return []
        }
    }
}

// MARK: - Job Board Fetcher
actor JobBoardFetcher {
    
    // MARK: - Greenhouse Fetcher
    func fetchGreenhouseJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let boardSlug = extractGreenhouseBoardSlug(from: url)
        
        let apiURL = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(boardSlug)/jobs?content=true")!
        print("🌱 [Greenhouse] Fetching API: \(apiURL)")
        
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            print("🌱 [Greenhouse] HTTP Error: Status code \(httpResponse.statusCode)")
            if let errorString = String(data: data, encoding: .utf8) {
                print("🌱 [Greenhouse] Error response: \(errorString.prefix(500))")
            }
            throw FetchError.invalidResponse
        }
        
        struct GreenhouseResponse: Codable {
            let jobs: [GreenhouseJob]
        }
        
        struct GreenhouseJob: Codable {
            let id: Int
            let title: String
            let absolute_url: String
            let location: GreenhouseLocation?
            let updated_at: String?
            let content: String?
            let departments: [GreenhouseDepartment]?
            
            struct GreenhouseLocation: Codable {
                let name: String
            }
            
            struct GreenhouseDepartment: Codable {
                let name: String
            }
        }
        
        do {
            let decoded = try JSONDecoder().decode(GreenhouseResponse.self, from: data)
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]
            
            var jobs = decoded.jobs.compactMap { ghJob -> Job? in
                var postingDate = Date()
                if let dateString = ghJob.updated_at {
                    postingDate = formatter.date(from: dateString)
                               ?? fallbackFormatter.date(from: dateString)
                               ?? Date()
                }
                
                let location = ghJob.location?.name ?? "Location not specified"
                let title = ghJob.title
                
                // Apply filters
                if !titleFilter.isEmpty {
                    let titleMatches = title.lowercased().contains(titleFilter.lowercased())
                    if !titleMatches { return nil }
                }
                
                if !locationFilter.isEmpty {
                    let locationMatches = location.lowercased().contains(locationFilter.lowercased())
                    if !locationMatches { return nil }
                }
                
                let cleanDescription = cleanHTMLContent(ghJob.content ?? "")
                
                return Job(
                    id: "gh-\(ghJob.id)",
                    title: title,
                    location: location,
                    postingDate: postingDate,
                    url: ghJob.absolute_url,
                    description: cleanDescription,
                    workSiteFlexibility: extractWorkFlexibility(from: cleanDescription)
                )
            }
            
            print("🌱 [Greenhouse] Parsed \(jobs.count) jobs from API")
            return jobs
            
        } catch {
            print("🌱 [Greenhouse] JSON Parsing Error: \(error)")
            throw FetchError.parsingFailed
        }
    }
    
    private func extractGreenhouseBoardSlug(from url: URL) -> String {
        // Handle different Greenhouse URLs:
        // https://boards.greenhouse.io/gitlab
        // https://job-boards.greenhouse.io/gitlab/jobs
        // https://gitlab.greenhouse.io/jobs
        
        let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        
        if url.host?.contains("boards.greenhouse.io") == true ||
           url.host?.contains("job-boards.greenhouse.io") == true {
            return pathComponents.first ?? "unknown"
        } else if url.host?.hasSuffix("greenhouse.io") == true {
            if let host = url.host,
               let companyName = host.components(separatedBy: ".").first {
                return companyName
            }
        }
        
        return pathComponents.first ?? "unknown"
    }
    
    // MARK: - Placeholder Methods (TODO: Implement)
    
    func fetchWorkableJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("Workable")
    }
    
    func fetchJobviteJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("Jobvite")
    }
    
    func fetchLeverJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("Lever")
    }
    
    func fetchBambooHRJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("BambooHR")
    }
    
    func fetchSmartRecruitersJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("SmartRecruiters")
    }
    
    func fetchAshbyJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("Ashby")
    }
    
    func fetchJazzHRJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("JazzHR")
    }
    
    func fetchRecruiteeJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("Recruitee")
    }
    
    func fetchBreezyHRJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        // TODO
        throw FetchError.notImplemented("Breezy HR")
    }
    
    // MARK: - Helper Methods
    private func cleanHTMLContent(_ html: String) -> String {
        let decoded = html
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
        
        var text = decoded
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "<p>", with: "")
            .replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "<div>", with: "")
            .replacingOccurrences(of: "<li>", with: "• ")
            .replacingOccurrences(of: "</li>", with: "\n")
            .replacingOccurrences(of: "<ul>", with: "\n")
            .replacingOccurrences(of: "</ul>", with: "\n")
            .replacingOccurrences(of: "<ol>", with: "\n")
            .replacingOccurrences(of: "</ol>", with: "\n")
        
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        
        let lines = text.components(separatedBy: .newlines)
        let cleanedLines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        var result: [String] = []
        var previousWasEmpty = false
        
        for line in cleanedLines {
            if line.isEmpty {
                if !previousWasEmpty && !result.isEmpty {
                    result.append("")
                }
                previousWasEmpty = true
            } else {
                result.append(line)
                previousWasEmpty = false
            }
        }
        
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractWorkFlexibility(from description: String) -> String? {
        let flexibilityKeywords = ["remote", "hybrid", "flexible", "work from home", "onsite", "on-site"]
        let lowercased = description.lowercased()
        
        for keyword in flexibilityKeywords {
            if lowercased.contains(keyword) {
                return keyword.capitalized
            }
        }
        
        return nil
    }
}

// MARK: - Configuration Sheet
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
            HStack {
                Text("Configure Job Boards")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    // Add new board
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Add Job Board", systemImage: "plus.circle.fill")
                            .font(.headline)
                        
                        TextField("Board Name (e.g., GitLab, Stripe)", text: $newBoardName)
                            .textFieldStyle(.roundedBorder)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Board URL (job listing page)", text: $newBoardURL)
                                .textFieldStyle(.roundedBorder)
                            
                            if !newBoardURL.isEmpty {
                                if let detectedSource = JobSource.detectFromURL(newBoardURL) {
                                    HStack {
                                        Image(systemName: detectedSource.icon)
                                            .foregroundColor(detectedSource.color)
                                        if detectedSource.isSupported {
                                            Text("Detected: \(detectedSource.rawValue)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.caption)
                                        } else {
                                            Text("Detected: \(detectedSource.rawValue) (Coming Soon)")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                            Image(systemName: "clock.circle.fill")
                                                .foregroundColor(.orange)
                                                .font(.caption)
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                } else {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.red)
                                        Text("Unsupported platform")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                    .padding(.horizontal, 4)
                                }
                            }
                        }
                        
                        Text("Currently supported: Greenhouse • Coming soon: Workable, Lever, Jobvite, and more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Button("Add Board") {
                                if !newBoardURL.isEmpty,
                                   let config = JobBoardConfig(name: newBoardName.isEmpty ? "" : newBoardName, url: newBoardURL) {
                                    monitor.addBoardConfig(config)
                                    newBoardName = ""
                                    newBoardURL = ""
                                    
                                    // fetch jobs after adding new board
                                    Task {
                                        await jobManager.fetchJobsWithBoards()
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newBoardURL.isEmpty || JobSource.detectFromURL(newBoardURL) == nil)
                            
                            Button("Add & Test") {
                                if !newBoardURL.isEmpty,
                                   let config = JobBoardConfig(name: newBoardName.isEmpty ? "" : newBoardName, url: newBoardURL) {
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
                            .buttonStyle(.bordered)
                            .disabled(newBoardURL.isEmpty || JobSource.detectFromURL(newBoardURL) == nil || testingBoardId != nil)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    
                    // Configured boards
                    if !monitor.boardConfigs.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Configured Boards", systemImage: "list.bullet")
                                .font(.headline)
                            
                            ForEach(monitor.boardConfigs) { config in
                                HStack {
                                    Image(systemName: config.source.icon)
                                        .foregroundColor(config.source.color)
                                        .frame(width: 30)
                                    
                                    VStack(alignment: .leading) {
                                        HStack {
                                            Text(config.displayName)
                                                .font(.headline)
                                            if !config.isSupported {
                                                Text("(Coming Soon)")
                                                    .font(.caption2)
                                                    .foregroundColor(.orange)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Color.orange.opacity(0.2))
                                                    .cornerRadius(3)
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
                                            
                                            // Show test result if available
                                            if let testResult = monitor.testResults[config.id] {
                                                Text(testResult)
                                                    .font(.caption2)
                                                    .foregroundColor(testResult.hasPrefix("✅") ? .green : .red)
                                            }
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        testingBoardId = config.id
                                        Task {
                                            await monitor.testSingleBoard(config)
                                            await MainActor.run {
                                                testingBoardId = nil
                                            }
                                        }
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
                                    
                                    Button(action: {
                                        if let index = monitor.boardConfigs.firstIndex(where: { $0.id == config.id }) {
                                            monitor.removeBoardConfig(at: index)
                                        }
                                    }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding()
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                                .opacity(config.isSupported ? 1.0 : 0.6)
                            }
                        }
                    }
                }
                .padding()
            }
            
            Divider()
            
            HStack {
                if let error = monitor.lastError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
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
        .frame(width: 650, height: 550)
    }
}

// MARK: - Error Types
enum FetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case parsingFailed
    case notImplemented(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Failed to fetch job listings"
        case .parsingFailed:
            return "Failed to parse job data"
        case .notImplemented(let platform):
            return "\(platform) integration coming soon"
        }
    }
}

// MARK: - Integration with JobManager
extension JobManager {
    func fetchJobsWithBoards() async {
        isLoading = true
        lastError = nil
        newJobsCount = 0
        
        async let microsoftJobs: Void = fetchJobs()
        
        // Fetch from configured job boards with filters
        let boardMonitor = JobBoardMonitor.shared
        async let boardJobs = boardMonitor.fetchAllBoardJobs(
            titleFilter: jobTitleFilter,
            locationFilter: locationFilter
        )
        
        // Wait for both to complete
        _ = await microsoftJobs
        let fetchedBoardJobs = await boardJobs
        
        // Filter board jobs for 24-hour window
        let recentBoardJobs = fetchedBoardJobs.filter { $0.isWithin24Hours }
        
        // Check for new jobs from boards
        var newBoardJobs: [Job] = []
        for job in recentBoardJobs {
            if !storedJobIds.contains(job.id) {
                newBoardJobs.append(job)
                storedJobIds.insert(job.id)
            }
        }
        
        jobs.append(contentsOf: recentBoardJobs)
        
        var uniqueJobs: [Job] = []
        var seenIds = Set<String>()
        
        for job in jobs.sorted(by: { $0.postingDate > $1.postingDate }) {
            if !seenIds.contains(job.id) {
                uniqueJobs.append(job)
                seenIds.insert(job.id)
            }
        }
        
        jobs = uniqueJobs
        
        if !newBoardJobs.isEmpty {
            sendGroupedNotification(for: newBoardJobs)
            newJobsCount += newBoardJobs.count
        }
        
        let totalBoardJobs = fetchedBoardJobs.count
        let recentBoardCount = recentBoardJobs.count
        
        print("📊 Board Job Summary:")
        print("  - Total fetched from boards: \(totalBoardJobs)")
        print("  - Recent (24h) from boards: \(recentBoardCount)")
        print("  - New notifications sent: \(newBoardJobs.count)")
        
        saveJobs()
        saveStoredJobIds()
        
        isLoading = false
    }
}

// MARK: - Configure Job Boards Button
struct ConfigureJobBoardsButton: View {
    @State private var showConfigSheet = false
    
    var body: some View {
        Button(action: {
            showConfigSheet = true
        }) {
            Label("Job Boards", systemImage: "gear")
        }
        .sheet(isPresented: $showConfigSheet) {
            JobBoardConfigSheet()
        }
    }
}
