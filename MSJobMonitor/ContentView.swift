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
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: "briefcase.fill", accessibilityDescription: "Job Monitor")?
                .withSymbolConfiguration(config)
            button.action = #selector(togglePopover)
            button.toolTip = "Microsoft Job Monitor"
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
            .replacingOccurrences(of: "&#8217;", with: "\u{2019}")
            .replacingOccurrences(of: "&#8220;", with: "\u{201C}")
            .replacingOccurrences(of: "&#8221;", with: "\u{201D}")
            .replacingOccurrences(of: "&#8211;", with: "\u{2013}")
            .replacingOccurrences(of: "&#8212;", with: "\u{2014}")
        
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
            
            // Parse comma-separated filters before passing to fetcher
            let titleKeywords = jobTitleFilter.isEmpty ? [] :
                jobTitleFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            
            let fetchedJobs = try await fetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter, // This will be parsed inside fetchJobs
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
struct SearchQuery: Hashable {
    let title: String
    let location: String
    let description: String
}

actor MicrosoftJobFetcher {
    private let baseURL = "https://gcsservices.careers.microsoft.com/search/api/v1/search"
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int = 5) async throws -> [Job] {
        print("MULTI-QUERY: Starting with titles: \(titleKeywords), location: '\(location)'")
        
        var allJobs: [Job] = []
        var globalSeenJobIds = Set<String>()
        
        // Parse comma-separated locations
        let locations = location.isEmpty ? [""] : location.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        
        let titles = titleKeywords.filter { !$0.isEmpty }
        
        print("MULTI-QUERY: Parsed titles: \(titles)")
        print("MULTI-QUERY: Parsed locations: \(locations)")
        
        // Generate individual search combinations
        var searchCombinations: [(title: String, location: String)] = []
        
        if titles.isEmpty && locations.isEmpty {
            searchCombinations.append(("", ""))
        } else if titles.isEmpty {
            for loc in locations {
                searchCombinations.append(("", loc))
            }
        } else if locations.isEmpty {
            for title in titles {
                searchCombinations.append((title, ""))
            }
        } else {
            for title in titles {
                for loc in locations {
                    searchCombinations.append((title, loc))
                }
            }
        }
        
        print("MULTI-QUERY: Will make \(searchCombinations.count) separate API calls:")
        for (i, combo) in searchCombinations.enumerated() {
            let query = [combo.title, combo.location].filter { !$0.isEmpty }.joined(separator: " ")
            print("  \(i+1). Query: '\(query.isEmpty ? "recent jobs" : query)'")
        }
        
        for (index, combo) in searchCombinations.enumerated() {
            let description = [combo.title, combo.location].filter { !$0.isEmpty }.joined(separator: " in ")
            
            await MainActor.run {
                JobManager.shared.loadingProgress = "Search \(index + 1)/\(searchCombinations.count): \(description.isEmpty ? "recent jobs" : description)"
            }
            
            let jobs = try await executeIndividualSearch(title: combo.title, location: combo.location, maxPages: max(1, maxPages / searchCombinations.count))
            
            // Deduplicate across all searches
            let newJobs = jobs.filter { job in
                if globalSeenJobIds.contains(job.id) {
                    return false
                }
                globalSeenJobIds.insert(job.id)
                return true
            }
            
            allJobs.append(contentsOf: newJobs)
            print("MULTI-QUERY: Search \(index + 1) returned \(newJobs.count) new unique jobs")
            
            try await Task.sleep(nanoseconds: 700_000_000) // 0.7 seconds
        }
        
        await MainActor.run {
            JobManager.shared.loadingProgress = ""
        }
        
        print("MULTI-QUERY: TOTAL RESULT: \(allJobs.count) unique jobs from \(searchCombinations.count) searches")
        return allJobs
    }

    
    
    private func generateSearchQueries(parsedTitles: [String], parsedLocations: [String]) -> [SearchQuery] {
        var queries: [SearchQuery] = []
        
        if parsedTitles.isEmpty && parsedLocations.isEmpty {
            queries.append(SearchQuery(title: "", location: "", description: "Recent jobs"))
            return queries
        }
        
        if parsedTitles.isEmpty {
            for location in parsedLocations {
                queries.append(SearchQuery(title: "", location: location, description: "All jobs in \(location)"))
                
                let synonyms = getLocationSynonyms(for: location)
                for synonym in synonyms.prefix(1) {
                    queries.append(SearchQuery(title: "", location: synonym, description: "All jobs in \(synonym)"))
                }
            }
        } else if parsedLocations.isEmpty {
            for title in parsedTitles {
                queries.append(SearchQuery(title: title, location: "", description: "\(title) roles"))
                
                let synonyms = getTitleSynonyms(for: title)
                for synonym in synonyms.prefix(1) {
                    queries.append(SearchQuery(title: synonym, location: "", description: "\(synonym) roles"))
                }
            }
        } else {
            // Combine titles and locations
            for title in parsedTitles {
                for location in parsedLocations {
                    queries.append(SearchQuery(title: title, location: location, description: "\(title) in \(location)"))
                }
            }

//            // broader searches with just titles
//            for title in parsedTitles {
//                queries.append(SearchQuery(title: title, location: "", description: "\(title) (any location)"))
//            }
        }
        
        return Array(queries.prefix(8))
    }
    
    private func performSingleSearch(title: String, location: String, maxPages: Int) async throws -> [Job] {
        var allJobs: [Job] = []
        var seenJobIds = Set<String>()
        var currentPage = 1
        let pageLimit = min(maxPages, 5) // Reduced page limit per individual search
        
        while currentPage <= pageLimit {
            var components = URLComponents(string: baseURL)!
            
            var queryParts: [String] = []
            if !title.isEmpty {
                queryParts.append(title)
            }
            if !location.isEmpty {
                queryParts.append(location)
            }
            let queryString = queryParts.joined(separator: " ")
            
            components.queryItems = [
                URLQueryItem(name: "l", value: "en_us"),
                URLQueryItem(name: "pg", value: String(currentPage)),
                URLQueryItem(name: "pgSz", value: "20"),
                URLQueryItem(name: "o", value: "Recent"),
                URLQueryItem(name: "flt", value: "true")
            ]
            
            if !queryString.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "q", value: queryString))
            }
            
            print("🌐 API Query: \(queryString.isEmpty ? "Recent jobs" : queryString)")
            
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("❌ API error for query: \(queryString)")
                break
            }
            
            let pageJobs = try parseResponse(data, page: currentPage)
            
            let uniquePageJobs = pageJobs.filter { job in
                if seenJobIds.contains(job.id) {
                    return false
                }
                seenJobIds.insert(job.id)
                return true
            }
            
            allJobs.append(contentsOf: uniquePageJobs)
            
            if pageJobs.count < 20 {
                break
            }
            
            currentPage += 1
            
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        }
        
        return allJobs
    }
    
    private func getTitleSynonyms(for title: String) -> [String] {
        let lowercaseTitle = title.lowercased()
        let synonymMap: [String: [String]] = [
            "manager": ["director", "lead", "supervisor"],
            "engineer": ["developer", "architect", "specialist"],
            "product": ["program", "project"],
            "software": ["dev", "engineering"],
            "senior": ["principal", "staff", "sr"],
            "program": ["product", "project"],
            "developer": ["engineer", "dev"],
            "data": ["analytics", "bi", "intelligence"],
            "marketing": ["growth", "demand", "digital"],
            "sales": ["account", "business development", "revenue"]
        ]
        
        for (key, synonyms) in synonymMap {
            if lowercaseTitle.contains(key) {
                return synonyms
            }
        }
        return []
    }
    
    private func getLocationSynonyms(for location: String) -> [String] {
        let lowercaseLocation = location.lowercased()
        let locationMap: [String: [String]] = [
            "washington": ["redmond", "seattle", "bellevue"],
            "seattle": ["redmond", "bellevue", "kirkland"],
            "california": ["mountain view", "san francisco", "los angeles"],
            "texas": ["austin", "dallas", "houston"],
            "new york": ["nyc", "manhattan"],
            "boston": ["cambridge", "ma"],
            "chicago": ["il", "illinois"]
        ]
        
        for (key, synonyms) in locationMap {
            if lowercaseLocation.contains(key) {
                return synonyms.prefix(2).map { String($0) }
            }
        }
        return []
    }
    
    private func parseResponse(_ data: Data, page: Int = 1) throws -> [Job] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let response = try decoder.decode(MSResponse.self, from: data)
        
        if page == 1 {
            // Update total available jobs
            if let total = response.operationResult.result.totalJobs {
                Task { @MainActor in
                    JobManager.shared.totalAvailableJobs = total
                }
            }
        }
        
        return response.operationResult.result.jobs.map { msJob in
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
            
            var cleanTitle = msJob.title
            var extractedLocation: String? = nil
            
            // Method 1: Check for location after dash in title
            if msJob.title.contains(" - ") {
                let parts = msJob.title.components(separatedBy: " - ")
                if parts.count > 1 {
                    let lastPart = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if knownLocations.contains(where: { lastPart.contains($0) }) || lastPart.count < 30 {
                        cleanTitle = parts.dropLast().joined(separator: " - ")
                        extractedLocation = lastPart
                    }
                }
            }
            
            // Check for location in parentheses
            if extractedLocation == nil,
               let range = msJob.title.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
                let location = String(msJob.title[range])
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                if knownLocations.contains(where: { location.contains($0) }) {
                    extractedLocation = location
                    cleanTitle = msJob.title.replacingOccurrences(of: #"\s*\([^)]+\)"#,
                                                                  with: "",
                                                                  options: .regularExpression)
                }
            }
            
            // Look for known locations in the title itself
            if extractedLocation == nil {
                for location in knownLocations {
                    if msJob.title.contains(location) {
                        extractedLocation = location
                        break
                    }
                }
            }
            
            var location: String = "Location not specified"
            
            if let primaryLoc = msJob.properties?.primaryLocation, !primaryLoc.isEmpty {
                location = primaryLoc
            } else if let locations = msJob.properties?.locations, !locations.isEmpty {
                location = locations[0]
            } else if let extracted = extractedLocation {
                location = extracted
            }
            
            // Check for remote/hybrid
            let workSiteFlexibility = msJob.properties?.workSiteFlexibility ?? ""
            let isHybrid = workSiteFlexibility.contains("days / week") ||
                           workSiteFlexibility.contains("days/week") ||
                           workSiteFlexibility.lowercased().contains("hybrid")
            let isRemote = workSiteFlexibility.lowercased().contains("100%") ||
                           workSiteFlexibility.lowercased().contains("remote") ||
                           workSiteFlexibility.lowercased().contains("work from home")
            
            if location != "Location not specified" {
                if isHybrid {
                    location += " (Hybrid: \(workSiteFlexibility))"
                } else if isRemote {
                    location += " (Remote)"
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
    
    private func executeIndividualSearch(title: String, location: String, maxPages: Int) async throws -> [Job] {
        var jobs: [Job] = []
        let pageLimit = min(maxPages, 3)
        
        for page in 1...pageLimit {
            let queryParts = [title, location].filter { !$0.isEmpty }
            let queryString = queryParts.joined(separator: " ")
            
            var components = URLComponents(string: baseURL)!
            components.queryItems = [
                URLQueryItem(name: "l", value: "en_us"),
                URLQueryItem(name: "pg", value: String(page)),
                URLQueryItem(name: "pgSz", value: "20"),
                URLQueryItem(name: "o", value: "Recent"),
                URLQueryItem(name: "flt", value: "true")
            ]
            
            if !queryString.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "q", value: queryString))
            }
            
            print("MULTI-QUERY: API call with query: '\(queryString)' (page \(page))")
            print("MULTI-QUERY: URL: \(components.url?.absoluteString ?? "nil")")
            
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("MULTI-QUERY: API error for query: '\(queryString)'")
                break
            }
            
            let pageJobs = try parseResponse(data, page: page)
            jobs.append(contentsOf: pageJobs)
            
            if pageJobs.count < 20 {
                break
            }
            
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
        }
        
        return jobs
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
    let locations: [String]?
    let primaryLocation: String?
    let workSiteFlexibility: String?
    let profession: String?
    let discipline: String?
    let roleType: String?
    let employmentType: String?
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
    @State private var sidebarVisible = true
    @State private var windowSize: CGSize = .zero
    
    private var isWindowMinimized: Bool {
        windowSize.width < 800
    }
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Collapsible Sidebar
                if sidebarVisible {
                    VStack(spacing: 20) {
                        // Sidebar header with toggle
                        HStack {
                            Image(systemName: "briefcase.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.accentColor)
                            
                            Spacer()
                            
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    sidebarVisible = false
                                }
                            }) {
                                Image(systemName: "sidebar.left")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Hide Sidebar")
                        }
                        
                        VStack(spacing: 10) {
                            SidebarButton(
                                title: "Jobs",
                                icon: "list.bullet",
                                isSelected: jobManager.selectedTab == "jobs"
                            ) {
                                jobManager.selectedTab = "jobs"
                                if isWindowMinimized {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        sidebarVisible = false
                                    }
                                }
                            }
                            
                            SidebarButton(
                                title: "Settings",
                                icon: "gear",
                                isSelected: jobManager.selectedTab == "settings"
                            ) {
                                jobManager.selectedTab = "settings"
                                jobManager.selectedJob = nil
                                if isWindowMinimized {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        sidebarVisible = false
                                    }
                                }
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
                                        .multilineTextAlignment(.center)
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
                    .background(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        Rectangle()
                            .frame(width: 1)
                            .foregroundColor(Color(NSColor.separatorColor)),
                        alignment: .trailing
                    )
                    .transition(.move(edge: .leading))
                }
                
                HStack(spacing: 0) {
                    // Show toggle when sidebar is hidden
                    if !sidebarVisible {
                        VStack {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    sidebarVisible = true
                                }
                            }) {
                                Image(systemName: "sidebar.left")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .help("Show Sidebar")
                            
                            Spacer()
                        }
                        .padding(.top, 8)
                        .padding(.leading, 8)
                    }
                    
                    // Content
                    VStack(spacing: 0) {
                        if jobManager.selectedTab == "jobs" {
                            JobListView(
                                sidebarVisible: $sidebarVisible,
                                isWindowMinimized: isWindowMinimized
                            )
                        } else {
                            SettingsView()
                        }
                    }
                    
                    if let selectedJob = jobManager.selectedJob {
                        JobDetailPane(job: selectedJob)
                            .frame(width: min(450, geometry.size.width * 0.5))
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: jobManager.selectedJob)
            }
            .animation(.easeInOut(duration: 0.3), value: sidebarVisible)
            .onAppear {
                windowSize = geometry.size
                // Hide sidebar by default if window starts minimized
                if isWindowMinimized {
                    sidebarVisible = false
                }
            }
            .onChange(of: geometry.size) { newSize in
                let wasMinimized = isWindowMinimized
                windowSize = newSize
                
                if !wasMinimized && isWindowMinimized && sidebarVisible {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        sidebarVisible = false
                    }
                }
                else if wasMinimized && !isWindowMinimized && !sidebarVisible {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        sidebarVisible = true
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 400)
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
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool
    
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
                            JobRow(
                                job: job,
                                sidebarVisible: $sidebarVisible,
                                isWindowMinimized: isWindowMinimized
                            )
                            Divider()
                        }
                    }
                }
            }
            
            // Error
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
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool
    
    private var isSelected: Bool {
        jobManager.selectedJob?.id == job.id
    }
    
    var body: some View {
        Button(action: {
            if isSelected {
                jobManager.selectedJob = nil
            } else {
                jobManager.selectedJob = job
                if isWindowMinimized && sidebarVisible {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        sidebarVisible = false
                    }
                }
            }
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
                
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .foregroundColor(.secondary)
                    .opacity(isHovered || isSelected ? 1 : 0.5)
            }
            .padding()
            .background(
                Group {
                    if isSelected {
                        Color.accentColor.opacity(0.1)
                    } else if isHovered {
                        Color.gray.opacity(0.05)
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct JobDetailPane: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Job Details")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: {
                    jobManager.selectedJob = nil
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Job header
                    VStack(alignment: .leading, spacing: 12) {
                        Text(job.title)
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Label(job.location, systemImage: "location")
                                .font(.callout)
                            
                            Label {
                                Text(job.postingDate, style: .relative)
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .font(.callout)
                        }
                        .foregroundColor(.secondary)
                        
                        if let flexibility = job.workSiteFlexibility, !flexibility.isEmpty {
                            Label(flexibility, systemImage: "house.laptop")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(6)
                        }
                    }
                    
                    Divider()
                    
                    // Job description
                    VStack(alignment: .leading, spacing: 12) {
                        Text(job.overview)
                            .font(.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        // Required qualifications if available (they're not but if...)
                        if let required = job.requiredQualifications {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Required Qualifications")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                
                                Text(required)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    
                    Spacer(minLength: 20)
                    
                    Button(action: {
                        jobManager.openJob(job)
                    }) {
                        Text("Apply on Microsoft Careers")
                            .font(.callout)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .leading
        )
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
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Job Titles", text: $titleFilter)
                            .textFieldStyle(.roundedBorder)
                        Text("Separate multiple titles with commas (e.g., 'product manager, program manager, director')")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Locations", text: $locationFilter)
                            .textFieldStyle(.roundedBorder)
                        Text("Separate multiple locations with commas (e.g., 'seattle, redmond, austin')")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
