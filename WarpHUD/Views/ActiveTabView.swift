import SwiftUI

struct ActiveTabView: View {
    let fullName: String
    let folderName: String
    let state: SessionState
    let isPinned: Bool
    let onTogglePin: () -> Void

    @State private var isHovering = false

    private var stateSymbol: String {
        switch state {
        case .working: return "\u{2800}\u{2810}"  // ⠐ braille working indicator
        case .waiting: return "\u{25CF}"           // ● waiting
        case .done:    return "\u{2731}"           // ✱ done
        case .idle:    return ""
        }
    }

    private var stateColor: Color {
        switch state {
        case .working: return Color(red: 1.0,  green: 0.8,  blue: 0.2)
        case .idle:    return Color(red: 0.3,  green: 0.9,  blue: 0.4)
        case .done:    return Color(red: 0.3,  green: 0.85, blue: 0.95)
        case .waiting: return Color(red: 1.0,  green: 0.3,  blue: 0.3)
        }
    }

    private let folderColor = Color(.sRGB, red: 0.65, green: 0.65, blue: 0.72, opacity: 0.9)

    var body: some View {
        HStack(spacing: 0) {
            // Pin button — only visible on hover
            Image(systemName: isPinned ? "pin.fill" : "pin.slash")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Color(.sRGB, red: 0.5, green: 0.5, blue: 0.55, opacity: 0.6))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .opacity(isHovering ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
                .onTapGesture { onTogglePin() }
                .padding(.trailing, 4)

            // State symbol
            if !stateSymbol.isEmpty {
                Text(stateSymbol)
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(stateColor)
                    .padding(.trailing, 4)
            }

            // Folder name
            if !folderName.isEmpty && folderName != "~" {
                Text(folderName)
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(folderColor)
                    .padding(.trailing, 6)
            }

            // Full session name
            Text(fullName)
                .font(.custom("Menlo-Bold", size: 11))
                .foregroundStyle(stateColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.sRGB, red: 0.06, green: 0.06, blue: 0.08, opacity: 0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    Color(.sRGB, red: 0.25, green: 0.25, blue: 0.3, opacity: 0.3),
                    lineWidth: 0.5
                )
        )
        .fixedSize()
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
