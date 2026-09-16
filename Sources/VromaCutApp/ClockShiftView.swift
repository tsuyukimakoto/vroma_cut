import SwiftUI
import VromaCutCore

struct ClockShiftView: View {
    let recording: Recording
    let timeZone: String
    let apply: (ClockShift) -> Void
    @Environment(\.dismiss) private var dismiss
    @State var shift: ClockShift
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("動画とGPXの時刻を合わせる").font(.title2.bold())
            Text("この動画のカメラ日時を基準に計算し、全動画と今後追加する動画に同じ時刻差を適用します。")
            Picker("カメラ日時を", selection: $shift.direction) {
                Text("先へ進める（加算）").tag(ClockShift.Direction.forward)
                Text("前へ戻す（減算）").tag(ClockShift.Direction.backward)
            }.pickerStyle(.segmented)
            HStack {
                number("年", $shift.years); number("ヶ月", $shift.months); number("日", $shift.days)
                number("時間", $shift.hours); number("分", $shift.minutes)
                VStack { TextField("0", value: $shift.seconds, format: .number).frame(width: 80); Text("秒") }
            }
            if let date = recording.cameraStart {
                Text("カメラ日時: \(formatted(date))")
                if let adjusted = try? shift.adjustedDate(from: date, timeZone: timeZone) {
                    Text("補正後:　　 \(formatted(adjusted))").bold()
                } else { Text("補正量を確認してください。負の値は使えません。").foregroundStyle(.red) }
            }
            Text("年月はカレンダーに沿って計算します。手動で追加したマークと編集済みの範囲は動画内の位置を保ちます。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("キャンセル") { dismiss() }; Button("適用") { apply(shift); dismiss() }.buttonStyle(.borderedProminent).disabled(recording.cameraStart.flatMap { try? shift.adjustedDate(from: $0, timeZone: timeZone) } == nil) }
        }.padding(24).frame(width: 620)
    }
    private func number(_ label: String, _ binding: Binding<Int>) -> some View {
        VStack { TextField("0", value: binding, format: .number).frame(width: 65); Text(label) }
    }
    private func formatted(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: timeZone); f.dateFormat = "yyyy年MM月dd日 HH:mm:ss.SSS"; return f.string(from: date)
    }
}
