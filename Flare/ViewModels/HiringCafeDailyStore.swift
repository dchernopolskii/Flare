import AppKit
import Foundation

@MainActor
final class HiringCafeDailyStore: ObservableObject {
    static let shared = HiringCafeDailyStore()

    @Published private(set) var query: String
    @Published private(set) var locationQuery: String
    @Published private(set) var includeRemote: Bool
    @Published private(set) var jobs: [HiringCafeDailyJob] = []
    @Published private(set) var matchedJobs: [HiringCafeDailyJob] = []
    @Published private(set) var batchDate: Date?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?

    private enum DefaultsKey {
        static let query = "hiringCafeDailyQuery"
        static let locationQuery = "hiringCafeDailyLocationQuery"
        static let includeRemote = "hiringCafeDailyIncludeRemote"
        static let seenIDs = "hiringCafeDailySeenIDs"
        static let seenQuery = "hiringCafeDailySeenQuery"
    }

    private let fetcher = HiringCafeDailyFetcher()
    private let persistence = PersistenceService.shared
    private var monitorTask: Task<Void, Never>?
    private var hasStarted = false
    private var browserVerificationRequired = false
    private var suppressNextNotification = false
    private var seenIDs: Set<String>

    private var currentSnapshot: HiringCafeDailySnapshot? {
        guard let batchDate else { return nil }
        return HiringCafeDailySnapshot(
            batchDate: batchDate,
            fetchedAt: lastChecked ?? Date.distantPast,
            jobs: jobs
        )
    }

    private init() {
        query = UserDefaults.standard.string(forKey: DefaultsKey.query) ?? ""
        locationQuery = UserDefaults.standard.string(forKey: DefaultsKey.locationQuery) ?? ""
        includeRemote = UserDefaults.standard.bool(forKey: DefaultsKey.includeRemote)
        seenIDs = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.seenIDs) ?? [])
        if UserDefaults.standard.string(forKey: DefaultsKey.seenQuery) != searchSignature {
            seenIDs = []
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        if let snapshot = try? await persistence.loadHiringCafeDailySnapshot() {
            apply(snapshot)
        }

        if hasSearch {
            await refresh()
        }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1_800))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func updateSearch(query newQuery: String, location newLocation: String, includeRemote newIncludeRemote: Bool) async {
        let normalizedQuery = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLocation = newLocation.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedQuery != query
                || normalizedLocation != locationQuery
                || newIncludeRemote != includeRemote else {
            await refresh(force: true)
            return
        }

        query = normalizedQuery
        locationQuery = normalizedLocation
        includeRemote = newIncludeRemote
        UserDefaults.standard.set(normalizedQuery, forKey: DefaultsKey.query)
        UserDefaults.standard.set(normalizedLocation, forKey: DefaultsKey.locationQuery)
        UserDefaults.standard.set(newIncludeRemote, forKey: DefaultsKey.includeRemote)
        suppressNextNotification = true
        updateMatches()
        seenIDs = Set(matchedJobs.map(\.id))
        persistSeenIDs()

        if hasSearch {
            await refresh(force: true)
        }
    }

    func refresh(force: Bool = false) async {
        guard hasSearch, !isLoading, force || !browserVerificationRequired else { return }
        isLoading = true
        errorMessage = nil
        status = "Checking HiringCafe for new jobs..."
        defer {
            isLoading = false
            status = ""
        }

        do {
            async let firstPageRequest = fetcher.fetchFirstPage()
            async let livePageRequest = fetcher.fetchLiveFirstPage(query: query)
            let firstPage = try await firstPageRequest
            browserVerificationRequired = false
            let liveFirstPage = try? await livePageRequest
            lastChecked = Date()

            let cachedSnapshot = currentSnapshot
            let cachedIDs = Set(cachedSnapshot?.jobs.map(\.id) ?? [])
            let firstLiveJobs = liveFirstPage?.jobs ?? []
            let pageHasNewJobs = (firstPage.jobs + firstLiveJobs).contains { !cachedIDs.contains($0.id) }
            let needsRefresh = force || jobs.isEmpty || pageHasNewJobs

            guard needsRefresh else {
                updateMatches()
                return
            }

            status = "Updating HiringCafe jobs..."
            let snapshot = try await fetcher.fetchLatestBatch(
                startingWith: firstPage,
                liveFirstPage: liveFirstPage ?? HiringCafeLivePage(page: 1, isLastPage: true, jobs: []),
                query: query,
                merging: cachedSnapshot
            )
            let previousSeenIDs = seenIDs
            apply(snapshot)
            try await persistence.saveHiringCafeDailySnapshot(snapshot)

            let newMatches = matchedJobs.filter { !previousSeenIDs.contains($0.id) }
            if suppressNextNotification {
                suppressNextNotification = false
            } else if !newMatches.isEmpty {
                await NotificationService.shared.sendHiringCafeDailyNotification(for: newMatches)
            }

            seenIDs.formUnion(matchedJobs.map(\.id))
            persistSeenIDs()
        } catch {
            if case HiringCafeDailyError.browserVerificationRequired = error {
                browserVerificationRequired = true
            }
            errorMessage = error.localizedDescription
            FetcherLog.error("HiringCafe Daily", error.localizedDescription)
        }
    }

    func open(_ job: HiringCafeDailyJob) {
        guard let url = job.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func apply(_ snapshot: HiringCafeDailySnapshot) {
        jobs = snapshot.jobs
        batchDate = snapshot.batchDate
        updateMatches()
    }

    private func updateMatches() {
        matchedJobs = hasSearch
            ? jobs.filter {
                $0.matches(
                    query: query,
                    locationQuery: locationQuery,
                    includeRemote: includeRemote
                )
            }
            : []
    }

    private func persistSeenIDs() {
        UserDefaults.standard.set(Array(seenIDs), forKey: DefaultsKey.seenIDs)
        UserDefaults.standard.set(searchSignature, forKey: DefaultsKey.seenQuery)
    }

    private var hasSearch: Bool { !query.isEmpty || !locationQuery.isEmpty }
    private var searchSignature: String { "\(query)\n\(locationQuery)\n\(includeRemote)" }
}
