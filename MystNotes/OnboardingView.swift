import SwiftUI

/// A swipeable, one-time introduction shown the very first time the app is
/// opened (see `AppSettings.hasSeenOnboarding`, checked in `ContentView`).
/// This covers the app as a whole at a glance; the deeper, hands-on tour of
/// the actual notebook interface lives in the auto-generated "Welcome to
/// Linework" notebook (see `TutorialNotebookFactory`) instead of here.
///
/// Five slides: a brand hero, then one idea each. Short sentences, no jargon.
struct OnboardingView: View {
    var onFinish: () -> Void

    private struct Slide {
        let symbol: String
        let tint: Color
        let title: String
        let subtitle: String
    }

    /// Slide 0 is the hero and draws the brand mark instead of a symbol.
    private let slides: [Slide] = [
        Slide(
            symbol: "",
            tint: .white,
            title: "Welcome to Linework",
            subtitle: "Write naturally with Apple Pencil. Five inks, shapes that snap clean, and a lasso to move what you drew."
        ),
        Slide(
            symbol: "point.3.connected.trianglepath.dotted",
            tint: Palette.node,
            title: "Connect your pages",
            subtitle: "Link any page to any other. Page Map shows your notes as a graph you can draw on."
        ),
        Slide(
            symbol: "magnifyingglass",
            tint: .accentColor,
            title: "Find anything",
            subtitle: "Search typed text, PDFs and even your handwriting, all in one place."
        ),
        Slide(
            symbol: "sparkles",
            tint: .accentColor,
            title: "Study in your own hand",
            subtitle: "An optional AI helper can quiz you from your own handwriting. It stays off until you turn it on."
        ),
        Slide(
            symbol: "lock.shield",
            tint: .accentColor,
            title: "Your notes stay yours",
            subtitle: "Sync through a folder you choose. Export everything, any time."
        )
    ]

    @State private var currentIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHero: Bool { currentIndex == 0 }
    private var isLast: Bool { currentIndex == slides.count - 1 }

    var body: some View {
        ZStack {
            TabView(selection: $currentIndex) {
                ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                    slideView(slide, index: index)
                        .tag(index)
                }
            }
            #if targetEnvironment(macCatalyst) || canImport(UIKit)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { onFinish() }
                        .font(Typography.label)
                        .foregroundStyle(isHero ? Color.white.opacity(0.9) : Color.secondary)
                        .minimumHitTarget()
                        .opacity(isLast ? 0 : 1)
                        .disabled(isLast)
                }
                .padding(.horizontal, Space.l)

                Spacer()

                pageDots
                    .padding(.bottom, Space.xl)

                Button {
                    if isLast {
                        onFinish()
                    } else {
                        withAnimation(reduceMotion ? nil : Motion.gentle) { currentIndex += 1 }
                    }
                } label: {
                    Text(isLast ? "Get Started" : "Continue")
                        .font(Typography.headline)
                        .foregroundStyle(isHero ? Palette.ink : Color.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(isHero ? Color.white : Color.accentColor)
                .frame(maxWidth: 420)
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.xl)
            }
            .padding(.top, Space.s)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .persistentSystemOverlays(.hidden)
        #endif
    }

    private var pageDots: some View {
        HStack(spacing: Space.s) {
            ForEach(0..<slides.count, id: \.self) { index in
                Capsule()
                    .fill(dotColor(for: index))
                    .frame(width: index == currentIndex ? Space.xl : Space.s, height: Space.s)
            }
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: currentIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentIndex + 1) of \(slides.count)")
    }

    private func dotColor(for index: Int) -> Color {
        if isHero {
            return index == currentIndex ? Color.white : Color.white.opacity(0.35)
        }
        return index == currentIndex ? Color.accentColor : Color.primary.opacity(0.2)
    }

    @ViewBuilder
    private func slideView(_ slide: Slide, index: Int) -> some View {
        let hero = index == 0
        ZStack {
            if hero {
                LinearGradient(colors: [Palette.ink.mix(with: .black, by: 0.12), Palette.ink],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            VStack(spacing: Space.xl) {
                Spacer()
                if hero {
                    BrandMarkShape()
                        .frame(width: 168, height: 168)
                        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                } else {
                    Image(systemName: slide.symbol)
                        .font(.system(size: 52, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(slide.tint)
                        .frame(width: 128, height: 128)
                        .background(Circle().fill(slide.tint.opacity(0.14)))
                        .accessibilityHidden(true)
                }
                VStack(spacing: Space.m) {
                    Text(slide.title)
                        .font(Typography.display)
                        .foregroundStyle(hero ? Color.white : Color.primary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(slide.subtitle)
                        .font(.title3)
                        .foregroundStyle(hero ? Color.white.opacity(0.85) : Color.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, Space.xxl)
                Spacer()
                // Room for the dots and the button that float above.
                Spacer().frame(height: 140)
            }
            .padding(Space.l)
        }
    }
}
