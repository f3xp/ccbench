import Foundation
import Testing
@preconcurrency import Combine
import AXKitCore
@testable import axkit_playground

// Hidden acceptance suite for ZP-001 (ZPTaskListing). Injected into the test
// target only at scoring time — the agent never sees it. Reuses the shared
// `dispatchAndAwaitState` / `dispatchAndAwait` / `OutputCapture` helpers from
// the test target's Helpers/DispatchHelpers.swift.

// MARK: - Mock DataSource

private final class AxbenchMockTaskListDataSource: AXPTaskListDataSource, @unchecked Sendable {

    var fetchResult: AnyPublisher<AXPTaskListPage, Error> =
        Just(AXPTaskListPage(tasks: [], hasMore: false))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()

    var updateResult: AnyPublisher<AXPTask, Error>?

    private(set) var fetchCallCount = 0
    private(set) var lastFetchFrom: Int?
    private(set) var updateCallCount = 0
    private(set) var lastUpdateStatus: AXPTaskStatus?

    func fetchTasks(props: AXPTaskListProps, from: Int, limit: Int)
        -> AnyPublisher<AXPTaskListPage, Error> {
        fetchCallCount += 1
        lastFetchFrom = from
        return fetchResult
    }

    func updateTaskStatus(id: String, status: AXPTaskStatus)
        -> AnyPublisher<AXPTask, Error> {
        updateCallCount += 1
        lastUpdateStatus = status
        if let result = updateResult { return result }
        return Just(AXPTask(id: id, title: "Updated", status: status))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}

// MARK: - Fixtures

private let openTask = AXPTask(
    id: "t1", title: "Open Task",
    status: AXPTaskStatus(kind: .open, id: "s1", name: "Open", colorHex: "#1abc9c"),
    completionPercentage: 10)
private let progressTask = AXPTask(
    id: "t2", title: "In Progress Task",
    status: AXPTaskStatus(kind: .inProgress, id: "s2", name: "In Progress", colorHex: "#f1c40f"),
    completionPercentage: 50)
private let closedTask = AXPTask(
    id: "t3", title: "Closed Task",
    status: AXPTaskStatus(kind: .closed, id: "s3", name: "Closed", colorHex: "#e74c3c"),
    completionPercentage: 100)
private let sampleTasks = [openTask, progressTask, closedTask]

private func page(_ tasks: [AXPTask], hasMore: Bool = false) -> AnyPublisher<AXPTaskListPage, Error> {
    Just(AXPTaskListPage(tasks: tasks, hasMore: hasMore))
        .setFailureType(to: Error.self)
        .eraseToAnyPublisher()
}

private func failingPage() -> AnyPublisher<AXPTaskListPage, Error> {
    Fail(error: NSError(domain: "Axbench", code: -1)).eraseToAnyPublisher()
}

// MARK: - Suite

@Suite("AxbenchProjectTaskListAcceptance")
@MainActor
struct AxbenchProjectTaskListAcceptance {

    private func makeSUT(
        _ ds: AxbenchMockTaskListDataSource = AxbenchMockTaskListDataSource()
    ) -> (AXPTaskListBlockModel, OutputCapture<AXPTaskListOutput>, AxbenchMockTaskListDataSource) {
        let outputs = OutputCapture<AXPTaskListOutput>()
        let communicator = AXCommunicator<AXPTaskListIntent, AXPTaskListOutput> { outputs.append($0) }
        let model = AXPTaskListBlockModel(
            props: AXPTaskListProps(portalId: "p1", projectId: "proj1"),
            state: .loading,
            communicator: communicator,
            dataSource: ds)
        return (model, outputs, ds)
    }

