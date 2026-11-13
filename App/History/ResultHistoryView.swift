import AppKit
import SwiftUI

enum ResultHistoryDateChoice: String, CaseIterable {
    case allTime, today, last7Days, last30Days, custom
    var titleKey: String {
        switch self {
        case .allTime: return "All time"
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        case .custom: return "Custom…"
        }
    }
}

// Keep the chosen civil dates when the system time zone changes.
struct ResultHistoryCalendarDays: Equatable {
    let first: DateComponents
    let last: DateComponents
    init(from first: Date, through last: Date, calendar: Calendar) {
        self.first = calendar.dateComponents([.era, .year, .month, .day], from: first)
        self.last = calendar.dateComponents([.era, .year, .month, .day], from: last)
    }
    func dates(in calendar: Calendar) -> (Date, Date)? {
        guard let first = calendar.date(from: first), let last = calendar.date(from: last) else { return nil }
        return (first, last)
    }
}

@MainActor final class ResultHistoryController: ObservableObject {
    @Published private(set) var entries: [ResultHistorySummary] = []
    @Published private(set) var selected: ResultHistoryEntry?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var canRetry = false
    @Published private(set) var writeIssue: String?
    @Published private(set) var searchQuery = ""
    @Published private(set) var canGoOlder = false
    @Published private(set) var canGoNewer = false
    @Published private(set) var hasSavedEntries = false
    @Published private(set) var taskFilter: ResultHistoryTask?
    @Published private(set) var dateChoice = ResultHistoryDateChoice.allTime
    @Published private(set) var customDays: ResultHistoryCalendarDays?
    private(set) var filter = ResultHistoryFilter()
    private let store: ResultHistoryStore
    private let copyText: (String) -> Bool
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var retention = ResultHistoryRetention.week
    private var operation: Task<Void, Never>?
    private var mutation: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var revision = UUID()
    private var selectionReadInFlight = false
    private var pendingSelection: UUID?
    private var pageCursors: [ResultHistoryCursor?] = [nil]
    private(set) var isPresented = false

