import SwiftUI

struct GreenToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            RoundedRectangle(cornerRadius: 8)
                .fill(configuration.isOn
                    ? Color(.sRGB, red: 0.3, green: 0.85, blue: 0.4, opacity: 1.0)
                    : Color(.sRGB, red: 0.3, green: 0.3, blue: 0.35, opacity: 0.4))
                .frame(width: 32, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

struct SettingsView: View {
    @Bindable var state: HUDState
    var onClose: () -> Void

    private let labelColor = Color(.sRGB, red: 0.9, green: 0.9, blue: 0.92, opacity: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Settings")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(Color(.sRGB, red: 0.6, green: 0.6, blue: 0.65, opacity: 0.8))

                Spacer()

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(.sRGB, red: 0.5, green: 0.5, blue: 0.55, opacity: 0.7))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
            }

            Toggle(isOn: $state.showActiveTabTooltip) {
                Text("Full name below active tab")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(labelColor)
            }
            .toggleStyle(GreenToggleStyle())

            Toggle(isOn: $state.showActiveTabIndicator) {
                Text("Floating indicator panel")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(labelColor)
            }
            .toggleStyle(GreenToggleStyle())

            Toggle(isOn: $state.showResourceUsage) {
                Text("Resource usage")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(labelColor)
            }
            .toggleStyle(GreenToggleStyle())

            Divider()
                .background(Color(.sRGB, red: 0.3, green: 0.3, blue: 0.35, opacity: 0.4))

            Toggle(isOn: $state.quitWithWarp) {
                Text("Quit when Warp quits")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(labelColor)
            }
            .toggleStyle(GreenToggleStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(.sRGB, red: 0.1, green: 0.1, blue: 0.12, opacity: 0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    Color(.sRGB, red: 0.3, green: 0.3, blue: 0.35, opacity: 0.5),
                    lineWidth: 0.5
                )
        )
        .fixedSize()
    }
}