    private func loaded(_ tasks: [AXPTask] = sampleTasks, hasMore: Bool = false) async
        -> (AXPTaskListBlockModel, OutputCapture<AXPTaskListOutput>, AxbenchMockTaskListDataSource) {
        let ds = AxbenchMockTaskListDataSource()
        ds.fetchResult = page(tasks, hasMore: hasMore)
        let sut = makeSUT(ds)
        await dispatchAndAwaitState(sut.0, intent: .initialLoad) { if case .loaded = $0 { return true }; return false }
        return sut
    }

    // AC-01
    @Test func initialLoad_populatesLoaded() async {
        let (model, _, _) = await loaded(sampleTasks, hasMore: true)
        guard case .loaded(let data) = model.state else { Issue.record("expected .loaded"); return }
        #expect(data.tasks.count == 3)
        #expect(data.tasks[0].id == "t1")
        #expect(data.hasMore)
        #expect(data.nextFrom == 3)
    }

    // AC-02
    @Test func initialLoad_emptyPage_setsEmpty() async {
        let ds = AxbenchMockTaskListDataSource(); ds.fetchResult = page([])
        let (model, _, _) = makeSUT(ds)
        await dispatchAndAwaitState(model, intent: .initialLoad) { if case .empty = $0 { return true }; return false }
        guard case .empty = model.state else { Issue.record("expected .empty"); return }
    }

    // AC-03
    @Test func initialLoad_failure_setsError() async {
        let ds = AxbenchMockTaskListDataSource(); ds.fetchResult = failingPage()
        let (model, _, _) = makeSUT(ds)
        await dispatchAndAwaitState(model, intent: .initialLoad) { if case .error = $0 { return true }; return false }
        guard case .error = model.state else { Issue.record("expected .error"); return }
    }

    // AC-04
    @Test func refresh_fetchesFromZero_replacesTasks() async {
        let (model, _, ds) = await loaded(sampleTasks)
        ds.fetchResult = page([AXPTask(id: "new", title: "New", status: AXPTaskStatus(kind: .open))])
        await dispatchAndAwaitState(model, intent: .refresh) {
            if case .loaded(let d) = $0 { return d.tasks.count == 1 }; return false
        }
        guard case .loaded(let data) = model.state else { Issue.record("expected .loaded"); return }
        #expect(data.tasks.first?.id == "new")
        #expect(ds.lastFetchFrom == 0)
    }

    // AC-05 — refresh must never flip the visible list to .loading
    @Test func refresh_neverShowsLoading() async {
        let (model, _, ds) = await loaded(sampleTasks)
        var sawLoading = false
        let cancellable = model.$state.dropFirst().sink { if case .loading = $0 { sawLoading = true } }
        defer { cancellable.cancel() }
        ds.fetchResult = page([openTask])
        await dispatchAndAwaitState(model, intent: .refresh) {
            if case .loaded(let d) = $0 { return d.tasks.count == 1 }; return false
        }
        #expect(!sawLoading)
    }

    // AC-06
    @Test func refresh_failure_keepsExistingData() async {
        let (model, _, ds) = await loaded(sampleTasks)
        ds.fetchResult = failingPage()
        await dispatchAndAwait(model, intent: .refresh)
        guard case .loaded(let data) = model.state else { Issue.record("expected .loaded retained"); return }
        #expect(data.tasks.count == 3)
    }

    // AC-07
    @Test func refresh_failure_noExistingData_setsError() async {
        let ds = AxbenchMockTaskListDataSource(); ds.fetchResult = failingPage()
        let (model, _, _) = makeSUT(ds)
        await dispatchAndAwaitState(model, intent: .refresh) { if case .error = $0 { return true }; return false }
        guard case .error = model.state else { Issue.record("expected .error"); return }
    }

    // AC-08
    @Test func loadMore_appendsNextPage() async {
        let (model, _, ds) = await loaded([openTask, progressTask], hasMore: true)
        ds.fetchResult = page([closedTask], hasMore: false)
        await dispatchAndAwaitState(model, intent: .loadMore) {
            if case .loaded(let d) = $0 { return d.tasks.count == 3 && !d.isLoadingMore }; return false
        }
        guard case .loaded(let data) = model.state else { Issue.record("expected .loaded"); return }
        #expect(data.tasks.count == 3)
        #expect(!data.hasMore)
    }

