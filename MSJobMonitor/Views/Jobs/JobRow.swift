//
//  JobRow.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI

struct JobRow: View {
    let job: Job
    @State private var isHovered = false
    @EnvironmentObject var jobManager: JobManager
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool
    
    private var isSelected: Bool {
        jobManager.selectedJob?.id == job.id
    }
    
    private var isNew: Bool {
        // Consider jobs posted in the last 2 hours as "new"
        if let postingDate = job.postingDate {
            return Date().timeIntervalSince(postingDate) < 7200
        } else {
            return Date().timeIntervalSince(job.firstSeenDate) < 7200
        }
    }
    
    private var timeText: String {
        if let postingDate = job.postingDate {
            return postingDate.formatted(date: .omitted, time: .shortened)
        } else {
            return job.firstSeenDate.formatted(date: .omitted, time: .shortened)
        }
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
                // Source Icon
                Image(systemName: job.source.icon)
                    .font(.title3)
                    .foregroundColor(job.source.color)
                    .frame(width: 30)
                
                // Job Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(job.title)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        if jobManager.isJobStarred(job) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                        }
                        
                        if isNew {
                            Badge(text: "NEW", color: .orange)
                        }
                        
                        if jobManager.isJobApplied(job) {
                            Badge(text: "APPLIED", color: .green)
                        }
                        
                        Spacer()
                    }
                    
                    // Location and Metadata
                    HStack {
                        Label(job.location, systemImage: "location")
                        Spacer()
                        HStack(spacing: 4) {
                            Text(timeText)
                            Text("•")
                            Text(job.companyName ?? job.source.rawValue)
                                .font(.caption2)
                                .foregroundColor(job.source.color)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    // Department/Category if available
                    if let department = job.department ?? job.category {
                        HStack {
                            Image(systemName: "folder")
                            Text(department)
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    
                    // Overview
                    if !job.overview.isEmpty {
                        Text(job.overview)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                
                Spacer()
                
                if isHovered || jobManager.isJobStarred(job) {
                    Button(action: {
                        jobManager.toggleStarred(for: job)
                    }) {
                        Image(systemName: jobManager.isJobStarred(job) ? "star.fill" : "star")
                            .foregroundColor(jobManager.isJobStarred(job) ? .yellow : .secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .foregroundColor(.secondary)
                    .opacity(isHovered || isSelected ? 1 : 0.5)
            }
            .padding()
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            JobRowContextMenu(job: job)
        }
    }
    
    private var rowBackground: some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.1)
            } else if jobManager.isJobStarred(job) {
                Color.yellow.opacity(0.05)
            } else if jobManager.isJobApplied(job) {
                Color.green.opacity(0.05)
            } else if isNew {
                Color.orange.opacity(0.03)
            } else if isHovered {
                Color.gray.opacity(0.05)
            } else {
                Color.clear
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
    }
}

struct JobRowContextMenu: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        Group {
            Button(action: {
                jobManager.toggleStarred(for: job)
            }) {
                if jobManager.isJobStarred(job) {
                    Label("Remove from favorites", systemImage: "star.slash")
                } else {
                    Label("Favorite", systemImage: "star")
                }
            }
            
            Button(action: {
                jobManager.toggleAppliedStatus(for: job)
            }) {
                if jobManager.isJobApplied(job) {
                    Label("Mark as Not Applied", systemImage: "xmark.circle")
                } else {
                    Label("Mark as Applied", systemImage: "checkmark.circle")
                }
            }
            
            Button(action: {
                jobManager.openJob(job)
            }) {
                Label("Open Job Page", systemImage: "arrow.up.right.square")
            }
            
            Button(action: {
                copyJobLink()
            }) {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            
            Divider()
            
            Text("Source: \(job.source.rawValue)")
                .font(.caption)
            
            if let company = job.companyName {
                Text("Company: \(company)")
                    .font(.caption)
            }
        }
    }
    
    private func copyJobLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(job.url, forType: .string)
    }
}
