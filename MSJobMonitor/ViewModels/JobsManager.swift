//
//  JobManager.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI
import Foundation
import Combine
import UserNotifications
import AppKit

@MainActor
class JobManager: ObservableObject {
    static let shared = JobManager()
    
    // MARK: - Published Properties
    @Published var jobs: [Job] = []
    @Published var isLoading = false
    @Published var loadingProgress = ""
    @Published var showSettings = false
    @Published var lastError: String?
    @Published var selectedJob: Job?
    @Published var selectedTab = "jobs"
    @Published var newJobsCount = 0
    @Published var appliedJobIds: Set<String> = []
    @Published var fetchStatistics = FetchStatistics()
    
    // MARK: - Settings (Persisted in UserDefaults)
    @Published var jobTitleFilter: String = UserDefaults.standard.string(forKey: "jobTitleFilter") ?? "" {
        didSet { UserDefaults.standard.set(jobTitleFilter, forKey: "jobTitleFilter") }
    }

    @Published var locationFilter: String = UserDefaults.standard.string(forKey: "locationFilter") ?? "" {
        didSet { UserDefaults.standard.set(locationFilter, forKey: "locationFilter") }
    }

    @Published var refreshInterval: Double = UserDefaults.standard.double(forKey: "refreshInterval") {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }

    @Published var maxPagesToFetch: Int = UserDefaults.standard.integer(forKey: "maxPagesToFetch") {
        didSet { UserDefaults.standard.set(maxPagesToFetch, forKey: "maxPagesToFetch") }
    }

    @Published var enableTikTok: Bool = UserDefaults.standard.bool(forKey: "enableTikTok") {
        didSet { UserDefaults.standard.set(enableTikTok, forKey: "enableTikTok") }
    }

    @Published var enableMicrosoft: Bool = UserDefaults.standard.bool(forKey: "enableMicrosoft") {
        didSet { UserDefaults.standard.set(enableMicrosoft, forKey: "enableMicrosoft") }
    }

