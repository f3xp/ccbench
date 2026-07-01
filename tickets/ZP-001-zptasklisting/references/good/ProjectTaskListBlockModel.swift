import AXKitCore
import Combine
import os.log

private let logger = Logger(subsystem: "com.zoho.desk.ui", category: "TaskListBlockModel")

/// The view model for the project task list feature.
///
/// Handles all ``AXPTaskListIntent`` cases and manages the
/// ``AXPTaskListState`` lifecycle including initial load,
/// pull-to-refresh, infinite scroll pagination, task selection,
/// and checkbox-driven status toggling.
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

        logger.info("handleIntent: \(String(describing: intent))")

        switch intent {
        case .initialLoad:
            logger.debug("Fetching tasks — initialLoad, pageSize=\(Self.pageSize)")
            return dataSource.fetchTasks(props: props, from: 0, limit: Self.pageSize)
                .handleEvents(
                    receiveOutput: { page in
                        logger.info("fetchTasks returned \(page.tasks.count) tasks, hasMore=\(page.hasMore)")
                    },
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            logger.error("fetchTasks failed: \(error.localizedDescription)")
                        }
                    }
                )
                .map { page in
                    let newState: AXPTaskListState = page.tasks.isEmpty
                        ? .empty
                        : .loaded(AXPTaskListData(
                            tasks: page.tasks,
                            hasMore: page.hasMore,
                            nextFrom: page.tasks.count
                        ))
                    logger.info("State transition → \(String(describing: newState))")
                    return newState
                }
                .replaceError(with: .error("Failed to load tasks. Please try again."))
                .eraseToAnyPublisher()

        case .refresh:
            logger.debug("Fetching tasks — refresh (from: 0), pageSize=\(Self.pageSize)")

            // Capture the current loaded data so we can preserve it during the fetch.
            let existingData: AXPTaskListData? = {
                if case .loaded(let data) = state { return data }
                return nil
            }()

            // On error, fall back to the existing loaded state if available,
            // otherwise transition to the generic error state.
            let errorFallback: AXPTaskListState = existingData.map { .loaded($0) }
                ?? .error("Failed to load tasks. Please try again.")

            return dataSource.fetchTasks(props: props, from: 0, limit: Self.pageSize)
                .handleEvents(
                    receiveOutput: { page in
                        logger.info("refresh: fetchTasks returned \(page.tasks.count) tasks, hasMore=\(page.hasMore)")
                    },
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            logger.error("refresh: fetchTasks failed: \(error.localizedDescription)")
                        }
                    }
                )
                .map { page in
                    let newState: AXPTaskListState = page.tasks.isEmpty
                        ? .empty
                        : .loaded(AXPTaskListData(
                            tasks: page.tasks,
                            hasMore: page.hasMore,
                            nextFrom: page.tasks.count
                        ))
                    logger.info("refresh: State transition → \(String(describing: newState))")
                    return newState
                }
                .replaceError(with: errorFallback)
                .eraseToAnyPublisher()

        case .loadMore:
            guard case .loaded(let data) = state,
                  data.hasMore,
                  !data.isLoadingMore else {
                logger.debug("loadMore skipped — current state=\(String(describing: self.state))")
                return Just(state).eraseToAnyPublisher()
            }

            logger.debug("loadMore starting from offset=\(data.nextFrom)")

            let loadingState = AXPTaskListData(
                tasks: data.tasks,
                hasMore: data.hasMore,
                isLoadingMore: true,
                nextFrom: data.nextFrom
            )

            return Just(AXPTaskListState.loaded(loadingState))
                .append(
                    dataSource.fetchTasks(props: props, from: data.nextFrom, limit: Self.pageSize)
                        .map { page in
                            .loaded(AXPTaskListData(
                                tasks: data.tasks + page.tasks,
                                hasMore: page.hasMore,
                                nextFrom: data.nextFrom + page.tasks.count
                            ))
                        }
                        .replaceError(with: .loaded(data))
                )
                .eraseToAnyPublisher()

        case .taskSelected(let task):
            logger.debug("taskSelected: id=\(task.id), title=\(task.title)")
            handleOutput(.taskSelected(task))
            return Just(state).eraseToAnyPublisher()

        case .checkboxToggled(let task):
            guard case .loaded(let data) = state else {
                logger.warning("checkboxToggled ignored — state is not .loaded")
                return Just(state).eraseToAnyPublisher()
            }
            let newStatus: AXPTaskStatus = task.status.kind == .closed
                ? AXPTaskStatus(kind: .open, id: task.status.id, name: "Open", colorHex: task.status.colorHex)
                : AXPTaskStatus(kind: .closed, id: task.status.id, name: "Closed", colorHex: task.status.colorHex)
            logger.debug("checkboxToggled: id=\(task.id), newStatus=\(String(describing: newStatus))")
            return dataSource.updateTaskStatus(id: task.id, status: newStatus)
                .map { [weak self] updatedTask -> AXPTaskListState in
                    guard let self else { return .loaded(data) }
                    self.handleOutput(.taskStatusChanged(updatedTask))
                    let updatedTasks = data.tasks.map { $0.id == updatedTask.id ? updatedTask : $0 }
                    return .loaded(AXPTaskListData(
                        tasks: updatedTasks,
                        hasMore: data.hasMore,
                        nextFrom: data.nextFrom
                    ))
                }
                .replaceError(with: .loaded(data))
                .eraseToAnyPublisher()

        case .createTaskTapped:
            logger.debug("createTaskTapped")
            handleOutput(.createTaskRequested)
            return Just(state).eraseToAnyPublisher()
        }
    }
}
