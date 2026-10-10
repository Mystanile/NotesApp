import SwiftUI

/// Edits one page's tags: chips you can remove, a field that adds on return.
struct PageTagsSheet: View {
    @State var tags: [String]
    let onDone: ([String]) -> Void
    @State private var input = ""

    /// `tags` plus the comma-separated names in `input`, normalized.
    static func adding(_ input: String, to tags: [String]) -> [String] {
        PageTags.normalized(tags + input.split(separator: ",").map(String.init))
    }

    static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { $0.lowercased() != tag.lowercased() }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Add a tag", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(commit)
                if tags.isEmpty {
                    Text("No tags yet.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading) {
                            ForEach(tags, id: \.self) { tag in
                                Button {
                                    tags = Self.removing(tag, from: tags)
                                } label: {
                                    Label("#\(tag)", systemImage: "xmark.circle.fill").lineLimit(1).fixedSize()
                                        .labelStyle(.titleAndIcon)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit(); onDone(tags) }
                }
            }
        }
    }

    private func commit() {
        tags = Self.adding(input, to: tags)
        input = ""
    }
}
