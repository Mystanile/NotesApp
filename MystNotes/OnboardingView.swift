import SwiftUI

/// A swipeable, one-time introduction shown the very first time the app is
/// opened (see `AppSettings.hasSeenOnboarding`, checked in `ContentView`).
/// This covers the app as a whole at a glance; the deeper, hands-on tour of
/// the actual notebook interface lives in the auto-generated "Welcome to
/// Mystnotes" notebook (see `TutorialNotebookFactory`) instead of here.
struct OnboardingView: View {
    var onFinish: () -> Void

    private struct Slide {
        let symbol: String
        let title: String
        let subtitle: String
    }

    private let slides: [Slide] = [
        Slide(
            symbol: "note.text",
            title: "Welcome to Mystnotes",
            subtitle: "A fast, native notebook for Apple Pencil — draw, write, and organize, right on your iPad or Mac."
        ),
        Slide(
            symbol: "pencil.tip.crop.circle",
            title: "Draw naturally",
            subtitle: "Five ink types, custom colors and widths, a shape tool that cleans up rough lines, and a lasso to move what you've drawn."
        ),
        Slide(
            symbol: "rectangle.stack.badge.plus",
            title: "Stay organized",
            subtitle: "Nested folders, page templates, draggable text boxes, stickers, and links between pages — all inside every notebook."
        ),
        Slide(
            symbol: "play.rectangle",
            title: "Find & present anything",
            subtitle: "Search across typed text, PDFs, and even your handwriting. Presentation mode hides the chrome for a clean screen share."
        ),
        Slide(
            symbol: "icloud",
            title: "Synced everywhere",
            subtitle: "Your notebooks follow you between iPad and Mac automatically over iCloud — no setup needed."
        )
    ]

    @State private var currentIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                TabView(selection: $currentIndex) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        slideView(slide)
                            .tag(index)
                    }
                }
                #if targetEnvironment(macCatalyst) || canImport(UIKit)
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                #endif
                .animation(.easeInOut, value: currentIndex)

                HStack {
                    Spacer()
                    Button("Skip") { onFinish() }
                        .padding()
                        .opacity(currentIndex == slides.count - 1 ? 0 : 1)
                }
            }

            Button(currentIndex == slides.count - 1 ? "Get Started" : "Next") {
                if currentIndex == slides.count - 1 {
                    onFinish()
                } else {
                    withAnimation { currentIndex += 1 }
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .persistentSystemOverlays(.hidden)
        #endif
    }

    @ViewBuilder
    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: slide.symbol)
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor)
            Text(slide.title)
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text(slide.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            Spacer()
            Spacer()
        }
        .padding()
    }
}
