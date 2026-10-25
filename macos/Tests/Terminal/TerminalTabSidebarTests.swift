import Testing
@testable import Ghostty

struct TerminalTabSidebarTests {
    private let pitch: CGFloat = 30

    // MARK: - dropSlot

    @Test func dropSlotWithoutMovementLeavesTabInPlace() {
        let slot = TerminalTabSidebar.dropSlot(from: 2, offset: 0, pitch: pitch, count: 5)
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: 2, toSlot: slot, count: 5) == nil)
    }

    @Test func dropSlotPassesNeighborOnlyOnceCenterCrossesIt() {
        // Just short of the next tab's center: still in place.
        let short = TerminalTabSidebar.dropSlot(from: 0, offset: pitch - 1, pitch: pitch, count: 3)
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: 0, toSlot: short, count: 3) == nil)

        // On the next tab's center: after it.
        let past = TerminalTabSidebar.dropSlot(from: 0, offset: pitch, pitch: pitch, count: 3)
        #expect(past == 2)
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: 0, toSlot: past, count: 3) == 1)
    }

    @Test func dropSlotMovingUpPassesPreviousTab() {
        let short = TerminalTabSidebar.dropSlot(from: 2, offset: -(pitch - 1), pitch: pitch, count: 3)
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: 2, toSlot: short, count: 3) == nil)

        let past = TerminalTabSidebar.dropSlot(from: 2, offset: -pitch - 1, pitch: pitch, count: 3)
        #expect(past == 1)
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: 2, toSlot: past, count: 3) == 1)
    }

    @Test func dropSlotIsClampedToTheList() {
        #expect(TerminalTabSidebar.dropSlot(from: 1, offset: -1000, pitch: pitch, count: 4) == 0)
        #expect(TerminalTabSidebar.dropSlot(from: 1, offset: 1000, pitch: pitch, count: 4) == 4)
    }

    // MARK: - destinationIndex

    @Test(arguments: [
        // (source, slot, expected) in a list of 4 tabs.
        (0, 0, nil),
        (0, 1, nil),
        (0, 2, 1),
        (0, 4, 3),
        (3, 0, 0),
        (3, 2, 2),
        (3, 3, nil),
        (3, 4, nil),
        (1, 3, 2),
    ] as [(Int, Int, Int?)])
    func destinationIndex(source: Int, slot: Int, expected: Int?) {
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: source, toSlot: slot, count: 4) == expected)
    }

    // MARK: - displacement

    /// The rows' displacements while dragging `source` over `slot` in a list of 5 tabs.
    private func displacements(source: Int, slot: Int) -> [Int] {
        (0..<5).map {
            TerminalTabSidebar.displacement(ofRowAt: $0, draggingFrom: source, toSlot: slot, count: 5)
        }
    }

    @Test func displacementMovingDownShiftsRowsBetweenUp() {
        // Tab 1 dragged to after tab 3: tabs 2 and 3 move up into its place.
        #expect(displacements(source: 1, slot: 4) == [0, 0, -1, -1, 0])
    }

    @Test func displacementMovingUpShiftsRowsBetweenDown() {
        // Tab 3 dragged to before tab 0: tabs 0 to 2 move down.
        #expect(displacements(source: 3, slot: 0) == [1, 1, 1, 0, 0])
    }

    @Test func displacementIsZeroWhenDropLeavesTabInPlace() {
        #expect(displacements(source: 2, slot: 2) == [0, 0, 0, 0, 0])
        #expect(displacements(source: 2, slot: 3) == [0, 0, 0, 0, 0])
    }

    @Test func displacementShowsTheOrderTheDropMakes() {
        // Applying the displacements must give the same order as the real move.
        for source in 0..<5 {
            for slot in 0...5 {
                var shown = Array(repeating: -1, count: 5)
                let moved = displacements(source: source, slot: slot)
                let destination = TerminalTabSidebar.destinationIndex(movingFrom: source, toSlot: slot, count: 5) ?? source
                for row in 0..<5 {
                    shown[row == source ? destination : row + moved[row]] = row
                }

                var expected = Array(0..<5)
                expected.remove(at: source)
                expected.insert(source, at: destination)
                #expect(shown == expected, "source \(source) slot \(slot)")
            }
        }
    }

    @Test func destinationIndexRejectsOutOfRangeInput() {
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: 4, toSlot: 0, count: 4) == nil)
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: 0, toSlot: 5, count: 4) == nil)
        #expect(TerminalTabSidebar.destinationIndex(movingFrom: 0, toSlot: 1, count: 1) == nil)
    }
}