    init(
        store: ResultHistoryStore, copyText: ((String) -> Bool)? = nil, now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .current }
    ) {
        self.store = store
        self.now = now
        self.calendar = calendar
        self.copyText =
            copyText ?? {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString($0, forType: .string)
            }
    }
    deinit {
        operation?.cancel()
        observation?.cancel()
    }
    func appear(enabled: Bool, retention: ResultHistoryRetention) {
        isPresented = true
        observation?.cancel()
        observation = Task { [weak self, store] in
            let stream = await store.changes()
            for await _ in stream {
                guard !Task.isCancelled, let self, self.isPresented else { return }
                self.refresh()
            }
        }
        configure(enabled: enabled, retention: retention)
    }
    func configure(enabled: Bool, retention: ResultHistoryRetention) {
        guard isPresented else { return }
        self.retention = retention
        let configuration = store.prepareConfiguration(enabled: enabled, retention: retention)
        mutate { [store] in
            try await store.configure(configuration)
        }
    }
    func reportWriteFailure(_ error: Error? = nil) {
        writeIssue = L10n.tr(
            (error as? ResultHistoryError) == .storageFull
                ? "History storage is full. Free up disk space and try again."
                : "Couldn’t save this result to history.")
    }
    func reportWriteSuccess() { writeIssue = nil }
    func refresh() {
        load()
    }
    func search(_ text: String) {
        guard isPresented else { return }
        searchQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
        resetQueryPage()
        load()
    }
    var currentCalendar: Calendar { calendar() }
    var canSelectEntries: Bool { isPresented && (!isLoading || selectionReadInFlight) }
    var hasActiveFilters: Bool { taskFilter != nil || dateChoice != .allTime }
    @discardableResult func setFilters(
        task: ResultHistoryTask?, date: ResultHistoryDateChoice, custom: ResultHistoryCalendarDays? = nil,
        search: String
    ) -> Bool {
        guard isPresented else { return false }
        let days = custom ?? customDays
        guard let resolved = resolveFilter(task: task, date: date, custom: days) else { return false }
        taskFilter = task
        dateChoice = date
        customDays = days
        filter = resolved
        searchQuery = search.trimmingCharacters(in: .whitespacesAndNewlines)
        resetQueryPage()
        load()
        return true
    }
    @discardableResult func setCustomDates(from first: Date, through last: Date, search: String) -> Bool {
        setFilters(
            task: taskFilter, date: .custom,
            custom: ResultHistoryCalendarDays(from: first, through: last, calendar: calendar()), search: search)
    }
    func resetFilters(search: String) {
        _ = setFilters(task: nil, date: .allTime, search: search)
    }
    func calendarChanged() { refresh() }
    private func resetQueryPage() {
        clearSelectionIntent()
        selected = nil
        entries = []
        pageCursors = [nil]
        canGoOlder = false
        canGoNewer = false
    }
    private func resolveFilter(
        task: ResultHistoryTask?, date: ResultHistoryDateChoice, custom: ResultHistoryCalendarDays?
    ) -> ResultHistoryFilter? {
        let calendar = calendar()
        let range: CoreHistoryDateRange?
        switch date {
        case .allTime: return .init(task: task)
        case .today: range = .recentDays(1, including: now(), calendar: calendar)
        case .last7Days: range = .recentDays(7, including: now(), calendar: calendar)
        case .last30Days: range = .recentDays(30, including: now(), calendar: calendar)
        case .custom:
            guard let (first, last) = custom?.dates(in: calendar) else { return nil }
            range = .days(from: first, through: last, calendar: calendar)
        }
        guard let range else { return nil }
        return .init(task: task, dateRange: range)
    }
    func older() {
        guard isPresented, !isLoading, canGoOlder, let last = entries.last else { return }
        pageCursors.append(ResultHistoryCursor(last))
        selected = nil
        load()
    }
    func newer() {
        guard isPresented, !isLoading, pageCursors.count > 1 else { return }
        pageCursors.removeLast()
        selected = nil
        load()
    }
    func latest() {
        guard isPresented, !isLoading else { return }
        pageCursors = [nil]
        selected = nil
        load()
    }
    func select(_ id: UUID) {
        guard isPresented, entries.contains(where: { $0.id == id }) else { return }
        if isLoading {
            // Native List selection can advance while a selected record is
            // loading. Query/mutation work still rejects old-page requests.
            if selectionReadInFlight { pendingSelection = id }
            return
        }
        selected = nil
        load(selecting: id)
    }
    private func clearSelectionIntent() {
        selectionReadInFlight = false
        pendingSelection = nil
    }
    func deleteSelected() {
        guard isPresented, let id = selected?.id else { return }
        let revocation = store.revokePendingWrites()
        selected = nil
        entries.removeAll { $0.id == id }
        mutate { [store] in try await store.delete(id: id, after: revocation) }
    }
    func clear() {
        guard isPresented else { return }
        let revocation = store.revokePendingWrites()
        selected = nil
        entries = []
        pageCursors = [nil]
        mutate { [store] in try await store.clear(after: revocation) }
    }
    func copy(source: Bool = false) {
        guard let entry = currentSelection() else { return }
        message = L10n.tr(copyText(source ? entry.source : entry.result) ? "Copied" : "Couldn’t copy. Try again.")
        canRetry = false
    }
    func currentSelection() -> ResultHistoryEntry? {
        guard isPresented, !isLoading, let selected, entries.contains(where: { $0.id == selected.id }) else {
            return nil
        }
        guard resolveFilter(task: taskFilter, date: dateChoice, custom: customDays) == filter else { return nil }
        if let seconds = retention.seconds, now() >= selected.summary.createdAt.addingTimeInterval(seconds) {
            return nil
        }
        if let task = filter.task, selected.summary.task != task { return nil }
        if let range = filter.dateRange,
            !(range.start <= selected.summary.createdAt && selected.summary.createdAt < range.end)
        {
            return nil
        }
        return selected
    }
    func disappear() {
        isPresented = false
        clearSelectionIntent()
        revision = UUID()
        operation?.cancel()
        observation?.cancel()
        operation = nil
        observation = nil
        entries = []
        selected = nil
        searchQuery = ""
        taskFilter = nil
        dateChoice = .allTime
        customDays = nil
        filter = .init()
        pageCursors = [nil]
        canGoOlder = false
        canGoNewer = false
        hasSavedEntries = false
        message = nil
        canRetry = false
        isLoading = false
    }
    // An accepted Clear/Delete/settings action outlives this presentation.
    // Closing cancels reads and publication, not a requested disk mutation.
    func waitForPendingChanges() async { await mutation?.value }
    #if YULLO_TESTING
        private(set) var testSelectionReadIDs: [UUID] = []
        func testEnqueueMutation(_ action: @escaping () async throws -> Void) { mutate(action) }
    #endif
    private func mutate(_ action: @escaping () async throws -> Void) {
        guard isPresented else { return }
        clearSelectionIntent()
        revision = UUID()
        let ticket = revision, previous = mutation
        operation?.cancel()
        operation = nil
        isLoading = true
        message = nil
        canRetry = false
        mutation = Task { [weak self] in
            await previous?.value
            do {
                try await action()
                guard let self, self.isPresented, self.revision == ticket else { return }
                self.refresh()
            } catch {
                guard let self, self.isPresented, self.revision == ticket else { return }
                self.selected = nil
                self.entries = []
                self.canRetry = true
                self.message = Self.failureMessage(error)
                self.isLoading = false
            }
        }
    }
    private func load(selecting requested: UUID? = nil) {
        guard isPresented else { return }
        clearSelectionIntent()
        guard let resolved = resolveFilter(task: taskFilter, date: dateChoice, custom: customDays) else {
            revision = UUID()
            operation?.cancel()
            selected = nil
            entries = []
            isLoading = false
            canRetry = true
            message = L10n.tr("Choose a valid date range.")
            return
        }
        if resolved != filter {
            filter = resolved
            resetQueryPage()
        }
        revision = UUID()
        let ticket = revision, previous = requested ?? selected?.id, pending = mutation
        let cursor = pageCursors.last ?? nil, query = searchQuery, filter = filter
        operation?.cancel()
        selectionReadInFlight = requested != nil
        #if YULLO_TESTING
            if let requested { testSelectionReadIDs.append(requested) }
        #endif
        isLoading = true
        message = nil
        canRetry = false
        operation = Task { [weak self, store] in
            do {
                await pending?.value
                try Task.checkCancellation()
                var page = try await store.page(before: cursor, search: query, filter: filter)
                let resetPage = page.entries.isEmpty && cursor != nil
                if resetPage { page = try await store.page(search: query, filter: filter) }
                let entries = page.entries
                try Task.checkCancellation()
                let selection = previous.flatMap { id in entries.first { $0.id == id }?.id } ?? entries.first?.id
                let selected: ResultHistoryEntry?
                if let selection { selected = try await store.entry(id: selection) } else { selected = nil }
                try Task.checkCancellation()
                guard let self, self.isPresented, self.revision == ticket else { return }
                self.entries = entries
                if resetPage { self.pageCursors = [nil] }
                self.canGoOlder = page.hasOlder
                self.canGoNewer = self.pageCursors.count > 1
                self.hasSavedEntries = page.hasSavedEntries
                if let pending = self.pendingSelection, pending != selection,
                    entries.contains(where: { $0.id == pending })
                {
                    // Keep the previous body unexportable and continue only
                    // the latest intent from this still-current page/read.
                    self.selected = nil
                    self.load(selecting: pending)
                    return
                }
                self.clearSelectionIntent()
                self.selected = selected
                self.isLoading = false
                self.operation = nil
            } catch is CancellationError {
                guard let self, self.revision == ticket else { return }
                self.clearSelectionIntent()
                self.isLoading = false
                self.operation = nil
            } catch {
                guard let self, self.isPresented, self.revision == ticket else { return }
                self.clearSelectionIntent()
                self.selected = nil
                self.entries = []
                self.canRetry = true
                self.message = Self.failureMessage(error)
                self.isLoading = false
                self.operation = nil
            }
        }
    }
    private static func failureMessage(_ error: Error) -> String {
        L10n.tr(
            (error as? ResultHistoryError) == .storageFull
                ? "History storage is full. Free up disk space and try again."
                : "History is unavailable. Try again.")
    }
}

