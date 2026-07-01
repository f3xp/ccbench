// HIDDEN acceptance suite for TKT-001. Overlaid into the test target by the
// scorer AFTER the agent finishes — the agent never sees this file.
//
// Verifies AC-001..AC-004 + E-001 against AXDViewsListBlockModel's
// .searchTextChanged behaviour.

import Foundation
import Testing
@preconcurrency import Combine
import AXKitCore
@testable import axkit_playground

private final class AcceptanceMockDataSource: AXDViewsListBlockDataSource, @unchecked Sendable {
    var result: AnyPublisher<[AXDViewSection], Swift.Error> =
        Just([]).setFailureType(to: Swift.Error.self).eraseToAnyPublisher()
    func getViewsList(props: AXDViewsListProps) -> AnyPublisher<[AXDViewSection], Swift.Error> {
        result
    }
}

@Suite("TKT-001 Views List search — acceptance")
@MainActor
struct ViewsListSearchAcceptanceTests {

    private let sections: [AXDViewSection] = [
        AXDViewSection(name: "Starred", views: [
            AXDView(id: "1", name: "My Open Tickets", count: "12"),
            AXDView(id: "2", name: "Unassigned Tickets", count: "5"),
        ]),
        AXDViewSection(name: "All", views: [
            AXDView(id: "3", name: "Closed Tickets"),
            AXDView(id: "4", name: "Spam"),
        ]),
    ]

    private func makeSUT() -> (AXDViewsListBlockModel, AcceptanceMockDataSource) {
        let ds = AcceptanceMockDataSource()
        let model = AXDViewsListBlockModel(
            props: AXDViewsListProps(orgId: "o", departmentId: "d",
                                     selectedViewId: "1", maxStarredCount: 15),
            state: .loading,
            communicator: AXCommunicator<AXDViewsListIntent, AXDViewsListOutput>(),
            dataSource: ds
        )
        return (model, ds)
    }

    private func load(_ model: AXDViewsListBlockModel, _ ds: AcceptanceMockDataSource) async {
        ds.result = Just(sections).setFailureType(to: Swift.Error.self).eraseToAnyPublisher()
        _ = await firstState(model, intent: .initialized)
    }

    // Helper: drive an intent and return the resulting state.
    private func firstState(_ model: AXDViewsListBlockModel,
                            intent: AXDViewsListIntent) async -> AXDViewsListState {
        await withCheckedContinuation { cont in
            var bag = Set<AnyCancellable>()
            model.handleIntent(intent)
                .first()
                .sink { state in cont.resume(returning: state); _ = bag }
                .store(in: &bag)
        }
    }

    @Test("AC-001: non-empty query filters to matching views only")
    func filtersMatching() async {
        let (m, ds) = makeSUT(); await load(m, ds)
        let state = await firstState(m, intent: .searchTextChanged("ticket"))
        guard case let .loaded(data) = state else { Issue.record("expected loaded"); return }
        let names = data.sections.flatMap(\.views).map(\.name)
        #expect(names.allSatisfy { $0.lowercased().contains("ticket") })
        #expect(names.contains("My Open Tickets"))
        #expect(!names.contains("Spam"))
    }

    @Test("AC-002: empty query restores the full list")
    func emptyRestores() async {
        let (m, ds) = makeSUT(); await load(m, ds)
        _ = await firstState(m, intent: .searchTextChanged("spam"))
        let state = await firstState(m, intent: .searchTextChanged(""))
        guard case let .loaded(data) = state else { Issue.record("expected loaded"); return }
        #expect(data.sections.flatMap(\.views).count == 4)
    }

    @Test("AC-003: no-match query yields the No Results empty state")
    func noMatchEmpty() async {
        let (m, ds) = makeSUT(); await load(m, ds)
        let state = await firstState(m, intent: .searchTextChanged("zzzznomatch"))
        guard case let .empty(empty) = state else { Issue.record("expected empty"); return }
        #expect(empty.title == "No Results")
    }

    @Test("AC-004: matching is case-insensitive")
    func caseInsensitive() async {
        let (m, ds) = makeSUT(); await load(m, ds)
        let state = await firstState(m, intent: .searchTextChanged("SPAM"))
        guard case let .loaded(data) = state else { Issue.record("expected loaded"); return }
        #expect(data.sections.flatMap(\.views).map(\.name).contains("Spam"))
    }
}
