import SwiftUI
import UserNotifications
import AppKit

// MARK: - Main App
@main
struct MicrosoftJobMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var jobManager = JobManager.shared
    @AppStorage("isFirstLaunch") private var isFirstLaunch = true
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(jobManager)
                .onAppear {
                    if isFirstLaunch {
                        jobManager.showSettings = true
                        isFirstLaunch = false
                    }
                }
                .handlesExternalEvents(preferring: ["job"], allowing: ["job"])
                .onOpenURL { url in
                    // Handle notification clicks
                    if let jobId = url.absoluteString.components(separatedBy: "://").last {
                        jobManager.selectJob(withId: jobId)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Microsoft Job Monitor") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Microsoft Job Monitor",
                            .applicationVersion: "1.0.0"
                        ]
                    )
                }
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        requestNotificationPermission()
        
        UNUserNotificationCenter.current().delegate = self
        
        Task {
            await JobManager.shared.startMonitoring()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "briefcase.fill", accessibilityDescription: "Job Monitor")
            button.action = #selector(togglePopover)
        }
    }
    
    @objc func togglePopover() {
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                print("Notification permission granted")
            }
        }
    }
    
    // Handle notification clicks
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let jobId = userInfo["jobId"] as? String {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
            
            DispatchQueue.main.async {
                JobManager.shared.selectJob(withId: jobId)
            }
        }
        completionHandler()
    }
}

