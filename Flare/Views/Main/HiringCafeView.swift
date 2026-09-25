import SwiftUI

struct HiringCafeView: View {
    @ObservedObject private var store = HiringCafeDailyStore.shared
    @State private var draftQuery = HiringCafeDailyStore.shared.query
    @State private var draftLocation = HiringCafeDailyStore.shared.locationQuery
    @State private var draftIncludeRemote = HiringCafeDailyStore.shared.includeRemote

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(FlareVisual.ink.opacity(0.16)).frame(height: 1)
            searchBar
            Rectangle().fill(FlareVisual.ink.opacity(0.12)).frame(height: 1)

            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                    if !store.jobs.isEmpty {
                        Text("Showing previously downloaded jobs.")
                    }
                    Link("Open HiringCafe", destination: URL(string: "https://hiringcafe.com")!)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(FlareVisual.paper)
            }

            if store.query.isEmpty && store.locationQuery.isEmpty {
                ContentUnavailableView("No daily search", systemImage: "cup.and.saucer")
            } else if store.isLoading && store.jobs.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(store.status)
                        .font(.caption)
                        .foregroundStyle(FlareVisual.fadedInk)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.errorMessage != nil, store.jobs.isEmpty {
                ContentUnavailableView("Could not load HiringCafe", systemImage: "exclamationmark.triangle")
            } else if store.matchedJobs.isEmpty {
                ContentUnavailableView("No matches in this daily batch", systemImage: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.matchedJobs) { job in
                            HiringCafeDailyRow(job: job) {
                                store.open(job)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .background(FlareVisual.canvas)
        .preferredColorScheme(.light)
        .task {
            await store.start()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                FlareLabel(text: "Latest available day")
                Text("HiringCafe Daily")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(FlareVisual.ink)
                    .accessibilityIdentifier("hiring-cafe.title")
            }

            Spacer()

            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Group {
                    if store.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading || (store.query.isEmpty && store.locationQuery.isEmpty))
            .help("Refresh daily feed")
            .accessibilityLabel("Refresh daily feed")
            .accessibilityIdentifier("hiring-cafe.reload")
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(FlareVisual.paper)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FlareVisual.fadedInk)

            TextField("engineering manager", text: $draftQuery)
                .textFieldStyle(.plain)
                .onSubmit { submitQuery() }
                .accessibilityIdentifier("hiring-cafe.search")

            Rectangle().fill(FlareVisual.ink.opacity(0.14)).frame(width: 1, height: 22)

            Image(systemName: "location")
                .foregroundStyle(FlareVisual.fadedInk)

            TextField("Seattle", text: $draftLocation)
                .textFieldStyle(.plain)
                .onSubmit { submitQuery() }
                .accessibilityIdentifier("hiring-cafe.location")

            Toggle("Include remote", isOn: $draftIncludeRemote)
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityIdentifier("hiring-cafe.include-remote")

            Button {
                submitQuery()
            } label: {
                Image(systemName: "arrow.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(FlareVisual.ember)
            .help("Search daily feed")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(FlareVisual.paper.opacity(0.72))
    }

    private func submitQuery() {
        Task {
            await store.updateSearch(
                query: draftQuery,
                location: draftLocation,
                includeRemote: draftIncludeRemote
            )
        }
    }
}

private struct HiringCafeDailyRow: View {
    let job: HiringCafeDailyJob
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.title3)
                    .foregroundStyle(FlareVisual.paper)
                    .frame(width: 36, height: 36)
                    .background(FlareVisual.ember, in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 5) {
                    Text(job.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(FlareVisual.ink)
                        .multilineTextAlignment(.leading)

                    Text(job.company)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(FlareVisual.soot)

                    HStack(spacing: 12) {
                        Label(job.location, systemImage: "location")
                        Label(job.category, systemImage: "tag")
                        Spacer()
                        Text(job.postedAt, style: .relative)
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.caption)
                    .foregroundStyle(FlareVisual.fadedInk)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open on HiringCafe")
    }
}
