import SwiftUI

// The single watch screen: an Ask/Tell toggle, one big "talk" button (single tap
// to start — no press-and-hold), a Listening / Thinking / Reply status line, and
// the last reply's text. Dick-Tracy simple.

struct WatchContentView: View {
    @Bindable var model: WatchTalkModel

    var body: some View {
        VStack(spacing: 8) {
            Button {
                model.mode = (model.mode == .ask) ? .tell : .ask
            } label: {
                Text(model.mode == .ask ? "Ask" : "Tell")
                    .font(.caption).bold()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(model.mode == .ask ? .blue : .green)
            .disabled(isBusy)

            Button(action: model.tapTalk) {
                Image(systemName: buttonIcon)
                    .font(.system(size: 34, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonTint)

            statusView
        }
        .padding(.horizontal, 4)
    }

    private var isBusy: Bool {
        switch model.state {
        case .listening, .thinking: return true
        default: return false
        }
    }

    private var buttonIcon: String {
        switch model.state {
        case .listening: return "stop.fill"
        case .thinking: return "hourglass"
        default: return "mic.fill"
        }
    }

    private var buttonTint: Color {
        switch model.state {
        case .listening: return .red
        case .error: return .orange
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .idle:
            Text("Tap to talk").font(.footnote).foregroundStyle(.secondary)
        case .listening:
            Text("Listening…").font(.footnote).foregroundStyle(.secondary)
        case .thinking:
            Text("Jesse is thinking…").font(.footnote).foregroundStyle(.secondary)
        case .received:
            // The bridge has the turn, so the answer is coming even if the phone is put away.
            // Standard watchOS only: the existing spinner plus one secondary footnote line, no
            // custom animation and no new colour.
            VStack(spacing: 4) {
                ProgressView()
                Text("Received").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Received by Jesse. Your message is saved and will be answered.")
        case .queued:
            Text("Will send when your phone is reachable.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .reply(let display, _):
            ScrollView {
                Text(display).font(.body)
            }
        case .error(let message):
            ScrollView {
                Text(message).font(.footnote).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