// MARK: - Models
struct Job: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let location: String
    let postingDate: Date
    let url: String
    let description: String
    let workSiteFlexibility: String?
    
    var isWithin24Hours: Bool {
        let hoursSincePosting = Date().timeIntervalSince(postingDate) / 3600
        return hoursSincePosting <= 24 && hoursSincePosting >= 0
    }
    
    var cleanDescription: String {
        // Remove HTML tags but preserve structure
        var text = description
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
        
        // Remove remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#8217;", with: "'")
            .replacingOccurrences(of: "&#8220;", with: """
            )
            .replacingOccurrences(of: "&#8221;", with:
            """)
            .replacingOccurrences(of: "&#8211;", with: "–")
            .replacingOccurrences(of: "&#8212;", with: "—")
        
        let lines = text.components(separatedBy: .newlines)
        let cleanedLines = lines.map { line in
            line.trimmingCharacters(in: .whitespaces)
        }
        
        // Remove empty lines
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
        
        return result.joined(separator: "\n")
    }
    
    var overview: String {
        // Extract the main description before qualifications
        let text = cleanDescription
        
        // Find where qualifications start
        let qualificationMarkers = [
            "Required/Minimum Qualifications",
            "Required Qualifications",
            "Minimum Qualifications",
            "Basic Qualifications",
            "Qualifications"
        ]
        
        var endIndex = text.endIndex
        for marker in qualificationMarkers {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                if range.lowerBound < endIndex {
                    endIndex = range.lowerBound
                }
            }
        }
        
        let overview = String(text[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return overview.isEmpty ? "No description available." : overview
    }
    
    var requiredQualifications: String? {
        let text = cleanDescription
        
        let requiredMarkers = [
            "Required/Minimum Qualifications",
            "Required Qualifications",
            "Minimum Qualifications",
            "Basic Qualifications"
        ]
        
        for marker in requiredMarkers {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let afterMarker = String(text[range.upperBound...])
                
                let endMarkers = [
                    "Preferred Qualifications",
                    "Additional Qualifications",
                    "Preferred/Additional Qualifications",
                    "Microsoft is an equal opportunity employer"
                ]
                
                var endIndex = afterMarker.endIndex
                for endMarker in endMarkers {
                    if let endRange = afterMarker.range(of: endMarker, options: .caseInsensitive) {
                        if endRange.lowerBound < endIndex {
                            endIndex = endRange.lowerBound
                        }
                    }
                }
                
                let qualifications = String(afterMarker[..<endIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                return qualifications.isEmpty ? nil : qualifications
            }
        }
        
        return nil
    }
    
    var preferredQualifications: String? {
        let text = cleanDescription
        
        let preferredMarkers = [
            "Preferred Qualifications",
            "Additional Qualifications",
            "Preferred/Additional Qualifications"
        ]
        
        for marker in preferredMarkers {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let afterMarker = String(text[range.upperBound...])
                
                let endMarkers = [
                    "Microsoft is an equal opportunity employer",
                    "Benefits/perks listed below",
                    "#LI-"
                ]
                
                var endIndex = afterMarker.endIndex
                for endMarker in endMarkers {
                    if let endRange = afterMarker.range(of: endMarker, options: .caseInsensitive) {
                        if endRange.lowerBound < endIndex {
                            endIndex = endRange.lowerBound
                        }
                    }
                }
                
                let qualifications = String(afterMarker[..<endIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                return qualifications.isEmpty ? nil : qualifications
            }
        }
        return nil
    }
}

// MARK: - Job Manager
@MainActor
class JobManager: ObservableObject {
    static let shared = JobManager()
    
    @Published var jobs: [Job] = []
    @Published var isLoading = false
    @Published var loadingProgress = ""
    @Published var showSettings = false
    @Published var lastError: String?
    @Published var selectedJob: Job?
    @Published var selectedTab = "jobs"
    @Published var totalFetchedCount = 0
    @Published var filteredCount = 0
    @Published var totalAvailableJobs = 0
    @Published var newJobsCount = 0
    
    @AppStorage("jobTitleFilter") var jobTitleFilter = ""
    @AppStorage("locationFilter") var locationFilter = ""
    @AppStorage("refreshInterval") var refreshInterval = 30.0 // minutes
    @AppStorage("maxPagesToFetch") var maxPagesToFetch = 5
    
    private var timer: Timer?
    private var storedJobIds: Set<String> = []
    
    private init() {
        loadStoredJobIds()
        loadJobs()
    }
    
    func selectJob(withId id: String) {
        if let job = jobs.first(where: { $0.id == id }) {
            selectedJob = job
            selectedTab = "jobs"
        }
    }
    
    func startMonitoring() async {
        await fetchJobs()
        
        // Setup timer
        await MainActor.run {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: refreshInterval * 60, repeats: true) { _ in
                Task {
                    await self.fetchJobs()
                }
            }
        }
    }
    
    func fetchJobs() async {
        isLoading = true
        lastError = nil
        newJobsCount = 0
        
        do {
            let fetcher = MicrosoftJobFetcher()
            let fetchedJobs = try await fetcher.fetchJobs(
                titleKeywords: jobTitleFilter.isEmpty ? [] : [jobTitleFilter],
                location: locationFilter,
                maxPages: Int(maxPagesToFetch)
            )
            
            totalFetchedCount = fetchedJobs.count
            print("Fetched \(fetchedJobs.count) total unique jobs from API")
            
            let recentJobs = fetchedJobs.filter { $0.isWithin24Hours }
            
            filteredCount = recentJobs.count
            print("Filtered to \(recentJobs.count) jobs from last 24 hours")
            
            // Deduplicate and find new jobs
            var uniqueJobs: [Job] = []
            var newJobs: [Job] = []
            var seenIds = Set<String>()
            
            for job in recentJobs.sorted(by: { $0.postingDate > $1.postingDate }) {
                if !seenIds.contains(job.id) {
                    uniqueJobs.append(job)
                    seenIds.insert(job.id)
                    
                    // Check if this is a new job
                    if !storedJobIds.contains(job.id) {
                        newJobs.append(job)
                        print("New job found: \(job.title) - \(job.id)")
                    }
                }
            }
            
            // Send notification for new jobs
            if !newJobs.isEmpty {
                print("Sending notification for \(newJobs.count) new jobs")
                sendGroupedNotification(for: newJobs)
                
                // Add new job IDs to stored set after sending notification
                for job in newJobs {
                    storedJobIds.insert(job.id)
                }
                
                newJobsCount = newJobs.count
            }
            
            jobs = uniqueJobs
            saveJobs()
            saveStoredJobIds()
            
            print("Stored job IDs count: \(storedJobIds.count)")
            
        } catch {
            lastError = error.localizedDescription
            print("Error fetching jobs: \(error)")
        }
        
        isLoading = false
    }
    
    private func sendGroupedNotification(for newJobs: [Job]) {
        if newJobs.count == 1 {
            // Single job notification
            let job = newJobs[0]
            let content = UNMutableNotificationContent()
            content.title = "New Job Posted"
            content.subtitle = job.title
            content.body = job.location
            content.sound = .default
            content.userInfo = ["jobId": job.id]
            
            let request = UNNotificationRequest(
                identifier: job.id,
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error sending notification: \(error)")
                } else {
                    print("Notification sent for job: \(job.title)")
                }
            }
        } else {
            // Multiple jobs - grouped notification
            let content = UNMutableNotificationContent()
            content.title = "\(newJobs.count) New Jobs Posted"
            content.subtitle = "Microsoft Careers (Last 24h)"
            
            let jobTitles = newJobs.prefix(3).map { "• \($0.title)" }.joined(separator: "\n")
            let moreText = newJobs.count > 3 ? "\n...and \(newJobs.count - 3) more" : ""
            content.body = jobTitles + moreText
            
            content.sound = .default
            content.userInfo = ["jobId": newJobs[0].id] // Open first job when clicked
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error sending grouped notification: \(error)")
                } else {
                    print("Grouped notification sent for \(newJobs.count) jobs")
                }
            }
        }
    }
    
    func openJob(_ job: Job) {
        if let url = URL(string: job.url) {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Persistence
    private var jobsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("jobs.json")
    }
    
    private var storedIdsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("storedIds.json")
    }
    
    private func saveJobs() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try FileManager.default.createDirectory(at: jobsURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try data.write(to: jobsURL)
        } catch {
            print("Failed to save jobs: \(error)")
        }
    }
    
    private func loadJobs() {
        do {
            let data = try Data(contentsOf: jobsURL)
            jobs = try JSONDecoder().decode([Job].self, from: data)
            filteredCount = jobs.count
        } catch {
            print("Failed to load jobs: \(error)")
        }
    }
    
    private func saveStoredJobIds() {
        do {
            let data = try JSONEncoder().encode(Array(storedJobIds))
            try data.write(to: storedIdsURL)
            print("Saved \(storedJobIds.count) stored job IDs")
        } catch {
            print("Failed to save stored IDs: \(error)")
        }
    }
    
    private func loadStoredJobIds() {
        do {
            let data = try Data(contentsOf: storedIdsURL)
            let ids = try JSONDecoder().decode([String].self, from: data)
            storedJobIds = Set(ids)
            print("Loaded \(storedJobIds.count) stored job IDs")
        } catch {
            print("Failed to load stored IDs: \(error)")
        }
    }
}

