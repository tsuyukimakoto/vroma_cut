import Foundation
import VromaCutCore

struct TimelineLayout {
    let rows: [UUID: Int]
    let rowCount: Int
    init(clips: [Clip]) {
        var ends: [MediaTime] = [], placed: [UUID: Int] = [:]
        for clip in clips.sorted(by: { a, b in
            if a.requested.start != b.requested.start { return a.requested.start < b.requested.start }
            if a.requested.end != b.requested.end { return a.requested.end < b.requested.end }
            return a.id.uuidString < b.id.uuidString
        }) {
            let row = ends.firstIndex { $0 <= clip.requested.start } ?? ends.count
            if row == ends.count { ends.append(clip.requested.end) } else { ends[row] = clip.requested.end }
            placed[clip.id] = row
        }
        rows = placed; rowCount = ends.count
    }
}

struct TimelineSelection {
    var ids: Set<UUID> = []
    var anchor: UUID?
    mutating func click(_ id: UUID, ordered: [UUID], toggle: Bool, extend: Bool) {
        if extend, let anchor, let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: id) {
            let range = Set(ordered[min(a, b)...max(a, b)])
            ids = toggle ? ids.union(range) : range
        } else if toggle {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        } else { ids = [id]; anchor = id }
    }
}
