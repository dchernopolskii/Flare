//
//  PersistenceService.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import Foundation

actor PersistenceService {
    static let shared = PersistenceService()
    
    private let appSupportURL: URL
    
    private init() {
        appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
        
        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    }
    
    // MARK: - Jobs
    func saveJobs(_ jobs: [Job]) async throws {
        let url = appSupportURL.appendingPathComponent("jobs.json")
        let data = try JSONEncoder().encode(jobs)
        try data.write(to: url)
    }
    
    func loadJobs() async throws -> [Job] {
        let url = appSupportURL.appendingPathComponent("jobs.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Job].self, from: data)
    }
    
    // MARK: - Stored Job IDs
    func saveStoredJobIds(_ ids: Set<String>) async throws {
        let url = appSupportURL.appendingPathComponent("storedIds.json")
        let data = try JSONEncoder().encode(Array(ids))
        try data.write(to: url)
    }
    
    func loadStoredJobIds() async throws -> Set<String> {
        let url = appSupportURL.appendingPathComponent("storedIds.json")
        let data = try Data(contentsOf: url)
        let ids = try JSONDecoder().decode([String].self, from: data)
        return Set(ids)
    }
    
    // MARK: - Applied Job IDs
    func saveAppliedJobIds(_ ids: Set<String>) async throws {
        let url = appSupportURL.appendingPathComponent("appliedJobs.json")
        let data = try JSONEncoder().encode(Array(ids))
        try data.write(to: url)
    }
    
    func loadAppliedJobIds() async throws -> Set<String> {
        let url = appSupportURL.appendingPathComponent("appliedJobs.json")
        let data = try Data(contentsOf: url)
        let ids = try JSONDecoder().decode([String].self, from: data)
        return Set(ids)
    }
    
    // MARK: - Board Configs
    func saveBoardConfigs(_ configs: [JobBoardConfig]) async throws {
        let url = appSupportURL.appendingPathComponent("boardConfigs.json")
        let data = try JSONEncoder().encode(configs)
        try data.write(to: url)
    }
    
    func loadBoardConfigs() async throws -> [JobBoardConfig] {
        let url = appSupportURL.appendingPathComponent("boardConfigs.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([JobBoardConfig].self, from: data)
    }
    
    // MARK: - Source-specific ID tracking
    func saveSourceJobIds(source: JobSource, ids: Set<String>) async throws {
        let url = appSupportURL.appendingPathComponent("\(source.rawValue.lowercased())JobIds.json")
        let data = try JSONEncoder().encode(Array(ids))
        try data.write(to: url)
    }
    
    func loadSourceJobIds(source: JobSource) async throws -> Set<String> {
        let url = appSupportURL.appendingPathComponent("\(source.rawValue.lowercased())JobIds.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Set<String>()
        }
        let data = try Data(contentsOf: url)
        let ids = try JSONDecoder().decode([String].self, from: data)
        return Set(ids)
    }
}
