import SwiftUI

/// A small preset sticker library (SF Symbols standing in for real sticker
/// art, which is a natural place to expand later).
struct StickerPickerView: View {
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let symbols = [
        "star.fill", "heart.fill", "checkmark.circle.fill", "flag.fill",
        "bolt.fill", "flame.fill", "leaf.fill", "moon.stars.fill",
        "exclamationmark.triangle.fill", "questionmark.circle.fill",
        "arrow.right.circle.fill", "pin.fill"
    ]

    private let columns = [GridItem(.adaptive(minimum: 60), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            onSelect(symbol)
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 32))
                                .foregroundStyle(.yellow)
                                .frame(width: 60, height: 60)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Add Sticker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
