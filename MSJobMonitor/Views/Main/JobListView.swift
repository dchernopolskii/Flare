//
//  JobListView.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI

struct JobListView: View {
    @EnvironmentObject var jobManager: JobManager
    @EnvironmentObject var boardMonitor: JobBoardMonitor
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool
    
    @State private var searchText = ""
    @State private var selectedSource: JobSource? = nil
    @State private var showOnlyNew = false
    @State private var showOnlyApplied = false

    var filteredJobs: [Job] {
        var result = jobManager.jobs
        
        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { job in
                job.title.localizedCaseInsensitiveContains(searchText) ||
                job.location.localizedCaseInsensitiveContains(searchText) ||
                job.companyName?.localizedCaseInsensitiveContains(searchText) ?? false ||
                job.department?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }
        
        // Filter by source
        if let source = selectedSource {
            result = result.filter { $0.source == source }
        }
        
        // Filter by new status
        if showOnlyNew {
            result = result.filter { job in
                // Jobs posted in the last 2 hours are considered "new"
                if let postingDate = job.postingDate {
                    return Date().timeIntervalSince(postingDate) < 7200
                } else {
                    return Date().timeIntervalSince(job.firstSeenDate) < 7200
                }
            }
        }
        
        // Filter by applied status
        if showOnlyApplied {
            result = result.filter { jobManager.isJobApplied($0) }
        }
        
        return result
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            JobListHeader(
                searchText: $searchText,
                selectedSource: $selectedSource,
                showOnlyNew: $showOnlyNew,
                showOnlyApplied: $showOnlyApplied
            )
            
            Divider()
            
            // Job List or Empty State
            if filteredJobs.isEmpty && !jobManager.isLoading {
                EmptyJobsView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredJobs) { job in
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
            
            // Error Banner
            if let error = jobManager.lastError {
                ErrorBanner(message: error)
            }
        }
    }
}

struct JobListHeader: View {
    @EnvironmentObject var jobManager: JobManager
    @EnvironmentObject var boardMonitor: JobBoardMonitor
    @Binding var searchText: String
    @Binding var selectedSource: JobSource?
    @Binding var showOnlyNew: Bool
    @Binding var showOnlyApplied: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            // Title and Actions
            HStack {
                Text("Jobs (Last 24 Hours)")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                // Source Filter
                Menu {
                    Button("All Sources") {
                        selectedSource = nil
                    }
                    Divider()
                    ForEach(JobSource.allCases, id: \.self) { source in
                        if source.isSupported {
                            Button(action: {
                                selectedSource = source == selectedSource ? nil : source
                            }) {
                                HStack {
                                    Image(systemName: source.icon)
                                    Text(source.rawValue)
                                    if source == selectedSource {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(selectedSource?.rawValue ?? "All Sources", systemImage: "line.3.horizontal.decrease.circle")
                }
                
                // Configure Job Boards
                Button(action: {
                    boardMonitor.showConfigSheet = true
                }) {
                    Label("Job Boards", systemImage: "gear")
                }
                .sheet(isPresented: $boardMonitor.showConfigSheet) {
                    JobBoardConfigSheet()
                }
                
                // Refresh Button
                Button(action: {
                    Task { await jobManager.fetchAllJobs() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(jobManager.isLoading)
            }
            .padding(.horizontal)
            .padding(.top)
            
            // Search and Filter Bar
            HStack(spacing: 12) {
                // Search Field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search jobs...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                // Filter Toggles
                Toggle(isOn: $showOnlyNew) {
                    Label("New", systemImage: "sparkles")
                        .foregroundColor(showOnlyNew ? .accentColor : .secondary)
                }
                .toggleStyle(.button)
                
                Toggle(isOn: $showOnlyApplied) {
                    Label("Applied", systemImage: "checkmark.circle")
                        .foregroundColor(showOnlyApplied ? .green : .secondary)
                }
                .toggleStyle(.button)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}

struct EmptyJobsView: View {
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("No jobs found")
                .font(.title3)
                .foregroundColor(.secondary)
            
            if jobManager.fetchStatistics.totalJobs > 0 {
                Text("Try adjusting your filters")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Check your filters in Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }
}