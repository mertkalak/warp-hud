import SwiftUI

struct HUDView: View {
    let state: HUDState
    let statsMonitor: StatsMonitor

    @State private var isCardsHovered = false
    @State private var isStatsHovered = false

    /// True when any non-selected card needs animation (flash or breathing).
    private var needsAnimation: Bool {
        state.sessions.contains { session in
            !session.isCurrentTab && (
                session.state == .working ||
                session.state == .waiting ||
                session.state == .done
            )
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !needsAnimation)) { timeline in
            let tick = timeline.date.timeIntervalSinceReferenceDate * 30.0

            HStack(spacing: 5) {
                // Cards section (with dark bg + border)
                HStack(spacing: 5) {
                    PinButton(state: state, visible: isCardsHovered)

                    ForEach(state.sessions) { session in
                        TabCard(
                            session: session,
                            isHovered: session.id == state.hoveredTabId,
                            animTick: tick,
                            onHover: { hovering in
                                state.setHoveredTab(hovering ? session.id : nil)
                            },
                            onTap: {
                                state.onTabClick?(session.id)
                            }
                        )
                    }
                }
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(.sRGB, red: 0.06, green: 0.06, blue: 0.08, opacity: 0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            Color(.sRGB, red: 0.25, green: 0.25, blue: 0.3, opacity: 0.3),
                            lineWidth: 0.5
                        )
                )
                .onHover { hovering in
                    isCardsHovered = hovering
                }
                .coordinateSpace(name: "hudCards")
                .onPreferenceChange(CardMidXPreference.self) { midXs in
                    state.cardMidXs = midXs
                }

                // Stats + gear section (floating, no background)
                HStack(spacing: 4) {
                    if state.showResourceUsage {
                        StatsView(stats: statsMonitor)
                    }

                    Image(systemName: "gearshape")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(
                            Color(.sRGB, red: 0.5, green: 0.5, blue: 0.55, opacity: 0.7)
                        )
                        .opacity(isStatsHovered ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.15), value: isStatsHovered)
                        .onTapGesture {
                            state.onSettingsToggle?()
                        }
                }
                .onHover { hovering in
                    isStatsHovered = hovering
                }
            }
            .fixedSize()
        }
    }
}