    // AC-09
    @Test func loadMore_noMore_isNoOp() async {
        let (model, _, ds) = await loaded(sampleTasks, hasMore: false)
        let before = ds.fetchCallCount
        await dispatchAndAwait(model, intent: .loadMore)
        #expect(ds.fetchCallCount == before)
    }

    // AC-10
    @Test func loadMore_failure_restoresPrevious() async {
        let (model, _, ds) = await loaded(sampleTasks, hasMore: true)
        ds.fetchResult = failingPage()
        await dispatchAndAwaitState(model, intent: .loadMore) {
            if case .loaded(let d) = $0 { return !d.isLoadingMore }; return false
        }
        guard case .loaded(let data) = model.state else { Issue.record("expected .loaded"); return }
        #expect(data.tasks.count == 3)
        #expect(data.hasMore)
    }

    // AC-11
    @Test func taskSelected_emitsOutput_stateUnchanged() async {
        let (model, outputs, _) = await loaded(sampleTasks)
        await dispatchAndAwait(model, intent: .taskSelected(openTask))
        #expect(outputs.values.count == 1)
        guard case .taskSelected(let t) = outputs.values.first else { Issue.record("expected .taskSelected"); return }
        #expect(t.id == "t1")
        guard case .loaded(let data) = model.state else { Issue.record("state changed"); return }
        #expect(data.tasks.count == 3)
    }

    // AC-12 — open→closed + output; closed→open
    @Test func checkboxToggled_flipsStatus_emitsChanged() async {
        let (model, outputs, _) = await loaded(sampleTasks)
        await dispatchAndAwaitState(model, intent: .checkboxToggled(openTask)) {
            if case .loaded(let d) = $0 { return d.tasks.first(where: { $0.id == "t1" })?.status.kind == .closed }
            return false
        }
        guard case .loaded(let data) = model.state,
              let t1 = data.tasks.first(where: { $0.id == "t1" }) else { Issue.record("expected updated"); return }
        #expect(t1.status.kind == .closed)
        #expect(outputs.values.contains { if case .taskStatusChanged = $0 { return true }; return false })

        // closed → open
        await dispatchAndAwaitState(model, intent: .checkboxToggled(closedTask)) {
            if case .loaded(let d) = $0 { return d.tasks.first(where: { $0.id == "t3" })?.status.kind == .open }
            return false
        }
        guard case .loaded(let data2) = model.state,
              let t3 = data2.tasks.first(where: { $0.id == "t3" }) else { Issue.record("expected updated"); return }
        #expect(t3.status.kind == .open)
    }

    // AC-13
    @Test func checkboxToggled_failure_keepsData_noOutput() async {
        let ds = AxbenchMockTaskListDataSource()
        ds.fetchResult = page(sampleTasks)
        ds.updateResult = Fail(error: NSError(domain: "Axbench", code: -1)).eraseToAnyPublisher()
        let (model, outputs, _) = makeSUT(ds)
        await dispatchAndAwaitState(model, intent: .initialLoad) { if case .loaded = $0 { return true }; return false }
        await dispatchAndAwait(model, intent: .checkboxToggled(openTask))
        guard case .loaded(let data) = model.state,
              let t1 = data.tasks.first(where: { $0.id == "t1" }) else { Issue.record("expected .loaded"); return }
        #expect(t1.status.kind == .open)
        #expect(outputs.values.isEmpty)
    }

    // AC-14
    @Test func createTaskTapped_emitsRequested() async {
        let (model, outputs, _) = await loaded(sampleTasks)
        await dispatchAndAwait(model, intent: .createTaskTapped)
        #expect(outputs.values.contains { if case .createTaskRequested = $0 { return true }; return false })
    }
}
