import SwiftUI

struct ProgressMeter: View {
    let fraction: Double?
    var body: some View {
        HStack(spacing: 8) {
            if let fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(Color.accentColor).frame(width: geometry.size.width * min(1, max(0, fraction)))
                    }
                }.frame(width: 120, height: 6)
                    .accessibilityLabel("進捗")
                    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.caption.monospacedDigit()).frame(width: 40)
            } else { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
        }.frame(height: 24).fixedSize()
    }
}

struct OperationBanner: View {
    @Bindable var operation: OperationState
    var body: some View {
        HStack(spacing: 16) {
            Text(operation.message).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            ProgressMeter(fraction: operation.fraction)
            Button(operation.isCancelling ? "キャンセル中…" : "キャンセル") { operation.cancel() }
                .disabled(operation.isCancelling)
                .accessibilityIdentifier("cancel-media-operation")
        }.padding(.horizontal, 16).padding(.vertical, 10).background(Color(nsColor: .controlBackgroundColor))
    }
}