struct ResultHistoryRetentionDraft {
    enum Unit: Int64, CaseIterable, Identifiable {
        case seconds = 1, minutes = 60, hours = 3600, days = 86400
        static let allCases: [Self] = [.minutes, .hours, .days]
        var id: Int64 { rawValue }
        var titleKey: String {
            switch self {
            case .seconds: return "Seconds"
            case .minutes: return "Minutes"
            case .hours: return "Hours"
            case .days: return "Days"
            }
        }
    }
    var number: String
    var unit: Unit
    var units: [Unit] { unit == .seconds ? [.seconds, .minutes, .hours, .days] : Unit.allCases }
    init(_ retention: ResultHistoryRetention) {
        let seconds = Int64(retention.seconds ?? (7 * 86400))
        unit = [.days, .hours, .minutes, .seconds].first { seconds % $0.rawValue == 0 } ?? .seconds
        number = String(seconds / unit.rawValue)
    }
    var value: ResultHistoryRetention? {
        guard !number.isEmpty, number.allSatisfy({ $0 >= "0" && $0 <= "9" }), let count = Int64(number), count > 0
        else { return nil }
        let result = count.multipliedReportingOverflow(by: unit.rawValue)
        guard !result.overflow else { return nil }
        return ResultHistoryRetention(rawValue: "seconds:\(result.partialValue)")
    }
}

#if YULLO_TESTING
    struct ResultHistoryReaderActions {
        let copy: () -> Void
        let use: () -> Void
        let translate: () -> Void
        let delete: () -> Void
    }
    struct ResultHistoryViewActions {
        let open: (UUID) -> Void
        let back: () -> Void
        let toggleOriginal: () -> Void
        let settings: () -> Void
        let dayGroups: () -> [[UUID]]
        let detailID: () -> UUID?
        let rowSelection: () -> UUID?
        let reader: () -> ResultHistoryReaderActions?
    }
#endif

