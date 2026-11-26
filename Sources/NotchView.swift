// UI state and the shape that animates out of the notch.
import SwiftUI

enum Phase { case idle, notice, scanning, enrolling, success, fail }

final class UI: ObservableObject {
    @Published var phase = Phase.idle
    @Published var text = ""
    @Published var badge = ""      // external auth context (e.g. "sudo · ttys003")
    @Published var progress = 0.0  // enrollment ring, 0...1
    @Published var fails = 0       // each increment plays one shake
    var last = Float.infinity      // best distance of the last scan, shown in the menu for calibration
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 6), y: 0))
    }
}

struct NotchView: View {
    @ObservedObject var ui: UI
    let notch: CGSize

    var body: some View {
        let open = ui.phase != .idle
        let tint: Color = ui.phase == .success ? .green : ui.phase == .fail ? .red : .white
        VStack(spacing: 8) {
            ZStack {
                Circle().trim(from: 0, to: ui.progress)
                    .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: ui.progress)
                Image(systemName: ui.phase == .success ? "checkmark.circle.fill" : "faceid")
                    .font(.system(size: 34))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: ui.phase == .scanning || ui.phase == .enrolling)
            }
            .frame(width: 60, height: 60)
            Text(ui.text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            if !ui.badge.isEmpty {
                Text(ui.badge)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.14), in: Capsule())
                    .lineLimit(1)
            }
        }
        .padding(.top, notch.height + 6)  // content sits below the physical notch
        .opacity(open ? 1 : 0)
        // Closed, the black shape is exactly the notch, so it is invisible.
        .frame(width: open ? max(notch.width + 60, 260) : notch.width,
               height: open ? notch.height + (ui.badge.isEmpty ? 112 : 134) : notch.height, alignment: .top)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: open ? 26 : 8, bottomTrailingRadius: open ? 26 : 8, style: .continuous))
        .modifier(Shake(animatableData: CGFloat(ui.fails)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.linear(duration: 0.45), value: ui.fails)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: ui.phase)
    }
}
