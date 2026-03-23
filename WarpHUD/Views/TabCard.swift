import SwiftUI

/// PreferenceKey to report each card's midX in the parent coordinate space.
struct CardMidXPreference: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct TabCard: View {
    let session: Session
    let isHovered: Bool
    let animTick: Double
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    // MARK: - Animation helpers (from init.lua)

    /// Flash: bright for 8 frames, dim for 7 frames at 30fps (0.5s period)
    private var flashBright: Bool {
        (Int(animTick) % 15) < 8
    }

    /// Breathing sine pulse 0→1→0 (for working state)
    private var pulse: Double {
        (sin(animTick * 0.083) + 1) / 2
    }

    // MARK: - State flags

    private var isHoveredNotSelected: Bool {
        isHovered && !session.isCurrentTab
    }

    private var isAnimated: Bool {
        !session.isCurrentTab && !isHoveredNotSelected
    }

    // MARK: - Accent / text color

    private var accentColor: Color {
        if isHoveredNotSelected {
            return Color(red: 1.0, green: 0.6, blue: 0.2)  // HOVER_COLOR
        }
        if session.isCurrentTab {
            return stateAccent
        }
        // Animated states
        switch session.state {
        case .waiting:
            return flashBright
                ? Color(red: 1.0, green: 0.3, blue: 0.3)
                : Color(.sRGB, red: 0.6, green: 0.2, blue: 0.2, opacity: 0.7)
        case .done:
            return flashBright
                ? Color(red: 0.3, green: 0.85, blue: 0.95)
                : Color(.sRGB, red: 0.2, green: 0.5, blue: 0.6, opacity: 0.7)
        case .working:
            return Color(red: 1.0, green: 0.8, blue: 0.2)  // constant amber
        case .idle:
            return Color(red: 0.3, green: 0.9, blue: 0.4)
        }
    }

    /// Non-animated state accent (for selected tab)
    private var stateAccent: Color {
        switch session.state {
        case .working: return Color(red: 1.0,  green: 0.8,  blue: 0.2)
        case .idle:    return Color(red: 0.3,  green: 0.9,  blue: 0.4)
        case .done:    return Color(red: 0.3,  green: 0.85, blue: 0.95)
        case .waiting: return Color(red: 1.0,  green: 0.3,  blue: 0.3)
        }
    }

    // MARK: - Card background

    private var cardBackground: Color {
        if isHoveredNotSelected {
            return Color(.sRGB, red: 0.22, green: 0.16, blue: 0.1, opacity: 0.6)
        }
        if session.isCurrentTab {
            return selectedBackground
        }
        switch session.state {
        case .working: return Color(.sRGB, red: 0.18, green: 0.16, blue: 0.08, opacity: 0.6)
        case .idle:    return Color(.sRGB, red: 0.06, green: 0.16, blue: 0.08, opacity: 0.55)
        case .done:
            return flashBright
                ? Color(.sRGB, red: 0.08, green: 0.14, blue: 0.18, opacity: 0.55)
                : Color(.sRGB, red: 0.06, green: 0.10, blue: 0.12, opacity: 0.4)
        case .waiting: return Color(.sRGB, red: 0.28, green: 0.08, blue: 0.08, opacity: 0.7)
        }
    }

    private var selectedBackground: Color {
        switch session.state {
        case .working: return Color(.sRGB, red: 0.288, green: 0.256, blue: 0.128, opacity: 0.85)
        case .idle:    return Color(.sRGB, red: 0.096, green: 0.256, blue: 0.128, opacity: 0.85)
        case .done:    return Color(.sRGB, red: 0.128, green: 0.224, blue: 0.288, opacity: 0.85)
        case .waiting: return Color(.sRGB, red: 0.448, green: 0.128, blue: 0.128, opacity: 0.85)
        }
    }

    // MARK: - Border

    private var borderColor: Color {
        if session.isCurrentTab { return stateAccent }
        if isHoveredNotSelected { return Color(red: 1.0, green: 0.6, blue: 0.2) }
        switch session.state {
        case .waiting:
            return flashBright
                ? Color(red: 1.0, green: 0.3, blue: 0.3)
                : Color(.sRGB, red: 0.7, green: 0.2, blue: 0.2, opacity: 0.6)
        case .working:
            // Breathing border: sine-driven color + alpha
            let r = 0.6 + pulse * 0.2
            let g = 0.45 + pulse * 0.2
            let a = 0.25 + pulse * 0.35
            return Color(.sRGB, red: r, green: g, blue: 0.1, opacity: a)
        case .done:
            return flashBright
                ? Color(red: 0.3, green: 0.85, blue: 0.95)
                : Color(.sRGB, red: 0.2, green: 0.55, blue: 0.65, opacity: 0.6)
        case .idle:
            return Color.clear
        }
    }

    private var borderWidth: CGFloat {
        if session.isCurrentTab { return 2.5 }
        if isHoveredNotSelected { return 1.0 }
        switch session.state {
        case .waiting: return 1.5
        case .working: return CGFloat(0.5 + pulse * 0.8)  // 0.5→1.3
        case .done:    return 0.5
        case .idle:    return 0
        }
    }

    private let folderColor = Color(.sRGB, red: 0.65, green: 0.65, blue: 0.72, opacity: 0.9)

    // MARK: - Body

    var body: some View {
        HStack(spacing: 4) {
            Text("\(session.id)")
                .font(.custom("Menlo", size: 11))
                .fontWeight(session.isCurrentTab ? .bold : .regular)
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.folderName)
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(folderColor)
                    .lineLimit(1)

                Text(session.displayName)
                    .font(.custom("Menlo", size: 11))
                    .fontWeight(session.isCurrentTab ? .bold : .regular)
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: CardMidXPreference.self,
                        value: [session.id: geo.frame(in: .named("hudCards")).midX]
                    )
            }
        )
        .onHover { hovering in
            onHover(hovering)
        }
        .onTapGesture {
            onTap()
        }
    }
}
