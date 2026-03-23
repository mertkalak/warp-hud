import SwiftUI

struct TooltipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.custom("Menlo", size: 11))
            .foregroundStyle(Color(.sRGB, red: 0.95, green: 0.95, blue: 0.95, opacity: 1.0))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.sRGB, red: 0.1, green: 0.1, blue: 0.12, opacity: 0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        Color(.sRGB, red: 0.3, green: 0.3, blue: 0.35, opacity: 0.6),
                        lineWidth: 0.5
                    )
            )
            .fixedSize()
    }
}