// MARK: - Job Fetcher
actor MicrosoftJobFetcher {
    private let baseURL = "https://gcsservices.careers.microsoft.com/search/api/v1/search"
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int = 5) async throws -> [Job] {
        var allJobs: [Job] = []
        var seenJobIds = Set<String>()
        var currentPage = 1
        let pageLimit = min(maxPages, 20) // Cap at 20 pages
        
        while currentPage <= pageLimit {
            // Update progress on main thread
            await MainActor.run {
                JobManager.shared.loadingProgress = "Fetching page \(currentPage) of \(pageLimit)..."
            }
            
            var components = URLComponents(string: baseURL)!
            
            var queryValue = titleKeywords.joined(separator: " ")
            if !location.isEmpty {
                queryValue += " \(location)"
            }
            
            components.queryItems = [
                URLQueryItem(name: "l", value: "en_us"),
                URLQueryItem(name: "pg", value: String(currentPage)),
                URLQueryItem(name: "pgSz", value: "20"),
                URLQueryItem(name: "o", value: "Relevance"),
                URLQueryItem(name: "flt", value: "true")
            ]
            
            if !queryValue.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "q", value: queryValue))
            }
            
            print("Fetching URL: \(components.url?.absoluteString ?? "nil")")
            
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("Response is not HTTP response")
                throw FetchError.invalidResponse
            }
            
            if httpResponse.statusCode != 200 {
                print("HTTP Error: Status code \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    print("Error response: \(errorString.prefix(500))")
                }
                throw FetchError.invalidResponse
            }
            
            let pageJobs = try parseResponse(data, page: currentPage)
            
            // Deduplicate jobs
            let uniquePageJobs = pageJobs.filter { job in
                if seenJobIds.contains(job.id) {
                    print("Skipping duplicate job: \(job.id) - \(job.title)")
                    return false
                }
                seenJobIds.insert(job.id)
                return true
            }
            
            let recentJobsInPage = uniquePageJobs.filter { job in
                let hoursSincePosting = Date().timeIntervalSince(job.postingDate) / 3600
                return hoursSincePosting <= 24 && hoursSincePosting >= 0
            }
            
            allJobs.append(contentsOf: uniquePageJobs)
            
            if recentJobsInPage.isEmpty && allJobs.contains(where: { job in
                let hours = Date().timeIntervalSince(job.postingDate) / 3600
                return hours <= 24 && hours >= 0
            }) {
                print("No recent jobs in page \(currentPage), stopping pagination")
                break
            }
            
            if pageJobs.count < 20 {
                break
            }
            
            currentPage += 1
            
            // Small delay to be nice to the API
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
        }
        
        await MainActor.run {
            JobManager.shared.loadingProgress = ""
        }
        
        let pagesFetched = min(currentPage, pageLimit)
        print("Total unique jobs fetched across \(pagesFetched) page(s): \(allJobs.count)")
        return allJobs
    }
    
    private func parseResponse(_ data: Data, page: Int = 1) throws -> [Job] {
        // Only log for first page
        if page == 1 {
            if let jsonString = String(data: data, encoding: .utf8) {
                print("=== MICROSOFT API RESPONSE (first 2000 chars) ===")
                let truncated = String(jsonString.prefix(2000))
                print(truncated)
                print("=== END RESPONSE SAMPLE ===")
            }
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let response = try decoder.decode(MSResponse.self, from: data)
        
        if page == 1 {
            print("\nTotal jobs available: \(response.operationResult.result.totalJobs ?? 0)")
            print("Jobs in this page: \(response.operationResult.result.jobs.count)")
            
            // Update total available jobs
            if let total = response.operationResult.result.totalJobs {
                Task { @MainActor in
                    JobManager.shared.totalAvailableJobs = total
                }
            }
        }
        
        return response.operationResult.result.jobs.map { msJob in
            // Common Microsoft office locations for better detection
            let knownLocations = [
                "Redmond", "Seattle", "Bellevue", "Mountain View", "Sunnyvale",
                "San Francisco", "New York", "NYC", "Austin", "Atlanta",
                "Boston", "Chicago", "Denver", "Los Angeles", "Phoenix",
                "San Diego", "Washington DC", "DC", "Toronto", "Vancouver",
                "London", "Dublin", "Paris", "Berlin", "Munich", "Amsterdam",
                "Stockholm", "Tokyo", "Beijing", "Shanghai", "Singapore",
                "Sydney", "Melbourne", "Bangalore", "Hyderabad", "Delhi",
                "Tel Aviv", "Dubai", "Cairo", "Lagos", "Nairobi", "Johannesburg"
            ]
            
            // Clean title and extract location
            var cleanTitle = msJob.title
            var extractedLocation: String? = nil
            
            // Method 1: Check for location after dash in title
            if msJob.title.contains(" - ") {
                let parts = msJob.title.components(separatedBy: " - ")
                if parts.count > 1 {
                    let lastPart = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Check if the last part looks like a location
                    if knownLocations.contains(where: { lastPart.contains($0) }) ||
                       lastPart.count < 30 { // Likely a location if it's short
                        cleanTitle = parts.dropLast().joined(separator: " - ")
                        extractedLocation = lastPart
                    }
                }
            }
            
            // Method 2: Check for location in parentheses
            if extractedLocation == nil && msJob.title.contains("(") && msJob.title.contains(")") {
                if let range = msJob.title.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
                    let location = String(msJob.title[range]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                    if knownLocations.contains(where: { location.contains($0) }) {
                        extractedLocation = location
                        cleanTitle = msJob.title.replacingOccurrences(of: #"\s*\([^)]+\)"#, with: "", options: .regularExpression)
                    }
                }
            }
            
            // Method 3: Look for known locations in the title itself
            if extractedLocation == nil {
                for location in knownLocations {
                    if msJob.title.contains(location) {
                        extractedLocation = location
                        break
                    }
                }
            }
            
            // Build location string from API fields
            var locationComponents: [String] = []
            
            if let city = msJob.properties?.location?.city, !city.isEmpty {
                locationComponents.append(city)
            }
            if let state = msJob.properties?.location?.state, !state.isEmpty {
                locationComponents.append(state)
            }
            if let country = msJob.properties?.location?.country, !country.isEmpty {
                locationComponents.append(country)
            }
            
            // Check for remote/hybrid in workSiteFlexibility
            let workSiteFlexibility = msJob.properties?.workSiteFlexibility ?? ""
            let isFullRemote = workSiteFlexibility.lowercased().contains("100%") ||
                              workSiteFlexibility.lowercased().contains("up to 100%")
            let hasRemoteOption = workSiteFlexibility.lowercased().contains("work from home") ||
                                 isFullRemote ||
                                 workSiteFlexibility.lowercased().contains("remote")
            let hasHybridOption = (workSiteFlexibility.lowercased().contains("up to 50%") ||
                                  workSiteFlexibility.lowercased().contains("up to 25%") ||
                                  workSiteFlexibility.lowercased().contains("hybrid")) && !isFullRemote
            
            // Determine final location string
            var location: String
            if !locationComponents.isEmpty {
                location = locationComponents.joined(separator: ", ")
            } else if let extracted = extractedLocation {
                location = extracted
            } else if isFullRemote {
                location = "Remote"
            } else if hasHybridOption {
                location = "Hybrid (Location Flexible)"
            } else if hasRemoteOption {
                location = "Remote/Flexible"
            } else {
                location = "Location not specified"
            }
            
            if location != "Remote" && location != "Remote/Flexible" && location != "Hybrid (Location Flexible)" {
                if hasHybridOption {
                    location += " (Hybrid)"
                } else if hasRemoteOption && !isFullRemote {
                    location += " (Remote option)"
                }
            }
            
            return Job(
                id: "microsoft-\(msJob.jobId)",
                title: cleanTitle,
                location: location,
                postingDate: parseDate(msJob.postingDate) ?? Date(),
                url: "https://careers.microsoft.com/us/en/job/\(msJob.jobId)",
                description: msJob.properties?.description ?? "",
                workSiteFlexibility: workSiteFlexibility
            )
        }
    }
    
    private func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}


// MARK: - API Response Models
struct MSResponse: Codable {
    let operationResult: OperationResult
}

struct OperationResult: Codable {
    let result: SearchResult
}

struct SearchResult: Codable {
    let jobs: [MSJob]
    let totalJobs: Int?
}

struct MSJob: Codable {
    let jobId: String
    let title: String
    let postingDate: String
    let properties: Properties?
}

struct Properties: Codable {
    let description: String?
    let location: Location?
    let workSiteFlexibility: String?
}

struct Location: Codable {
    let city: String?
    let state: String?
    let country: String?
}

enum FetchError: LocalizedError {
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Failed to fetch jobs from Microsoft"
        }
    }
}

