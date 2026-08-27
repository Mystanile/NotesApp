import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)

/// The controls that appear while imported artwork is being adjusted -
/// rotate, crop, remove, done. Styled to match the drawing toolbar so
/// adjust mode reads as the same family of UI.
struct ImageAdjustToolbar: View {
    var isCropping: Bool
    var onRotate: () -> Void
    var onToggleCrop: () -> Void
    var onRemove: () -> Void
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if isCropping {
                // While cropping, the only meaningful actions are commit or
                // back out - rotating or deleting mid-crop would just be
                // confusing.
                labeledButton("Cancel", systemImage: "xmark", action: onToggleCrop)
                Divider().frame(height: 24)
                labeledButton("Apply Crop", systemImage: "checkmark", isProminent: true, action: onDone)
            } else {
                iconButton("rotate.right", action: onRotate)
                iconButton("crop", isOn: isCropping, action: onToggleCrop)
                Divider().frame(height: 24)
                iconButton("trash", isDestructive: true, action: onRemove)
                Divider().frame(height: 24)
                labeledButton("Done", systemImage: "checkmark", isProminent: true, action: onDone)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func iconButton(
        _ systemImage: String,
        isOn: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .frame(width: 34, height: 34)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                .foregroundStyle(isDestructive ? Color.red : (isOn ? Color.accentColor : Color.primary))
        }
    }

    private func labeledButton(
        _ title: String,
        systemImage: String,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .foregroundStyle(isProminent ? Color.accentColor : Color.primary)
        }
    }
}
#endif
