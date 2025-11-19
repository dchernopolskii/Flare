//
//  JobListView.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import SwiftUI

@propertyWrapper
struct PersistedJobSources: DynamicProperty {
    @State private var value: Set<JobSource>
    let key: String
    
    var wrappedValue: Set<JobSource> {
        get { value }
        nonmutating set {
            value = newValue
            save()
        }
    }
    
    var projectedValue: Binding<Set<JobSource>> {
        Binding(
            get: { value },
            set: { newValue in
                value = newValue
                save()
            }
        )
    }
    
    init(wrappedValue: Set<JobSource> = Set(JobSource.allCases.filter { $0.isSupported }), key: String = "selectedJobSources") {
        self.key = key
        
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String].self, from: data),
           !decoded.isEmpty {
            let sources = decoded.compactMap { rawValue in
                JobSource(rawValue: rawValue)
            }.filter { $0.isSupported }
            
            if !sources.isEmpty {
                self._value = State(initialValue: Set(sources))
            } else {
                self._value = State(initialValue: wrappedValue)
            }
        } else {
            self._value = State(initialValue: wrappedValue)
        }
    }
    
    private func save() {
        let rawValues = value.map { $0.rawValue }
        if let encoded = try? JSONEncoder().encode(rawValues) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}

struct JobListView: View {
    @EnvironmentObject var jobManager: JobManager
    @EnvironmentObject var boardMonitor: JobBoardMonitor
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool
    
    @State private var searchText = UserDefaults.standard.string(forKey: "jobSearchText") ?? ""
    @PersistedJobSources private var selectedSources
    @State private var showOnlyStarred = UserDefaults.standard.bool(forKey: "showOnlyStarredJobs")
    @State private var showOnlyApplied = UserDefaults.standard.bool(forKey: "showOnlyAppliedJobs")

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
        
        if showOnlyStarred {
            result = result.filter { jobManager.isJobStarred($0) }
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
                showOnlyStarred: $showOnlyStarred,
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
            
            if let error = jobManager.lastError {
                ErrorBanner(message: error)
            }
        }
        .onChange(of: searchText) { newValue in
            UserDefaults.standard.set(newValue, forKey: "jobSearchText")
        }
        .onChange(of: showOnlyStarred) { newValue in
            UserDefaults.standard.set(newValue, forKey: "showOnlyStarredJobs")
        }
        .onChange(of: showOnlyApplied) { newValue in
            UserDefaults.standard.set(newValue, forKey: "showOnlyAppliedJobs")
        }
    }
}

struct JobListHeader: View {
    @EnvironmentObject var jobManager: JobManager
    @EnvironmentObject var boardMonitor: JobBoardMonitor
    @Binding var searchText: String
    @Binding var selectedSources: Set<JobSource>
    @Binding var showOnlyStarred: Bool
    @Binding var showOnlyApplied: Bool
    
    // Show all possible sources
    private var supportedSources: [JobSource] {
        // Return all supported source types
        return [.microsoft, .tiktok, .snap, .amd, .meta, .greenhouse, .lever, .ashby, .workday]
            .filter { $0.isSupported }
            .sorted { $0.rawValue < $1.rawValue }
    }
    
    private var allSourcesSelected: Bool {
        !supportedSources.isEmpty && supportedSources.allSatisfy { selectedSources.contains($0) }
    }
    
    private var someSourcesSelected: Bool {
        !selectedSources.isEmpty && selectedSources.contains { source in
            supportedSources.contains(source)
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Title and Actions
            HStack {
                Text("Jobs (Last 48 Hours)")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if !supportedSources.isEmpty {
                    Menu {
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
                                        .foregroundColor(source.color)
                                    Text(source.rawValue)
                                    
                                    // Show job count
                                    let count = jobManager.jobs.filter { $0.source == source }.count
                                    if count > 0 {
                                        Text("(\(count))")
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("(0)")
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }
                                    
                                    Spacer()
                                }
                            }
                        }
                    } label: {
                        Label(sourceFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    }
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
                Toggle(isOn: $showOnlyStarred) {
                    Label("Starred", systemImage: "star.fill")
                        .foregroundColor(showOnlyStarred ? .yellow : .secondary)
                }
                .toggleStyle(.button)
                
                Toggle(isOn: $showOnlyApplied) {
                    Label("Applied", systemImage: "checkmark.circle")
                        .foregroundColor(showOnlyApplied ? .green : .secondary)
                }
                .toggleStyle(.button)
                
                // Show filter status
                if !selectedSources.isEmpty && selectedSources.count < supportedSources.count {
                    Text("Filtered")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
    
    private var sourceFilterLabel: String {
        if supportedSources.isEmpty {
            return "No Sources"
        } else if allSourcesSelected {
            return "All Sources"
        } else if selectedSources.isEmpty {
            return "No Sources Selected"
        } else if selectedSources.count == 1 {
            return selectedSources.first?.rawValue ?? "Unknown"
        } else {
            let activeCount = selectedSources.filter { source in
                supportedSources.contains(source)
            }.count
            return "\(activeCount) Sources"
        }
    }
    
    private func toggleAllSources() {
        if allSourcesSelected {
            selectedSources.removeAll()
        } else {
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