@MainActor struct ResultHistoryView: View {
    @ObservedObject var controller: ResultHistoryController
    @Binding var enabled: Bool
    @Binding var retention: ResultHistoryRetention
    let useResult: (ResultHistoryEntry) -> Void
    let translateAgain: (ResultHistoryEntry) -> Void
    var embedded = false
    var manageHistory: (() -> Void)? = nil
    @Environment(\.locale) private var locale
    @Environment(\.localizedLanguageNames) private var localizedLanguageNames
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSettings = false
    @State private var searchDraft = ""
    @State private var detailID: UUID?
    @State private var selectedRow: UUID?
    @State private var showOriginal = false
    @State private var lastCopy: (id: UUID, source: Bool)?
    @State private var showCustomDates = false
    @State private var firstDate = Date()
    @State private var lastDate = Date()
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    #if YULLO_TESTING
        var yulloTestingCapture: ((ResultHistoryViewActions) -> Void)? = nil
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                HStack {
                    Text("History").font(.system(size: 20, weight: .semibold))
                    Spacer(minLength: 8)
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("History settings"))
                    .help(Text("History settings"))
                    .accessibilityIdentifier("history-settings").historyProbe("settings")
                    .popover(isPresented: $showSettings) {
                        ResultHistorySettingsView(controller: controller, enabled: $enabled, retention: $retention)
                    }
                }
            }
            if let issue = controller.writeIssue {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(issue).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Refresh") { controller.refresh() }.controlSize(.small)
                }.accessibilityIdentifier("history-write-issue").historyProbe("write-issue")
            }
            GeometryReader { geometry in
                let wide = geometry.size.width >= 660
                if wide {
                    VStack(spacing: 12) {
                        queryControls
                        HStack(spacing: 16) {
                            browser.frame(width: 250)
                            Divider()
                            reader(back: false)
                        }.frame(maxHeight: .infinity)
                    }
                } else {
                    ZStack {
                        VStack(spacing: 10) {
                            queryControls
                            browser
                        }
                        .opacity(detailID == nil ? 1 : 0).allowsHitTesting(detailID == nil)
                        .accessibilityHidden(detailID != nil)
                        if detailID != nil { reader(back: true) }
                    }
                }
            }
        }
        .padding(embedded ? 0 : 16).frame(minWidth: embedded ? 0 : 360, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            searchDraft = ""
            controller.appear(enabled: enabled, retention: retention)
            #if YULLO_TESTING
                yulloTestingCapture?(
                    .init(
                        open: open, back: closeReader, toggleOriginal: { showOriginal.toggle() },
                        settings: presentSettings, dayGroups: { summaryDays.map { $0.entries.map(\.id) } },
                        detailID: { detailID }, rowSelection: { selectedRow },
                        reader: {
                            guard let entry = currentReader() else { return nil }
                            let id = entry.id, source = showOriginal
                            return .init(
                                copy: { copyVisible(id: id, source: source) }, use: { useVisible(id: id) },
                                translate: { translateVisible(id: id) }, delete: { deleteVisible(id: id) })
                        }))
            #endif
        }
        .onChange(of: enabled) { _, value in controller.configure(enabled: value, retention: retention) }
        .onChange(of: retention) { _, value in controller.configure(enabled: enabled, retention: value) }
        .onChange(of: controller.canSelectEntries) { _, canSelect in
            if !canSelect, let selectedRow, selectedRow != controller.selected?.id {
                self.selectedRow = controller.selected?.id
            }
        }
        .onChange(of: controller.isLoading) { _, loading in
            if !loading {
                if let detailID, controller.currentSelection()?.id != detailID { closeReader() }
                if let selectedRow, !controller.entries.contains(where: { $0.id == selectedRow }) {
                    self.selectedRow = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in controller.calendarChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            showCustomDates = false
            controller.calendarChanged()
        }
        .onDisappear {
            showCustomDates = false
            detailID = nil
            controller.disappear()
        }
    }
    private var queryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search history", text: $searchDraft).textFieldStyle(.roundedBorder)
                    .onSubmit(performSearch).focused($searchFocused).accessibilityIdentifier("history-search")
                    .task(id: searchDraft) {
                        // Results follow typing after a short pause; Return still searches at once.
                        guard searchDraft != controller.searchQuery else { return }
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled,
                            searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                != controller.searchQuery
                        else { return }
                        performSearch()
                    }
                    .historyProbe("search")
                Button(action: performSearch) { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel(Text("Search history")).help(Text("Search history"))
                if !searchDraft.isEmpty || !controller.searchQuery.isEmpty {
                    Button {
                        searchDraft = ""
                        performSearch()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .accessibilityLabel(Text("Clear search")).help(Text("Clear search"))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    typeMenu
                    dateMenu
                    resetFilterControl
                    Spacer(minLength: 0)
                    browserStatus
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        typeMenu
                        dateMenu
                    }
                    HStack(spacing: 8) {
                        resetFilterControl
                        Spacer(minLength: 0)
                        browserStatus
                    }
                }
            }
        }
    }
    @ViewBuilder private var browserStatus: some View {
        if !enabled, controller.hasSavedEntries {
            Text("Saving off").font(.system(size: 11)).foregroundStyle(.secondary).historyProbe("saving-off")
        }
        if controller.isLoading, !controller.entries.isEmpty, detailID == nil {
            ProgressView().controlSize(.small).accessibilityLabel(Text("Loading…")).historyProbe("loading")
        }
    }
    @ViewBuilder private var resetFilterControl: some View {
        if controller.hasActiveFilters {
            Button {
                resetNavigation()
                controller.resetFilters(search: searchDraft)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }.controlSize(.small).accessibilityLabel(Text("Reset filters")).help(Text("Reset filters"))
                .accessibilityIdentifier("history-filter-reset").historyProbe("filter-reset")
        }
    }
    private func presentSettings() {
        if let manageHistory { manageHistory() } else { showSettings = true }
    }
    private func performSearch() {
        resetNavigation()
        controller.search(searchDraft)
    }
    private func applyFilters(task: ResultHistoryTask?, date: ResultHistoryDateChoice) {
        resetNavigation()
        _ = controller.setFilters(task: task, date: date, search: searchDraft)
    }
    private func resetNavigation() {
        detailID = nil
        selectedRow = nil
        showOriginal = false
    }
    private func closeReader() {
        detailID = nil
        showOriginal = false
        listFocused = true
    }
    private func open(_ id: UUID) {
        guard !controller.isLoading, controller.entries.contains(where: { $0.id == id }) else { return }
        listFocused = false
        searchFocused = false
        lastCopy = nil
        selectedRow = id
        detailID = id
        showOriginal = false
        if controller.currentSelection()?.id != id { controller.select(id) }
    }
    private var browser: some View {
        VStack(spacing: 8) {
            if controller.canRetry, let message = controller.message {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Button("Refresh") { controller.refresh() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityIdentifier("history-message").historyProbe("message")
            } else if controller.entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if controller.isLoading {
                        ProgressView().accessibilityLabel(Text("Loading…"))
                    } else if controller.hasSavedEntries {
                        Text("No matching results").font(.system(size: 16, weight: .semibold))
                        if controller.hasActiveFilters {
                            Button("Reset filters") {
                                resetNavigation()
                                controller.resetFilters(search: searchDraft)
                            }
                        }
                    } else {
                        Text("No saved results").font(.system(size: 16, weight: .semibold))
                        Text("Translations, dictation and writing appear here.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        if !enabled, !embedded || manageHistory != nil {
                            Button("Set up history…", action: presentSettings).accessibilityIdentifier("history-setup")
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(
                    selection: Binding(
                        get: { selectedRow },
                        set: { value in
                            guard controller.canSelectEntries else { return }
                            selectedRow = value
                            if let value { controller.select(value) }
                        })
                ) {
                    ForEach(summaryDays, id: \.date) { group in
                        Section {
                            ForEach(group.entries) { entry in summaryButton(entry) }
                        } header: {
                            Text(
                                group.date,
                                format: Date.FormatStyle(
                                    date: .abbreviated, time: .omitted,
                                    locale: locale, calendar: controller.currentCalendar,
                                    timeZone: controller.currentCalendar.timeZone)
                            )
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .textCase(nil).padding(.top, 1).padding(.bottom, 3)
                            .historyProbe("day-" + String(group.date.timeIntervalSince1970))
                        }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).focused($listFocused)
                    .historyProbe("list").accessibilityIdentifier("history-list")
                    .disabled(!controller.canSelectEntries)
                    .onKeyPress(.return) {
                        if let selectedRow {
                            open(selectedRow)
                            return .handled
                        }
                        return .ignored
                    }
                    // ⌘C copies the selected row's result without opening it.
                    .onCopyCommand {
                        guard let selectedRow, let entry = controller.currentSelection(), entry.id == selectedRow
                        else { return [] }
                        return [NSItemProvider(object: entry.result as NSString)]
                    }
            }
            if controller.canGoNewer || controller.canGoOlder {
                HStack(spacing: 10) {
                    Button("Latest") {
                        resetNavigation()
                        controller.latest()
                    }
                    .disabled(controller.isLoading || !controller.canGoNewer)
                    Spacer(minLength: 0)
                    Button("Newer") {
                        resetNavigation()
                        controller.newer()
                    }
                    .disabled(controller.isLoading || !controller.canGoNewer)
                    Button("Older") {
                        resetNavigation()
                        controller.older()
                    }
                    .disabled(controller.isLoading || !controller.canGoOlder)
                }.controlSize(.small).accessibilityIdentifier("history-pagination").historyProbe("pagination")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var summaryDays: [(date: Date, entries: [ResultHistorySummary])] {
        let calendar = controller.currentCalendar
        let groups = Dictionary(grouping: controller.entries) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { (date: $0, entries: groups[$0] ?? []) }
    }
    private func summarySymbol(_ task: ResultHistoryTask) -> String {
        switch task {
        case .translation: return "translate"
        case .dictation: return "mic"
        case .writing: return "pencil"
        }
    }
    private func summaryLanguages(_ entry: ResultHistorySummary) -> String {
        guard entry.task == .translation else { return "" }
        var values = [entry.sourceLanguage, entry.targetLanguage].compactMap { $0 }
        if values.count == 2, values[0] == values[1] { values.removeLast() }
        return values.map { Language.displayName(for: $0, localized: localizedLanguageNames, locale: locale) }.joined(
            separator: " → ")
    }
    private func summaryButton(_ entry: ResultHistorySummary) -> some View {
        Button {
            open(entry.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: summarySymbol(entry.task)).font(.system(size: 14))
                    .foregroundStyle(.secondary).frame(width: 18, height: 19).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.preview).font(.system(size: 13, weight: .regular)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Text(LocalizedStringKey(entry.task.titleKey))
                            if !summaryLanguages(entry).isEmpty {
                                Text("·")
                                Text(summaryLanguages(entry))
                            }
                            Spacer(minLength: 5)
                            summaryTime(entry)
                        }
                        HStack(spacing: 5) {
                            Text(LocalizedStringKey(entry.task.titleKey))
                            Spacer(minLength: 5)
                            summaryTime(entry)
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(
                            selectedRow == entry.id
                                ? Color.clear : Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            selectedRow == entry.id ? Color.clear : Color.primary.opacity(0.085), lineWidth: 0.5)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle()).historyProbe("row-" + entry.id.uuidString)
        }.buttonStyle(.plain).tag(entry.id)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("history-entry-" + entry.id.uuidString)
    }
    private func summaryTime(_ entry: ResultHistorySummary) -> some View {
        Text(
            entry.createdAt,
            format: Date.FormatStyle(
                date: .omitted,
                time: .shortened, locale: locale, calendar: controller.currentCalendar,
                timeZone: controller.currentCalendar.timeZone))
    }
    private func currentReader() -> ResultHistoryEntry? {
        guard let detailID, let entry = controller.currentSelection(), entry.id == detailID else { return nil }
        return entry
    }
    private func copyVisible(id: UUID, source: Bool) {
        guard currentReader()?.id == id, showOriginal == source else { return }
        controller.copy(source: source)
        lastCopy = (id, source)
    }
    private func useVisible(id: UUID) {
        if let entry = currentReader(), entry.id == id { useResult(entry) }
    }
    private func translateVisible(id: UUID) {
        if let entry = currentReader(), entry.id == id { translateAgain(entry) }
    }
    private func deleteVisible(id: UUID) {
        guard currentReader()?.id == id else { return }
        controller.deleteSelected()
        resetNavigation()
    }
    @ViewBuilder private func reader(back: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if back {
                    Button(action: closeReader) { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.link).keyboardShortcut("[", modifiers: .command)
                        .accessibilityIdentifier("history-back").historyProbe("back")
                }
                if showOriginal {
                    Text("Original").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let entry = controller.selected, entry.id == detailID {
                    Text(LocalizedStringKey(entry.summary.task.titleKey)).font(.system(size: 11)).foregroundStyle(
                        .secondary)
                    Menu {
                        Button("Translate again") {
                            translateVisible(id: entry.id)
                        }
                        Divider()
                        Button("Delete result", role: .destructive) { deleteVisible(id: entry.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                    .disabled(currentReader() == nil).accessibilityLabel(Text("Result actions"))
                    if controller.isLoading {
                        ProgressView().controlSize(.small).accessibilityLabel(Text("Loading…"))
                    }
                }
            }
            if let entry = controller.selected, entry.id == detailID {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.summary.createdAt, format: .dateTime.locale(locale).year().month().day().hour().minute())
                    Text(metadata(entry.summary))
                }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let source = showOriginal
                ResultHistoryText(
                    text: source ? entry.source : entry.result,
                    identifier: showOriginal ? "history-original-text" : "history-result-text",
                    isCurrent: { currentReader()?.id == entry.id && self.showOriginal == source }
                )
                .id(showOriginal).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text(LocalizedStringKey(showOriginal ? "Original" : "Result"))).historyProbe(
                    "reader")
                if let message = controller.message, !controller.canRetry,
                    lastCopy?.id == entry.id, lastCopy?.source == showOriginal
                {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("history-copy-feedback")
                }
                readerActions(id: entry.id, source: source)
            } else {
                VStack(spacing: 10) {
                    if controller.isLoading {
                        ProgressView().accessibilityLabel(Text("Loading…"))
                    } else if controller.canRetry, let message = controller.message {
                        Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Button("Refresh") { controller.refresh() }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private func readerActions(id: UUID, source: Bool) -> some View {
        let original = Button(LocalizedStringKey(showOriginal ? "View result" : "View original")) {
            guard currentReader()?.id == id else { return }
            showOriginal.toggle()
        }.buttonStyle(.link).font(.system(size: 12)).accessibilityIdentifier("history-toggle-original")
        let use = Button("Use result") { useVisible(id: id) }
            .disabled(currentReader() == nil).accessibilityIdentifier("history-use").historyProbe("use")
        let copy = Button(LocalizedStringKey(showOriginal ? "Copy original" : "Copy result")) {
            copyVisible(id: id, source: source)
        }.disabled(currentReader() == nil)
            .accessibilityIdentifier(showOriginal ? "history-copy-original" : "history-copy-result")
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                original
                Spacer(minLength: 4)
                use
                copy
            }
            VStack(alignment: .leading, spacing: 9) {
                original
                HStack(spacing: 10) {
                    Spacer(minLength: 4)
                    use
                    copy
                }
            }
        }
    }
    private func metadata(_ entry: ResultHistorySummary) -> String {
        var ids = [entry.sourceLanguage, entry.targetLanguage].compactMap { $0 }
        if ids.count == 2, ids[0] == ids[1] { ids.removeLast() }
        let languages = ids.map { Language.displayName(for: $0, localized: localizedLanguageNames, locale: locale) }
            .joined(separator: " → ")
        let delivery: String
        switch entry.delivery {
        case .inserted: delivery = "Inserted"
        case .notInserted: delivery = "Not inserted"
        case .uncertain: delivery = "Insertion not confirmed"
        }
        return [languages, L10n.tr(delivery)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var typeMenu: some View {
        Picker(
            L10n.tr("Result type"),
            selection: Binding(
                get: { controller.taskFilter },
                set: { applyFilters(task: $0, date: controller.dateChoice) })
        ) {
            Text(L10n.tr("All types")).tag(Optional<ResultHistoryTask>.none)
            ForEach(ResultHistoryTask.allCases, id: \.self) { task in
                Text(L10n.tr(task.titleKey)).tag(Optional(task))
            }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        .accessibilityLabel(L10n.tr("Result type"))
        .accessibilityIdentifier("history-type-filter").historyProbe("type-filter")
    }
    private func chooseDate(_ choice: ResultHistoryDateChoice) {
        if choice == .custom {
            let draft = controller.customDays?.dates(in: controller.currentCalendar)
            firstDate = draft?.0 ?? controller.filter.dateRange?.start ?? Date()
            lastDate = draft?.1 ?? Date()
            showCustomDates = true
        } else {
            applyFilters(task: controller.taskFilter, date: choice)
        }
    }
    private var dateMenu: some View {
        Menu {
            ForEach(ResultHistoryDateChoice.allCases, id: \.self) { choice in
                // The menu's own checkmark marks the current choice; choosing it again reapplies it.
                Toggle(
                    L10n.tr(choice.titleKey),
                    isOn: Binding(get: { controller.dateChoice == choice }, set: { _ in chooseDate(choice) })
                )
                .toggleStyle(.automatic)
            }
        } label: {
            Text(dateSelectionLabel)
        }
        .menuStyle(.borderedButton).fixedSize()
        .popover(isPresented: $showCustomDates) { customDateControls }
        .accessibilityLabel(L10n.tr("Date range")).accessibilityValue(dateSelectionLabel)
        .accessibilityIdentifier("history-date-filter").historyProbe("date-filter")
    }
    private var dateSelectionLabel: String {
        guard controller.dateChoice == .custom,
            let (first, last) = controller.customDays?.dates(in: controller.currentCalendar)
        else { return L10n.tr(controller.dateChoice.titleKey) }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = controller.currentCalendar
        formatter.timeZone = controller.currentCalendar.timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: first, to: last)
    }
    private var customDateControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Date range")).font(.headline)
            DatePicker(L10n.tr("Start date"), selection: $firstDate, displayedComponents: .date)
                .accessibilityIdentifier("history-date-from")
            DatePicker(L10n.tr("End date"), selection: $lastDate, displayedComponents: .date)
                .accessibilityIdentifier("history-date-through")
            if !customDatesValid {
                Text(L10n.tr("Choose a valid date range.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.tr("Cancel")) { showCustomDates = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("Apply")) {
                    if controller.setCustomDates(from: firstDate, through: lastDate, search: searchDraft) {
                        resetNavigation()
                        showCustomDates = false
                    }
                }.disabled(!customDatesValid).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("history-date-apply")
            }
        }.padding(16).frame(width: 300).environment(\.calendar, controller.currentCalendar)
    }
    private var customDatesValid: Bool {
        CoreHistoryDateRange.days(from: firstDate, through: lastDate, calendar: controller.currentCalendar) != nil
    }
}

@MainActor struct ResultHistorySettingsView: View {
    @ObservedObject var controller: ResultHistoryController
    @Binding var enabled: Bool
    @Binding var retention: ResultHistoryRetention
    @State private var confirmClear = false
    @State private var showCustomRetention = false
    @State private var retentionDraft = ResultHistoryRetentionDraft(.week)
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History settings").font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Toggle("Save new results", isOn: $enabled).toggleStyle(.switch)
                .accessibilityIdentifier("history-enabled").historyProbe("enabled")
            HStack(spacing: 12) {
                Text("Keep for")
                Spacer(minLength: 8)
                Menu {
                    ForEach(ResultHistoryRetention.allCases) { value in
                        Button(LocalizedStringKey(value.titleKey)) {
                            retention = value
                            showCustomRetention = false
                        }
                    }
                    Divider()
                    Button("Custom…") {
                        retentionDraft = ResultHistoryRetentionDraft(retention)
                        showCustomRetention = true
                    }.accessibilityIdentifier("history-retention-custom")
                } label: {
                    Text(retentionSelectionLabel)
                }
                .menuStyle(.borderedButton).accessibilityLabel(Text("Keep for"))
                .accessibilityIdentifier("history-retention").historyProbe("retention")
            }
            if showCustomRetention {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Keep for", text: $retentionDraft.number).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("history-custom-number")
                        Picker("Unit", selection: $retentionDraft.unit) {
                            ForEach(retentionDraft.units) { unit in
                                Text(LocalizedStringKey(unit.titleKey)).tag(unit)
                            }
                        }.labelsHidden().accessibilityIdentifier("history-custom-unit")
                    }
                    if retentionDraft.value == nil {
                        Text("Enter a positive duration.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Cancel") { showCustomRetention = false }
                        Spacer()
                        Button("Apply") {
                            if let value = retentionDraft.value {
                                retention = value
                                showCustomRetention = false
                            }
                        }.disabled(retentionDraft.value == nil).accessibilityIdentifier("history-custom-apply")
                    }
                }
            }
            Divider()
            Button("Clear all history…", role: .destructive) { confirmClear = true }
                .disabled(!controller.hasSavedEntries || controller.isLoading)
                .accessibilityIdentifier("history-clear").historyProbe("clear")
        }.font(.system(size: 13)).padding(18).frame(width: 330)
            .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
                Button("Clear all history", role: .destructive) { controller.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every saved result, including results hidden by search or filters.")
            }
    }
    private var retentionSelectionLabel: String {
        guard let seconds = retention.seconds, !ResultHistoryRetention.allCases.contains(retention) else {
            return L10n.tr(retention.titleKey)
        }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits =
            seconds >= 86400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? String(Int64(seconds))
    }
}

private struct ResultHistoryText: NSViewRepresentable {
    let text: String
    let identifier: String
    let isCurrent: () -> Bool
    final class TextView: NSTextView {
        var isCurrent: () -> Bool = { false }
        override func copy(_ sender: Any?) { if isCurrent() { super.copy(sender) } }
        override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
            isCurrent() ? super.writablePasteboardTypes : []
        }
        override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            isCurrent() && super.writeSelection(to: pasteboard, type: type)
        }
        override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
            isCurrent() && super.writeSelection(to: pasteboard, types: types)
        }
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = TextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textColor = .labelColor
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.writingToolsBehavior = .none
        view.font = .systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.drawsBackground = false
        scroll.drawsBackground = false
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TextView else { return }
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.isCurrent = isCurrent
        if !view.string.utf16.elementsEqual(text.utf16) { view.string = text }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        guard let view = scroll.documentView as? TextView else { return }
        view.isCurrent = { false }
        view.string = ""
    }
}