    @Published var enableCustomBoards: Bool = UserDefaults.standard.object(forKey: "enableCustomBoards") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enableCustomBoards, forKey: "enableCustomBoards") }
    }
    
    // MARK: - Private Properties
    private var fetchTimers: [JobSource: Timer] = [:]
    private var storedJobIds: Set<String> = []
    private let persistenceService = PersistenceService.shared
    private let notificationService = NotificationService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Fetchers
    private let microsoftFetcher = MicrosoftJobFetcher()
    private let tiktokFetcher = TikTokJobFetcher()
    private let greenhouseFetcher = GreenhouseFetcher()
    
    private init() {
        setupInitialState()
        setupBindings()
    }
    
    // MARK: - Setup
    private func setupInitialState() {
        Task {
            await loadStoredData()
        }
    }
    
    private func setupBindings() {
        $enableTikTok
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.tiktok)
                } else {
                    self?.stopMonitoringSource(.tiktok)
                }
            }
            .store(in: &cancellables)
        
        $enableMicrosoft
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.microsoft)
                } else {
                    self?.stopMonitoringSource(.microsoft)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    func startMonitoring() async {
        print("📊 Starting job monitoring...")
        
        // Initial fetch
        await fetchAllJobs()
        
        if enableMicrosoft {
            startMonitoringSource(.microsoft)
        }
        if enableTikTok {
            startMonitoringSource(.tiktok)
        }
        if enableCustomBoards {
            await JobBoardMonitor.shared.startMonitoring()
        }
    }
    
    func stopMonitoring() {
        fetchTimers.values.forEach { $0.invalidate() }
        fetchTimers.removeAll()
        print("📊 Stopped all job monitoring")
    }
    
    func fetchAllJobs() async {
        isLoading = true
        lastError = nil
        newJobsCount = 0
        fetchStatistics = FetchStatistics()
        
        var allNewJobs: [Job] = []
        var allFetchedJobs: [Job] = []
        
        // Fetch from each enabled source
        if enableMicrosoft {
            do {
                let jobs = try await fetchFromSource(.microsoft)
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                allFetchedJobs.append(contentsOf: jobs)
                fetchStatistics.microsoftJobs = jobs.count
            } catch {
                lastError = "Microsoft: \(error.localizedDescription)"
                print("❌ Microsoft fetch error: \(error)")
            }
        }
        
        if enableTikTok {
            do {
                let jobs = try await fetchFromSource(.tiktok)
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                allFetchedJobs.append(contentsOf: jobs)
                fetchStatistics.tiktokJobs = jobs.count
            } catch {
                lastError = "TikTok: \(error.localizedDescription)"
                print("❌ TikTok fetch error: \(error)")
            }
        }
        
        if enableCustomBoards {
            let boardJobs = await JobBoardMonitor.shared.fetchAllBoardJobs(
                titleFilter: jobTitleFilter,
                locationFilter: locationFilter
            )
            let newBoardJobs = filterNewJobs(boardJobs)
            allNewJobs.append(contentsOf: newBoardJobs)
            allFetchedJobs.append(contentsOf: boardJobs)
            fetchStatistics.customBoardJobs = boardJobs.count
        }
        
        // Process and update jobs
        await processNewJobs(allNewJobs, allFetched: allFetchedJobs)
        
        isLoading = false
    }
    
    func selectJob(withId id: String) {
        if let job = jobs.first(where: { $0.id == id }) {
            selectedJob = job
            selectedTab = "jobs"
        }
    }
    
    func openJob(_ job: Job) {
        if let url = URL(string: job.url) {
            appliedJobIds.insert(job.id)
            Task {
                try await persistenceService.saveAppliedJobIds(appliedJobIds)
            }
            NSWorkspace.shared.open(url)
        }
    }
    
    func toggleAppliedStatus(for job: Job) {
        if appliedJobIds.contains(job.id) {
            appliedJobIds.remove(job.id)
        } else {
            appliedJobIds.insert(job.id)
        }
        Task {
            try await persistenceService.saveAppliedJobIds(appliedJobIds)
        }
    }
    
    func isJobApplied(_ job: Job) -> Bool {
        return appliedJobIds.contains(job.id)
    }
    
    // MARK: - Private Methods
    private func startMonitoringSource(_ source: JobSource) {
        // Cancel existing timer if any
        fetchTimers[source]?.invalidate()
        
        let interval = refreshInterval * 60
        
        fetchTimers[source] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { [weak self] in
                await self?.fetchJobsFromSource(source)
            }
        }
        
        print("⏰ Started monitoring \(source.rawValue) every \(refreshInterval) minutes")
    }
    
    private func stopMonitoringSource(_ source: JobSource) {
        fetchTimers[source]?.invalidate()
        fetchTimers.removeValue(forKey: source)
        print("⏰ Stopped monitoring \(source.rawValue)")
    }
    
    private func fetchFromSource(_ source: JobSource) async throws -> [Job] {
        let titleKeywords = parseTitleKeywords()
        let locations = parseLocations()
        
        loadingProgress = "Fetching from \(source.rawValue)..."
        
        switch source {
        case .microsoft:
            return try await microsoftFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: Int(maxPagesToFetch)
            )
        case .tiktok:
            return try await tiktokFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: 350  // Fetch more pages for TikTok since no dates
            )
        case .greenhouse:
            return []
        default:
            throw FetchError.notImplemented(source.rawValue)
        }
    }
    
    private func fetchJobsFromSource(_ source: JobSource) async {
        do {
            let jobs = try await fetchFromSource(source)
            let newJobs = filterNewJobs(jobs)
            
            if !newJobs.isEmpty {
                await processNewJobs(newJobs, allFetched: jobs)
            }
        } catch {
            print("❌ Error fetching from \(source.rawValue): \(error)")
        }
    }
    
    private func filterNewJobs(_ jobs: [Job]) -> [Job] {
        return jobs.filter { job in
            job.isRecent && !storedJobIds.contains(job.id)
        }
    }
    
    private func processNewJobs(_ newJobs: [Job], allFetched: [Job]) async {
        // Add new job IDs to stored set
        newJobs.forEach { storedJobIds.insert($0.id) }
        
        let recentJobs = allFetched.filter { $0.isRecent }
        
        var uniqueJobs: [Job] = []
        var seenIds = Set<String>()
        
        let allJobs = recentJobs + jobs
        for job in allJobs.sorted(by: { 
            // Sort by posting date if available, otherwise by first seen date
            let date1 = $0.postingDate ?? $0.firstSeenDate
            let date2 = $1.postingDate ?? $1.firstSeenDate
            return date1 > date2
        }) {
            if !seenIds.contains(job.id) {
                uniqueJobs.append(job)
                seenIds.insert(job.id)
            }
        }
        
        jobs = uniqueJobs
        newJobsCount = newJobs.count
        
        fetchStatistics.totalJobs = jobs.count
        fetchStatistics.newJobs = newJobsCount
        fetchStatistics.lastFetchTime = Date()
        
        if !newJobs.isEmpty {
            await notificationService.sendGroupedNotification(for: newJobs)
        }
        
        try? await persistenceService.saveJobs(jobs)
        try? await persistenceService.saveStoredJobIds(storedJobIds)
        
        loadingProgress = ""
    }
    
    private func loadStoredData() async {
        do {
            jobs = try await persistenceService.loadJobs()
            storedJobIds = try await persistenceService.loadStoredJobIds()
            appliedJobIds = try await persistenceService.loadAppliedJobIds()
            
            print("📊 Loaded \(jobs.count) jobs, \(storedJobIds.count) tracked IDs")
        } catch {
            print("❌ Error loading stored data: \(error)")
        }
    }
    
    private func parseTitleKeywords() -> [String] {
        guard !jobTitleFilter.isEmpty else { return [] }
        return jobTitleFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    private func parseLocations() -> [String] {
        guard !locationFilter.isEmpty else { return [] }
        return locationFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Fetch Statistics
struct FetchStatistics {
    var totalJobs: Int = 0
    var newJobs: Int = 0
    var microsoftJobs: Int = 0
    var tiktokJobs: Int = 0
    var customBoardJobs: Int = 0
    var lastFetchTime: Date?
    
    var summary: String {
        var parts: [String] = []
        
        if microsoftJobs > 0 {
            parts.append("Microsoft: \(microsoftJobs)")
        }
        if tiktokJobs > 0 {
            parts.append("TikTok: \(tiktokJobs)")
        }
        if customBoardJobs > 0 {
            parts.append("Boards: \(customBoardJobs)")
        }
        
        if parts.isEmpty {
            return "No jobs found"
        }
        
        return parts.joined(separator: " • ")
    }
}
