// GOOD reference — correct, complete, idiomatic MVI. Filtering lives entirely
// inside the block model; no new global state; all four acceptance criteria met.

case .searchTextChanged(let query):
    guard !query.isEmpty else {
        // S-003: empty query restores the full last-loaded list.
        if allSections.flatMap(\.views).isEmpty {
            return Just(state).eraseToAnyPublisher()   // E-001: nothing loaded yet
        }
        return Just(.loaded(AXDViewsListData(
            sections: allSections,
            selectedViewId: props.selectedViewId
        ))).eraseToAnyPublisher()
    }

    let lowered = query.lowercased()                    // E-002: case-insensitive
    let filtered = allSections.compactMap { section -> AXDViewSection? in
        let matching = section.views.filter { $0.name.lowercased().contains(lowered) }
        return matching.isEmpty ? nil : AXDViewSection(name: section.name, views: matching)
    }

    if filtered.isEmpty {
        // S-004: no matches → "No Results" empty state referencing the query.
        return Just(.empty(AXEmptyData(
            title: "No Results",
            subTitle: "No views match \"\(query)\".",
            icon: "magnifyingglass"
        ))).eraseToAnyPublisher()
    }

    return Just(.loaded(AXDViewsListData(
        sections: filtered,
        selectedViewId: props.selectedViewId
    ))).eraseToAnyPublisher()
