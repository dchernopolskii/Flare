//
//  JobBoardMonitor.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import Foundation
import SwiftUI

@MainActor
class JobBoardMonitor: ObservableObject {
    static let shared = JobBoardMonitor()
    
    @Published var boardConfigs: [JobBoardConfig] = []
    @Published var isMonitoring = false
    @Published var lastError: String?
    @Published var showConfigSheet = false
    @Published var testResults: [UUID: String] = [:]
    
    private let persistenceService = PersistenceService.shared
    private let greenhouseFetcher = GreenhouseFetcher()
    private var monitorTimer: Timer?
    
    private init() {
        Task {
            await loadConfigs()
        }
    }
    
    func loadConfigs() async {
        do {
            boardConfigs = try await persistenceService.loadBoardConfigs()
        } catch {
            print("Failed to load board configs: \(error)")
        }
    }
    
    func saveConfigs() async {
        do {
            try await persistenceService.saveBoardConfigs(boardConfigs)
        } catch {
            print("Failed to save board configs: \(error)")
        }
    }
    
    func addBoardConfig(_ config: JobBoardConfig) {
        boardConfigs.append(config)
        Task {
            await saveConfigs()
        }
    }
    
    func removeBoardConfig(at index: Int) {
        boardConfigs.remove(at: index)
        Task {
            await saveConfigs()
        }
    }
    
    func updateBoardConfig(_ config: JobBoardConfig) {
        if let index = boardConfigs.firstIndex(where: { $0.id == config.id }) {
            boardConfigs[index] = config
            Task {
                await saveConfigs()
            }
        }
    }
    
    func startMonitoring() async {
        monitorTimer?.invalidate()
        
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { [weak self] in
                await self?.fetchAllBoardJobs()
            }
        }
    }
    
    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }
    
    func testSingleBoard(_ config: JobBoardConfig) async {
        testResults[config.id] = "Testing..."
        
        do {
            let jobs = try await fetchJobsFromBoard(config, titleFilter: "", locationFilter: "")
            let message = "✅ Found \(jobs.count) jobs"
            testResults[config.id] = message
            
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
        
        for config in boardConfigs where config.isEnabled && config.isSupported {
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
        
        switch config.source {
        case .greenhouse:
            return try await greenhouseFetcher.fetchGreenhouseJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case .lever:
            return try await LeverFetcher().fetchJobs(
                titleKeywords: titleFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                location: locationFilter,
                maxPages: 1
            )
        case .workable, .jobvite, .bamboohr, .smartrecruiters, .ashby, .jazzhr, .recruitee, .breezyhr:
            throw FetchError.notImplemented(config.source.rawValue)
        default:
            return []
        }
    }
}
