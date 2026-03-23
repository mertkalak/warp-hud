import SwiftUI

struct StatsView: View {
    let stats: StatsMonitor

    private var cpuColor: Color {
        if stats.cpuValue >= 20 {
            return Color(.sRGB, red: 1.0, green: 0.3, blue: 0.3, opacity: 0.9)
        } else if stats.cpuValue >= 10 {
            return Color(.sRGB, red: 1.0, green: 0.6, blue: 0.2, opacity: 0.85)
        } else {
            return Color(.sRGB, red: 0.45, green: 0.45, blue: 0.5, opacity: 0.7)
        }
    }

    private let ramColor = Color(.sRGB, red: 0.4, green: 0.4, blue: 0.45, opacity: 0.6)

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(stats.cpuText + " CPU")
                .font(.custom("Menlo", size: 9))
                .foregroundStyle(cpuColor)

            Text(stats.ramText + " RAM")
                .font(.custom("Menlo", size: 9))
                .foregroundStyle(ramColor)
        }
        .frame(minWidth: 48)
    }
}