// MARK: - Views
struct ContentView: View {
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            VStack(spacing: 20) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                
                VStack(spacing: 10) {
                    SidebarButton(
                        title: "Jobs",
                        icon: "list.bullet",
                        isSelected: jobManager.selectedTab == "jobs"
                    ) {
                        jobManager.selectedTab = "jobs"
                        jobManager.selectedJob = nil
                    }
                    
                    SidebarButton(
                        title: "Settings",
                        icon: "gear",
                        isSelected: jobManager.selectedTab == "settings"
                    ) {
                        jobManager.selectedTab = "settings"
                        jobManager.selectedJob = nil
                    }
                }
                
                Spacer()
                
                if jobManager.isLoading {
                    VStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.8)
                        if !jobManager.loadingProgress.isEmpty {
                            Text(jobManager.loadingProgress)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                VStack(spacing: 4) {
                    Text("\(jobManager.jobs.count) jobs (24h)")
                        .font(.caption)
                        .fontWeight(.medium)
                    if jobManager.totalFetchedCount > jobManager.filteredCount {
                        Text("(\(jobManager.totalFetchedCount) fetched)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if jobManager.totalAvailableJobs > 0 {
                        Text("\(jobManager.totalAvailableJobs) available")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .frame(width: 200)
        } detail: {
            // Main content
            if jobManager.selectedTab == "jobs" {
                if let selectedJob = jobManager.selectedJob {
                    JobDetailView(job: selectedJob)
                } else {
                    JobListView()
                }
            } else {
                SettingsView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("Microsoft Job Monitor")
    }
}

struct SidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct JobListView: View {
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Jobs (Last 24 Hours)")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: {
                    Task {
                        await jobManager.fetchJobs()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(jobManager.isLoading)
            }
            .padding()
            
            Divider()
            
            // Jobs list
            if jobManager.jobs.isEmpty && !jobManager.isLoading {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text("No jobs posted in last 24 hours")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    
                    if jobManager.totalFetchedCount > 0 {
                        Text("(\(jobManager.totalFetchedCount) jobs found, but none from last 24h)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Check your filters in Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(jobManager.jobs) { job in
                            JobRow(job: job)
                            Divider()
                        }
                    }
                }
            }
            
            // Error message
            if let error = jobManager.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
            }
        }
    }
}

