#if os(iOS)
import SwiftUI
import iPocketTubeCore
import UIKit

struct AppIconPreviewImage: View {
    let style: AppIconStyle

    var body: some View {
        if let url = Bundle.module.url(
            forResource: style.previewAssetName,
            withExtension: "png"
        ), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay {
                    Image(systemName: "app.dashed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }
}

struct AppIconPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let selectedStyle: AppIconStyle
    let isChanging: Bool
    let supportsAlternateIcons: Bool
    let onSelect: (AppIconStyle) -> Void

    @State private var target: AppIconColorTarget

    init(
        selectedStyle: AppIconStyle,
        isChanging: Bool,
        supportsAlternateIcons: Bool,
        onSelect: @escaping (AppIconStyle) -> Void
    ) {
        self.selectedStyle = selectedStyle
        self.isChanging = isChanging
        self.supportsAlternateIcons = supportsAlternateIcons
        self.onSelect = onSelect
        _target = State(initialValue: selectedStyle.colorTarget)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    selectedPreview
                    targetPicker
                    iconGrid
                    systemBoundaryNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Иконка AxrTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onChange(of: selectedStyle) { _, newStyle in
            target = newStyle.colorTarget
        }
    }

    private var selectedPreview: some View {
        VStack(spacing: 14) {
            ZStack {
                AppIconPreviewImage(style: selectedStyle)
                    .frame(width: 144, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

                if isChanging {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(.black.opacity(0.34))
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                }
            }
            .frame(width: 144, height: 144)

            VStack(spacing: 3) {
                Text("Предпросмотр")
                    .font(.title3.weight(.semibold))
                Text(selectionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.primary.opacity(colorSchemeContrast == .increased ? 0.24 : 0.10), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Предпросмотр иконки AxrTube, \(selectionSummary)")
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Что окрашиваем")
                .font(.headline)

            Picker("Что окрашиваем", selection: $target) {
                Text("Фон").tag(AppIconColorTarget.background)
                Text("Буквы").tag(AppIconColorTarget.glyph)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appIcon.colorTarget")
        }
    }

    private var iconGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92, maximum: 112), spacing: 14)],
            spacing: 18
        ) {
            ForEach(AppIconStyle.styles(for: target), id: \.self) { style in
                iconButton(style)
            }
        }
        .animation(.snappy, value: target)
    }

    private func iconButton(_ style: AppIconStyle) -> some View {
        let isSelected = style == selectedStyle
        return Button {
            guard supportsAlternateIcons, !isChanging else { return }
            onSelect(style)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    AppIconPreviewImage(style: style)
                        .frame(width: 74, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .background(Circle().fill(.white))
                            .offset(x: 7, y: -7)
                    }
                }

                Text(style.colorName)
                    .font(.caption.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .padding(.horizontal, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isChanging || !supportsAlternateIcons)
        .accessibilityLabel("\(target == .background ? "Цвет фона" : "Цвет букв"): \(style.colorName)")
        .accessibilityValue(isSelected ? "Выбрано" : "")
        .accessibilityIdentifier("settings.appIcon.\(style.rawValue)")
    }

    private var systemBoundaryNote: some View {
        Label {
            Text(
                supportsAlternateIcons
                    ? "Все варианты встроены в подписанную сборку. iOS не разрешает назначать произвольную фотографию или создавать новый оттенок во время работы приложения."
                    : "Смена иконки недоступна на этом устройстве. Предпросмотр продолжает работать."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var selectionSummary: String {
        let targetName = selectedStyle.colorTarget == .background ? "фон" : "буквы"
        return "\(targetName): \(selectedStyle.colorName.lowercased())"
    }

    private var cardBackground: AnyShapeStyle {
        if reduceTransparency {
            AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
        } else {
            AnyShapeStyle(.regularMaterial)
        }
    }
}
#endif
