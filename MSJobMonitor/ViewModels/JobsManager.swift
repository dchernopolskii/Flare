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
    @Published var allJobs: [Job] = []
    @Published var isLoading = false
    @Published var loadingProgress = ""
    @Published var showSettings = false
    @Published var lastError: String?
    @Published var selectedJob: Job?
    @Published var selectedTab = "jobs"
    @Published var newJobsCount = 0
    @Published var appliedJobIds: Set<String> = []
    @Published var fetchStatistics = FetchStatistics()
    
    var jobs: [Job] {
        return allJobs.filter { job in
            if let postingDate = job.postingDate {
                return Date().timeIntervalSince(postingDate) <= 86400
            } else {
                return Date().timeIntervalSince(job.firstSeenDate) <= 86400
            }
        }.sorted { job1, job2 in
            let date1 = job1.postingDate ?? job1.firstSeenDate
            let date2 = job2.postingDate ?? job2.firstSeenDate
            return date1 > date2
        }
    }
    
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
    
    @Published var enableApple: Bool = UserDefaults.standard.object(forKey: "enableApple") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enableApple, forKey: "enableApple") }
    }
    
    @Published var enableSnap: Bool = UserDefaults.standard.bool(forKey: "enableSnap") {
        didSet { UserDefaults.standard.set(enableSnap, forKey: "enableSnap") }
    }

    @Published var enableCustomBoards: Bool = UserDefaults.standard.object(forKey: "enableCustomBoards") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enableCustomBoards, forKey: "enableCustomBoards") }
    }
    
    @Published var includeRemoteJobs: Bool = UserDefaults.standard.object(forKey: "includeRemoteJobs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeRemoteJobs, forKey: "includeRemoteJobs") }
    }
    
    // MARK: - Private Properties
    private var fetchTimers: [JobSource: Timer] = [:]
    private var storedJobIds: Set<String> = []
    private let persistenceService = PersistenceService.shared
    private let notificationService = NotificationService.shared
    private var cancellables = Set<AnyCancellable>()
    private var jobsBySource: [JobSource: [Job]] = [:]
    
    // MARK: - Fetchers
    private let microsoftFetcher = MicrosoftJobFetcher()
    private let tiktokFetcher = TikTokJobFetcher()
    private let appleFetcher = AppleFetcher()
    private let snapFetcher = SnapFetcher()
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
        
        $enableApple
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.apple)
                } else {
                    self?.stopMonitoringSource(.apple)
                }
            }
            .store(in: &cancellables)
        
        $enableSnap
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.snap)
                } else {
                    self?.stopMonitoringSource(.snap)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    func startMonitoring() async {
        
        // Initial fetch
        await fetchAllJobs()
        
        if enableMicrosoft {
            startMonitoringSource(.microsoft)
        }
        if enableTikTok {
            startMonitoringSource(.tiktok)
        }
        if enableApple {
            startMonitoringSource(.apple)
        }
        if enableSnap {
            startMonitoringSource(.snap)
        }
        if enableCustomBoards {
            await JobBoardMonitor.shared.startMonitoring()
        }
    }
    
    func stopMonitoring() {
        fetchTimers.values.forEach { $0.invalidate() }
        fetchTimers.removeAll()
    }
    
    func fetchAllJobs() async {
        isLoading = true
        lastError = nil
        newJobsCount = 0
        fetchStatistics = FetchStatistics()
        
        var allNewJobs: [Job] = []
        var sourceJobsMap: [JobSource: [Job]] = [:]
        
        // Fetch from each enabled source
        if enableMicrosoft {
            do {
                let jobs = try await fetchFromSource(.microsoft)
                sourceJobsMap[.microsoft] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.microsoftJobs = jobs.count
            } catch {
                lastError = "Microsoft: \(error.localizedDescription)"
                // Keep existing Microsoft jobs if fetch fails
                if let existingJobs = jobsBySource[.microsoft] {
                    sourceJobsMap[.microsoft] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.microsoft] = []
        }
        
        if enableTikTok {
            do {
                let jobs = try await fetchFromSource(.tiktok)
                sourceJobsMap[.tiktok] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.tiktokJobs = jobs.count
            } catch {
                lastError = "TikTok: \(error.localizedDescription)"
                if let existingJobs = jobsBySource[.tiktok] {
                    sourceJobsMap[.tiktok] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.tiktok] = []
        }
        
        if enableApple {
            do {
                let jobs = try await fetchFromSource(.apple)
                sourceJobsMap[.apple] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.appleJobs = jobs.count
            } catch {
                lastError = "Apple: \(error.localizedDescription)"
                // Keep existing Apple jobs if fetch fails
                if let existingJobs = jobsBySource[.apple] {
                    sourceJobsMap[.apple] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.apple] = []
        }
        
        if enableSnap {
            do {
                let jobs = try await fetchFromSource(.snap)
                sourceJobsMap[.snap] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.appleJobs = jobs.count
            } catch {
                lastError = "Snap: \(error.localizedDescription)"
                if let existingJobs = jobsBySource[.snap] {
                    sourceJobsMap[.snap] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.snap] = []
        }
        
        if enableCustomBoards {
            let boardJobs = await JobBoardMonitor.shared.fetchAllBoardJobs(
                titleFilter: jobTitleFilter,
                locationFilter: locationFilter
            )
            
            for job in boardJobs {
                if sourceJobsMap[job.source] == nil {
                    sourceJobsMap[job.source] = []
                }
                sourceJobsMap[job.source]?.append(job)
            }
            
            let newBoardJobs = filterNewJobs(boardJobs)
            allNewJobs.append(contentsOf: newBoardJobs)
            fetchStatistics.customBoardJobs = boardJobs.count
        }
        
        jobsBySource = sourceJobsMap
        await processNewJobs(allNewJobs, sourceJobsMap: sourceJobsMap)
        isLoading = false
    }
    
    func selectJob(withId id: String) {
        if let job = allJobs.first(where: { $0.id == id }) {
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
        fetchTimers[source]?.invalidate()
        
        let interval = refreshInterval * 60
        
        fetchTimers[source] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { [weak self] in
                await self?.fetchJobsFromSource(source)
            }
        }
        
    }
    
    private func stopMonitoringSource(_ source: JobSource) {
        fetchTimers[source]?.invalidate()
        fetchTimers.removeValue(forKey: source)
    }
    
    private func fetchFromSource(_ source: JobSource) async throws -> [Job] {
        let titleKeywords = parseTitleKeywords()
        
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
        case .apple:
             return try await appleFetcher.fetchJobs(
                 titleKeywords: titleKeywords,
                 location: locationFilter,
                 maxPages: Int(maxPagesToFetch)
             )
        case .snap:
             return try await snapFetcher.fetchJobs(
                 titleKeywords: titleKeywords,
                 location: locationFilter,
                 maxPages: Int(maxPagesToFetch)
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
            
            jobsBySource[source] = jobs
            var sourceJobsMap = jobsBySource
            let newJobs = filterNewJobs(jobs)
            
            if !newJobs.isEmpty {
                await processNewJobs(newJobs, sourceJobsMap: sourceJobsMap)
            }
        } catch {
        }
    }
    
    private func filterNewJobs(_ jobs: [Job]) -> [Job] {
        return jobs.filter { job in
            !storedJobIds.contains(job.id)
        }
    }
    
    private func processNewJobs(_ newJobs: [Job], sourceJobsMap: [JobSource: [Job]]) async {
        newJobs.forEach { storedJobIds.insert($0.id) }
        
        var combinedJobs: [Job] = []
        for (_, sourceJobs) in sourceJobsMap {
            combinedJobs.append(contentsOf: sourceJobs)
        }
        
        var uniqueJobs: [Job] = []
        var seenIds = Set<String>()
        
        for job in combinedJobs {
            if !seenIds.contains(job.id) {
                uniqueJobs.append(job)
                seenIds.insert(job.id)
            }
        }
        
        uniqueJobs.sort { job1, job2 in
            let date1 = job1.postingDate ?? job1.firstSeenDate
            let date2 = job2.postingDate ?? job2.firstSeenDate
            return date1 > date2
        }
        
        allJobs = uniqueJobs
        newJobsCount = newJobs.count
        
        fetchStatistics.totalJobs = uniqueJobs.count
        fetchStatistics.newJobs = newJobsCount
        fetchStatistics.lastFetchTime = Date()
        
        if !newJobs.isEmpty {
            let recentNewJobs = newJobs.filter { job in
                if let postingDate = job.postingDate {
                    return Date().timeIntervalSince(postingDate) <= 7200 // 2 hours
                } else {
                    return Date().timeIntervalSince(job.firstSeenDate) <= 7200
                }
            }
            if !recentNewJobs.isEmpty {
                await notificationService.sendGroupedNotification(for: recentNewJobs)
            }
        }
        
        try? await persistenceService.saveJobs(allJobs)
        try? await persistenceService.saveStoredJobIds(storedJobIds)
        
        loadingProgress = ""
        
        for (source, jobs) in sourceJobsMap {
            if !jobs.isEmpty {
            }
        }
    }
    
    private func loadStoredData() async {
        do {
            let loadedJobs = try await persistenceService.loadJobs()
            
            jobsBySource = Dictionary(grouping: loadedJobs) { $0.source }
                .mapValues { Array($0) }
            
            allJobs = loadedJobs
            
            storedJobIds = try await persistenceService.loadStoredJobIds()
            appliedJobIds = try await persistenceService.loadAppliedJobIds()
            
            for (source, jobs) in jobsBySource {
            }
        } catch {
        }
    }
    
    private func parseTitleKeywords() -> [String] {
        guard !jobTitleFilter.isEmpty else { return [] }
        return jobTitleFilter
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
    var appleJobs: Int = 0
    var snapJobs: Int = 0
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
        if appleJobs > 0 {
            parts.append("Apple: \(appleJobs)")
        }
        if snapJobs > 0 {
            parts.append("Apple: \(appleJobs)")
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
