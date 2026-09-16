import Foundation

// Internal finalization step for a staging MP4 produced by this engine only.
// No public operation to rewrite arbitrary source media.
enum ControlledMovieDate {
    private static func number(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func read(_ file: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw CutError.invalid("書き出したMP4が途中で切れています。") }
        return data
    }
    private static func children(_ box: Data) throws -> [Data] {
        var position = 8, result: [Data] = []
        while position < box.count {
            guard box.count - position >= 8 else { throw CutError.invalid("出力moovの構造が不正です。") }
            let size = Int(number(box[position..<position + 4]))
            guard size >= 8, size <= box.count - position else { throw CutError.invalid("出力moovの子box長が不正です。") }
            result.append(box.subdata(in: position..<position + size)); position += size
        }
        return result
    }
    private static func type(_ box: Data) -> String { String(decoding: box[4..<8], as: UTF8.self) }
    private static func atom(_ type: String, _ payload: Data) throws -> Data {
        guard payload.count < Int(UInt32.max) - 8 else { throw CutError.invalid("日時メタデータが大きすぎます。") }
        let size = UInt32(payload.count + 8)
        var data = Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
        data.append(contentsOf: type.utf8); data.append(payload); return data
    }
    static func finalize(stagingURL: URL) throws {
        let file = try FileHandle(forUpdating: stagingURL); defer { try? file.close() }
        let size = try file.seekToEnd()
        var position: UInt64 = 0, movieOffset: UInt64?, movie: Data?
        while position < size {
            guard size - position >= 8 else { throw CutError.invalid("出力boxの境界が不正です。") }
            let header = try read(file, offset: position, count: 8)
            var length = number(header.prefix(4))
            let large = length == 1
            if large { guard size - position >= 16 else { throw CutError.invalid("出力boxが不完全です。") }; length = number(try read(file, offset: position + 8, count: 8)) }
            guard length >= (large ? 16 : 8), length <= size - position, ["ftyp", "free", "mdat", "moov"].contains(type(header)) else { throw CutError.invalid("制御下の出力形式と異なるMP4です。") }
            if type(header) == "moov" {
                guard movie == nil, !large, position + length == size, length <= 64 * 1024 * 1024 else { throw CutError.invalid("末尾の32-bit moovだけを日時確定の対象にできます。") }
                movieOffset = position; movie = try read(file, offset: position, count: Int(length))
            }
            position += length
        }
        guard let movie, let movieOffset else { throw CutError.invalid("出力moovがありません。") }
        var retained = Data(), metadata: [Data] = []
        for child in try children(movie) {
            guard type(child) != "meta" else { throw CutError.invalid("出力にmovie-level metaが既に存在します。") }
            if type(child) != "udta" { retained.append(child); continue }
            var userData = Data()
            for item in try children(child) {
                if type(item) == "meta" {
                    guard item.count >= 12, number(item[8..<12]) == 0 else { throw CutError.invalid("出力metaの版が不正です。") }
                    metadata.append(try atom("meta", item.subdata(in: 12..<item.count)))
                } else { userData.append(item) }
            }
            if !userData.isEmpty { retained.append(try atom("udta", userData)) }
        }
        guard metadata.count == 1 else { throw CutError.invalid("出力日時メタデータを一意に確定できません。") }
        retained.append(metadata[0])
        let final = try atom("moov", retained)
        try file.seek(toOffset: movieOffset); try file.write(contentsOf: final)
        try file.truncate(atOffset: movieOffset + UInt64(final.count)); try file.synchronize()
    }
}
