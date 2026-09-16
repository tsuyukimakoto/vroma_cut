import Foundation
import CryptoKit

public struct Mark: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let comment: String
}

public enum MarkCSV {
    public static func parse(_ input: String) throws -> [Mark] {
        var text = input
        if text.first == "\u{feff}" { text.removeFirst() }
        // Iterate Unicode scalars so CRLF remains two delimiters, even as a single Swift Character.
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, previousCR = false
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if quoted {
                if scalar == "\"" { quoted = false; closed = true }
                else { field.unicodeScalars.append(scalar) }
                continue
            }
            if closed && scalar == "\"" { field.append("\""); quoted = true; closed = false; continue }
            if scalar == "\n" && previousCR { previousCR = false; continue }
            previousCR = false
            if scalar == "," { row.append(field); field = ""; closed = false }
            else if scalar == "\r" || scalar == "\n" {
                row.append(field); rows.append(row); row = []; field = ""; closed = false; previousCR = scalar == "\r"
            } else if scalar == "\"", field.isEmpty, !closed { quoted = true }
            else {
                guard !closed, scalar != "\"" else { throw CutError.invalid("CSVの引用符の後に不正な文字があります。") }
                field.unicodeScalars.append(scalar)
            }
        }
        guard !quoted else { throw CutError.invalid("CSVの引用符が閉じていません。") }
        if !row.isEmpty || !field.isEmpty || closed { row.append(field); rows.append(row) }
        var seen: Set<String> = []
        return try rows.filter { $0 != [""] }.enumerated().compactMap { index, columns in
            guard columns.count >= 2 else { throw CutError.invalid("CSVの\(index + 1)行目に日時列がありません。") }
            let date = try UTCDate.parse(columns[0])
            let comment = columns.dropFirst(2).joined(separator: ",")
            let identity = String(date.timeIntervalSince1970) + "\u{0}" + comment
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(id).inserted else { return nil }
            return Mark(id: id, date: date, comment: comment)
        }
    }
}
