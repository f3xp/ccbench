// BAD reference — plausible but wrong AND over-engineered. Introduces an
// unnecessary global singleton (MVI violation: business logic outside the block
// model), is case-SENSITIVE (fails E-002), never restores the full list on an
// empty query (fails S-003), and shows the wrong title on no-match (fails S-004).

final class ViewSearchManager {                  // MVI violation: needless global state
    static let shared = ViewSearchManager()
    var lastQuery: String = ""
    func filter(_ sections: [AXDViewSection], query: String) -> [AXDViewSection] {
        lastQuery = query
        return sections.map { section in
            AXDViewSection(
                name: section.name,
                views: section.views.filter { $0.name.contains(query) }  // case-SENSITIVE (E-002 fail)
            )
        }
        // keeps empty sections; no empty-query restore (S-003 fail)
    }
}

case .searchTextChanged(let query):
    let filtered = ViewSearchManager.shared.filter(allSections, query: query)
    let allViews = filtered.flatMap(\.views)
    if allViews.isEmpty {
        return Just(.empty(AXEmptyData(
            title: "No Views",                    // wrong title — spec wants "No Results" (S-004 fail)
            subTitle: "Nothing here.",
            icon: "list.bullet"
        ))).eraseToAnyPublisher()
    }
    return Just(.loaded(AXDViewsListData(
        sections: filtered,
        selectedViewId: props.selectedViewId
    ))).eraseToAnyPublisher()
