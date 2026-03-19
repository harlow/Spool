import SwiftUI

struct RecordingIndicatorView: View {
    let state: RecordingState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 34, height: 34)

                Image(systemName: "recordingtape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.top, 10)

            Spacer(minLength: 10)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    AnimatedBar(index: index, state: state)
                }
            }
            .padding(.bottom, 12)
        }
        .frame(width: 54, height: 128)
        .background(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.19, green: 0.19, blue: 0.20),
                            Color(red: 0.13, green: 0.13, blue: 0.14)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }
}

private struct AnimatedBar: View {
    let index: Int
    let state: RecordingState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isAnimating)) { context in
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(barColor)
                .frame(width: 5, height: barHeight(at: context.date))
                .opacity(barOpacity(at: context.date))
        }
    }

    private var isAnimating: Bool {
        state == .recording
    }

    private var barColor: Color {
        switch state {
        case .recording:
            return Color(red: 0.43, green: 0.87, blue: 0.25)
        case .stopping, .finalizingTranscript, .summarizing:
            return Color.white.opacity(0.35)
        default:
            return Color.white.opacity(0.2)
        }
    }

    private func barHeight(at date: Date) -> CGFloat {
        switch state {
        case .recording:
            let t = date.timeIntervalSinceReferenceDate
            let wave = (sin((t * 5.2) + Double(index) * 0.9) + 1) / 2
            let secondary = (sin((t * 2.8) + Double(index) * 1.7) + 1) / 2
            return 8 + CGFloat((wave * 14) + (secondary * 4))
        case .stopping, .finalizingTranscript, .summarizing:
            return 10
        default:
            return 7
        }
    }

    private func barOpacity(at date: Date) -> Double {
        switch state {
        case .recording:
            let t = date.timeIntervalSinceReferenceDate
            let pulse = (sin((t * 4.4) + Double(index) * 1.1) + 1) / 2
            return 0.65 + (pulse * 0.35)
        case .stopping, .finalizingTranscript, .summarizing:
            return 0.55
        default:
            return 0.3
        }
    }
}
