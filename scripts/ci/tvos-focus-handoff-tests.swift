/// Host-only checks for the value policies used by tvOS focus handoffs.
/// Compile with TVFocusWatchdog.swift, TVMainTabView.swift and TVCatalogGrid.swift.
@main
enum TVFocusHandoffHostTests {
    static func main() {
        var gate = TVBarFocusTransitionGate()
        precondition(gate.consume(sequence: 1, sourceInBar: false, destinationInBar: false,
                                  isDown: true, isDirectional: true) == .unrelated)
        precondition(gate.consume(sequence: 2, sourceInBar: true, destinationInBar: false,
                                  isDown: false, isDirectional: false) == .otherDeparture)
        precondition(gate.consume(sequence: 2, sourceInBar: true, destinationInBar: false,
                                  isDown: true, isDirectional: true) == .unrelated)
        precondition(gate.consume(sequence: 3, sourceInBar: true, destinationInBar: false,
                                  isDown: true, isDirectional: true) == .downFromBar)
        precondition(gate.consume(sequence: 4, sourceInBar: false, destinationInBar: true,
                                  isDown: false, isDirectional: true) == .userArrival)

        precondition(tvQueuedContentHandoffIsCurrent(scheduledGeneration: 1, currentGeneration: 1,
                                                     scheduledDestination: "movies", currentDestination: "movies",
                                                     isShowingRoot: true, menuOwnsFocus: false))
        precondition(!tvQueuedContentHandoffIsCurrent(scheduledGeneration: 1, currentGeneration: 2,
                                                      scheduledDestination: "movies", currentDestination: "movies",
                                                      isShowingRoot: true, menuOwnsFocus: false))
        precondition(!tvQueuedContentHandoffIsCurrent(scheduledGeneration: 1, currentGeneration: 1,
                                                      scheduledDestination: "movies", currentDestination: "series",
                                                      isShowingRoot: true, menuOwnsFocus: false))
        precondition(!tvQueuedContentHandoffIsCurrent(scheduledGeneration: 1, currentGeneration: 1,
                                                      scheduledDestination: "movies", currentDestination: "movies",
                                                      isShowingRoot: true, menuOwnsFocus: true))

        var detail = TVBrowseDetailReturnState()
        detail.open(itemId: "deep", detailDepth: 2)
        precondition(detail.targetAfterPop(to: 2, availableIDs: ["first", "deep"]) == nil)
        precondition(detail.targetAfterPop(to: 1, availableIDs: ["first", "deep"]) == "deep")
        precondition(detail.targetAfterPop(to: 1, availableIDs: ["first", "deep"]) == nil)
        detail.open(itemId: "removed", detailDepth: 2)
        precondition(detail.targetAfterPop(to: 1, availableIDs: ["first"]) == "first")
        detail.open(itemId: "old", detailDepth: 2)
        detail.cancel()
        precondition(detail.targetAfterPop(to: 1, availableIDs: ["new"]) == nil)
        print("PASS: scoped single-use transitions, cancelled handoffs, Browse detail return and fallback")
    }
}