private extension View {
    @ViewBuilder func historyProbe(_ id: String) -> some View {
        #if YULLO_TESTING
            self.background(ResultHistoryBoundsProbe(id: id))
        #else
            self
        #endif
    }
}
#if YULLO_TESTING
    struct ResultHistoryBoundsProbe: NSViewRepresentable {
        let id: String
        @Environment(\.isEnabled) private var isEnabled
        final class Probe: NSView {
            var probeID = ""
            var isEnabledInView = false
        }
        func makeNSView(context: Context) -> Probe {
            let view = Probe()
            view.probeID = id
            view.isEnabledInView = isEnabled
            return view
        }
        func updateNSView(_ nsView: Probe, context: Context) {
            nsView.probeID = id
            nsView.isEnabledInView = isEnabled
        }
    }
#endif

#if YULLO_TESTING
    extension ResultHistoryView {
        @MainActor static func testReader(
            text: String, isCurrent: @escaping () -> Bool
        ) -> (view: NSView, update: @MainActor (String) -> Void) {
            let host = NSHostingView(
                rootView: ResultHistoryText(
                    text: text, identifier: "generated-history-reader", isCurrent: isCurrent))
            host.sizingOptions = []
            return (
                host,
                { value in
                    host.rootView = ResultHistoryText(
                        text: value, identifier: "generated-history-reader", isCurrent: isCurrent)
                }
            )
        }
    }
#endif