struct JobRow: View {
    let job: Job
    @State private var isHovered = false
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        Button(action: {
            jobManager.selectedJob = job
        }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "briefcase")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    HStack {
                        Label(job.location, systemImage: "location")
                        Spacer()
                        Text(job.postingDate, style: .time)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    if !job.overview.isEmpty {
                        Text(job.overview)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .opacity(isHovered ? 1 : 0.5)
            }
            .padding()
            .background(isHovered ? Color.gray.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct JobDetailView: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    @State private var selectedSection = "overview"
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with back button
                HStack {
                    Button(action: {
                        jobManager.selectedJob = nil
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back to Jobs")
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Button(action: {
                        jobManager.openJob(job)
                    }) {
                        Label("Open in Browser", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                
                Divider()
                
                // Job details
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    Text(job.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    // Location and time
                    HStack(spacing: 20) {
                        Label(job.location, systemImage: "location")
                            .font(.title3)
                        
                        Label {
                            Text(job.postingDate, style: .relative)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.title3)
                    }
                    .foregroundColor(.secondary)
                    
                    if let flexibility = job.workSiteFlexibility, !flexibility.isEmpty {
                        Label(flexibility, systemImage: "house.laptop")
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }
                    
                    Divider()
                    
                    // Section Picker
                    Picker("Section", selection: $selectedSection) {
                        Text("Overview").tag("overview")
                        if job.requiredQualifications != nil {
                            Text("Required").tag("required")
                        }
                        if job.preferredQualifications != nil {
                            Text("Preferred").tag("preferred")
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    // Content based on selection
                    VStack(alignment: .leading, spacing: 12) {
                        switch selectedSection {
                        case "overview":
                            Text("Job Description")
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            Text(job.overview)
                                .font(.body)
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                            
                        case "required":
                            Text("Required/Minimum Qualifications")
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            if let qualifications = job.requiredQualifications {
                                Text(qualifications)
                                    .font(.body)
                                    .lineSpacing(6)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            
                        case "preferred":
                            Text("Preferred Qualifications")
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            if let qualifications = job.preferredQualifications {
                                Text(qualifications)
                                    .font(.body)
                                    .lineSpacing(6)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            
                        default:
                            EmptyView()
                        }
                    }
                    .padding(.horizontal)
                    
                    Spacer(minLength: 40)
                    
                    // Action button
                    HStack {
                        Spacer()
                        Button(action: {
                            jobManager.openJob(job)
                        }) {
                            Text("Apply on Microsoft Careers")
                                .font(.headline)
                                .padding(.horizontal, 30)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Spacer()
                    }
                }
                .padding()
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var jobManager: JobManager
    @State private var titleFilter = ""
    @State private var locationFilter = ""
    @State private var refreshInterval = 30.0
    @State private var maxPagesToFetch = 5.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            
            Divider()
            
            Form {
                Section("Job Filters") {
                    TextField("Job Title", text: $titleFilter)
                        .textFieldStyle(.roundedBorder)
                        .help("Enter keywords to filter job titles (e.g., 'Software Engineer')")
                    
                    TextField("Location", text: $locationFilter)
                        .textFieldStyle(.roundedBorder)
                        .help("Enter location to filter jobs (e.g., 'Seattle' or 'Remote')")
                }
                
                Section("Fetch Settings") {
                    HStack {
                        Text("Check for new jobs every")
                        TextField("", value: $refreshInterval, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text("minutes")
                    }
                    
                    HStack {
                        Text("Fetch up to")
                        TextField("", value: $maxPagesToFetch, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text("pages (\(Int(maxPagesToFetch) * 20) jobs)")
                            .foregroundColor(.secondary)
                    }
                    .help("Each page contains 20 jobs. More pages = longer fetch time")
                }
                
                Section {
                    HStack {
                        Button("Save Settings") {
                            saveSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Save and Refresh Now") {
                            saveSettings()
                            Task {
                                await jobManager.fetchJobs()
                            }
                        }
                        
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            
            Spacer()
        }
        .padding()
        .onAppear {
            titleFilter = jobManager.jobTitleFilter
            locationFilter = jobManager.locationFilter
            refreshInterval = jobManager.refreshInterval
            maxPagesToFetch = Double(jobManager.maxPagesToFetch)
        }
    }
    
    private func saveSettings() {
        jobManager.jobTitleFilter = titleFilter
        jobManager.locationFilter = locationFilter
        jobManager.refreshInterval = refreshInterval
        jobManager.maxPagesToFetch = Int(maxPagesToFetch)
        
        Task {
            await jobManager.startMonitoring()
        }
    }
}
