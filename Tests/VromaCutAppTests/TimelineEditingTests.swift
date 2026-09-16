import Foundation
import Testing
import VromaCutCore
@testable import VromaCutApp

@Test func timelineStacksOnlyOverlappingClips() throws {
    let recording = UUID()
    func clip(_ start: Double, _ end: Double) throws -> Clip {
        Clip(recordingID: recording, requested: try MediaRange(start: MediaTime(seconds: start), end: MediaTime(seconds: end)))
    }
    let a = try clip(0, 10), b = try clip(10, 20), c = try clip(5, 15), d = try clip(20, 30)
    let separate = TimelineLayout(clips: [d, b, a])
    #expect(separate.rowCount == 1)
    let overlap = TimelineLayout(clips: [d, c, b, a])
    #expect(overlap.rowCount == 2)
    #expect(overlap.rows[a.id] == overlap.rows[b.id])
    #expect(overlap.rows[b.id] == overlap.rows[d.id])
    #expect(overlap.rows[c.id] != overlap.rows[a.id])
}

@Test func timelineSelectionSupportsCommandToggleAndShiftRange() {
    let ids = (0..<5).map { _ in UUID() }
    var selection = TimelineSelection()
    selection.click(ids[1], ordered: ids, toggle: false, extend: false)
    #expect(selection.ids == [ids[1]])
    selection.click(ids[3], ordered: ids, toggle: true, extend: false)
    #expect(selection.ids == [ids[1], ids[3]])
    selection.click(ids[1], ordered: ids, toggle: true, extend: false)
    #expect(selection.ids == [ids[3]])
    selection.click(ids[4], ordered: ids, toggle: false, extend: true)
    #expect(selection.ids == Set(ids[1...4]))
    selection.click(ids[0], ordered: ids, toggle: false, extend: false)
    #expect(selection.ids == [ids[0]])
}
