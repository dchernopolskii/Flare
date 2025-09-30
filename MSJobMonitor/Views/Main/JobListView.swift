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
    @State private var selectedSources: Set<JobSource> = Set(JobSource.allCases.filter { $0.isSupported })
    @State private var showOnlyNew = false
    @State private var showOnlyApplied = false

    var filteredJobs: [Job] {
        var result = jobManager.jobs
        
        if !searchText.isEmpty {
            result = result.filter { job in
                job.title.localizedCaseInsensitiveContains(searchText) ||
                job.location.localizedCaseInsensitiveContains(searchText) ||
                job.companyName?.localizedCaseInsensitiveContains(searchText) ?? false ||
                job.department?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }
        
        if !selectedSources.isEmpty {
            result = result.filter { selectedSources.contains($0.source) }
        }
        
        if showOnlyNew {
            result = result.filter { job in
                if let postingDate = job.postingDate {
                    return Date().timeIntervalSince(postingDate) < 7200
                } else {
                    return Date().timeIntervalSince(job.firstSeenDate) < 7200
                }
            }
        }
        
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
                selectedSources: $selectedSources,
                showOnlyNew: $showOnlyNew,
                showOnlyApplied: $showOnlyApplied
            )
            
            Divider()
            
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
    @Binding var selectedSources: Set<JobSource> // UPDATED: Set instead of single source
    @Binding var showOnlyNew: Bool
    @Binding var showOnlyApplied: Bool
    
    private var supportedSources: [JobSource] {
        JobSource.allCases.filter { $0.isSupported }
    }
    
    private var allSourcesSelected: Bool {
        selectedSources.count == supportedSources.count
    }
    
    private var someSourcesSelected: Bool {
        !selectedSources.isEmpty && selectedSources.count < supportedSources.count
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Title and Actions
            HStack {
                Text("Jobs (Last 24 Hours)")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Menu {
                    // All Sources toggle
                    Button(action: toggleAllSources) {
                        HStack {
                            Image(systemName: allSourcesSelected ? "checkmark.square.fill" :
                                                someSourcesSelected ? "minus.square.fill" : "square")
                            Text("All Sources")
                            Spacer()
                        }
                    }
                    
                    Divider()
                    
                    ForEach(supportedSources, id: \.self) { source in
                        Button(action: {
                            toggleSource(source)
                        }) {
                            HStack {
                                Image(systemName: selectedSources.contains(source) ? "checkmark.square.fill" : "square")
                                Image(systemName: source.icon)
                                Text(source.rawValue)
                                Spacer()
                            }
                        }
                    }
                } label: {
                    Label(sourceFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
                }
                
                Button(action: {
                    boardMonitor.showConfigSheet = true
                }) {
                    Label("Job Boards", systemImage: "gear")
                }
                .sheet(isPresented: $boardMonitor.showConfigSheet) {
                    JobBoardConfigSheet()
                }
                
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
    
    private var sourceFilterLabel: String {
        if allSourcesSelected {
            return "All Sources"
        } else if selectedSources.isEmpty {
            return "No Sources"
        } else if selectedSources.count == 1 {
            return selectedSources.first?.rawValue ?? "Unknown"
        } else {
            return "\(selectedSources.count) Sources"
        }
    }
    
    private func toggleAllSources() {
        if allSourcesSelected {
            // Uncheck all
            selectedSources.removeAll()
        } else {
            // Check all
            selectedSources = Set(supportedSources)
        }
    }
    
    private func toggleSource(_ source: JobSource) {
        if selectedSources.contains(source) {
            selectedSources.remove(source)
        } else {
            selectedSources.insert(source)
        }
    }
}

//struct JobListViewWithPropertyWrapper: View {
//    @EnvironmentObject var jobManager: JobManager
//    @EnvironmentObject var boardMonitor: JobBoardMonitor
//    @Binding var sidebarVisible: Bool
//    let isWindowMinimized: Bool
//    
//    @State private var searchText = ""
//    @State private var showOnlyNew = false
//    @State private var showOnlyApplied = false
//    
//    @PersistedJobSources private var selectedSources
//    
//    var filteredJobs: [Job] {
//        var result = jobManager.jobs
//        
//        // Filter by search text
//        if !searchText.isEmpty {
//            result = result.filter { job in
//                job.title.localizedCaseInsensitiveContains(searchText) ||
//                job.location.localizedCaseInsensitiveContains(searchText) ||
//                job.companyName?.localizedCaseInsensitiveContains(searchText) ?? false ||
//                job.department?.localizedCaseInsensitiveContains(searchText) ?? false
//            }
//        }
//        
//        if !selectedSources.isEmpty {
//            result = result.filter { selectedSources.contains($0.source) }
//        }
//        
//        if showOnlyNew {
//            result = result.filter { job in
//                if let postingDate = job.postingDate {
//                    return Date().timeIntervalSince(postingDate) < 7200
//                } else {
//                    return Date().timeIntervalSince(job.firstSeenDate) < 7200
//                }
//            }
//        }
//        
//        // Filter by applied status
//        if showOnlyApplied {
//            result = result.filter { jobManager.isJobApplied($0) }
//        }
//        
//        return result
//    }
//    
//    var body: some View {
//        VStack(spacing: 0) {
//            // Header
//            JobListHeader(
//                searchText: $searchText,
//                selectedSources: $selectedSources,
//                showOnlyNew: $showOnlyNew,
//                showOnlyApplied: $showOnlyApplied
//            )
//            
//            Divider()
//            
//            // Job List or Empty State
//            if filteredJobs.isEmpty && !jobManager.isLoading {
//                EmptyJobsView()
//            } else {
//                ScrollView {
//                    LazyVStack(alignment: .leading, spacing: 0) {
//                        ForEach(filteredJobs) { job in
//                            JobRow(
//                                job: job,
//                                sidebarVisible: $sidebarVisible,
//                                isWindowMinimized: isWindowMinimized
//                            )
//                            Divider()
//                        }
//                    }
//                }
//            }
//            
//            // Error Banner
//            if let error = jobManager.lastError {
//                ErrorBanner(message: error)
//            }
//        }
//    }
//}
//
//extension JobListView {
//
//    private func loadAllPersistedFilters() {
//        searchText = UserDefaults.standard.string(forKey: "jobSearchText") ?? ""
//        
//        showOnlyNew = UserDefaults.standard.bool(forKey: "showOnlyNewJobs")
//        showOnlyApplied = UserDefaults.standard.bool(forKey: "showOnlyAppliedJobs")
//        
//        loadPersistedSourceSelection()
//    }
//    
//    private func saveAllFilters() {
//        UserDefaults.standard.set(searchText, forKey: "jobSearchText")
//        
//        UserDefaults.standard.set(showOnlyNew, forKey: "showOnlyNewJobs")
//        UserDefaults.standard.set(showOnlyApplied, forKey: "showOnlyAppliedJobs")
//    }
//}

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
