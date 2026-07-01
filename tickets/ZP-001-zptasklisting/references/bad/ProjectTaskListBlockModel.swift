import AXKitCore
import Combine
import os.log

// BAD reference (judge self-test). Plausible-looking, but wrong in several
// ways the rubric should catch:
//  - refresh flips the visible list back to `.loading` (AC-05 fail) and shows
//    `.error` on failure even when data was already loaded (AC-06 fail).
//  - loadMore does not guard `hasMore` / `isLoadingMore` and never restores the
//    previous data on error (AC-09 / AC-10 fail).
//  - checkboxToggled decides the new status from the display *name* string
//    instead of the status `kind`, and forgets to emit `.taskStatusChanged`
//    (AC-12 / AC-13 fail).
//  - introduces a singleton formatter/manager for no reason (MVI anti-pattern).

/// A needless global helper — exactly the kind of over-engineering the MVI
/// rubric penalizes.
final class TaskStatusFormatter {
    static let shared = TaskStatusFormatter()
    func isClosed(_ name: String) -> Bool { name.lowercased() == "closed" }
}

final class AXPTaskListBlockModel: AXBlockModel<
    AXPTaskListProps,
    AXPTaskListState,
    AXPTaskListIntent,
    AXPTaskListOutput
> {
    private static let pageSize = 50
    private let dataSource: AXPTaskListDataSource

    init(
        props: AXPTaskListProps,
        state: AXPTaskListState,
        communicator: AXCommunicator<AXPTaskListIntent, AXPTaskListOutput>,
        dataSource: AXPTaskListDataSource
    ) {
        self.dataSource = dataSource
        super.init(props: props, state: state, communicator: communicator)
    }

    override func handleIntent(_ intent: AXPTaskListIntent)
        -> AnyPublisher<AXPTaskListState, Never> {

        switch intent {
        case .initialLoad, .refresh:
            // Wrong: refresh shows a full-screen spinner and clears the list,
            // and any failure becomes `.error` even if data was loaded.
            return Just(AXPTaskListState.loading)
                .append(
                    dataSource.fetchTasks(props: props, from: 0, limit: Self.pageSize)
                        .map { page in
                            page.tasks.isEmpty
                                ? .empty
                                : .loaded(AXPTaskListData(
                                    tasks: page.tasks,
                                    hasMore: page.hasMore,
                                    nextFrom: page.tasks.count))
                        }
                        .replaceError(with: .error("Failed to load tasks."))
                )
                .eraseToAnyPublisher()

        case .loadMore:
            // Wrong: no guard on hasMore / isLoadingMore, no restore on error.
            guard case .loaded(let data) = state else {
                return Just(state).eraseToAnyPublisher()
            }
            return dataSource.fetchTasks(props: props, from: data.nextFrom, limit: Self.pageSize)
                .map { page in
                    .loaded(AXPTaskListData(
                        tasks: data.tasks + page.tasks,
                        hasMore: page.hasMore,
                        nextFrom: data.nextFrom + page.tasks.count))
                }
                .replaceError(with: .empty)   // wrong fallback
                .eraseToAnyPublisher()

        case .taskSelected(let task):
            handleOutput(.taskSelected(task))
            return Just(state).eraseToAnyPublisher()

        case .checkboxToggled(let task):
            guard case .loaded(let data) = state else {
                return Just(state).eraseToAnyPublisher()
            }
            // Wrong: decides state from the display name, mutates locally without
            // calling the data source, and never emits `.taskStatusChanged`.
            let closed = TaskStatusFormatter.shared.isClosed(task.status.name)
            let newStatus = AXPTaskStatus(kind: closed ? .open : .closed)
            let updated = AXPTask(id: task.id, title: task.title, status: newStatus,
                                  tags: task.tags, completionPercentage: task.completionPercentage,
                                  owners: task.owners)
            let updatedTasks = data.tasks.map { $0.id == updated.id ? updated : $0 }
            return Just(.loaded(AXPTaskListData(
                tasks: updatedTasks, hasMore: data.hasMore, nextFrom: data.nextFrom)))
                .eraseToAnyPublisher()

        case .createTaskTapped:
            handleOutput(.createTaskRequested)
            return Just(state).eraseToAnyPublisher()
        }
    }
}
