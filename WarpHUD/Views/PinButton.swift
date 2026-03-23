import SwiftUI

struct PinButton: View {
    let state: HUDState
    let visible: Bool

    var body: some View {
        Image(systemName: state.isPinned ? "pin.fill" : "pin.slash")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(
                Color(.sRGB, red: 0.5, green: 0.5, blue: 0.55, opacity: 0.8)
            )
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .opacity(visible ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: visible)
            .onTapGesture {
                state.togglePin()
            }
    }
}
