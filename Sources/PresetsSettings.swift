import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// формат пресета живёт в репозитории: держать его копию в окне значило бы
/// поддерживать две редакции одного текста
private let shaderFormatURL = URL(
    string: "https://github.com/boundlessend/subvenio-screen/blob/main/DEVELOPMENT.md#writing-a-shader"
)!

/// коллекция пресетов целиком: папка, заготовка, возврат встроенных и то, что
/// не загрузилось. на вкладке эффекта эти кнопки стояли рядом с настройкой одного
/// пресета и читались как действия над ним
struct PresetsSettings: View {
    @ObservedObject var effects: EffectController
    @State private var isConfirmingRestore = false
    /// ответ на нажатие кнопки: он показывается здесь же, а не уезжает в меню-бар,
    /// потому что нажимали здесь
    @State private var outcome: String?

    var body: some View {
        Form {
            Section {
                Text(String(localized: """
                A preset is a folder with a manifest and a Metal shader. Drop one on this \
                window, or save a file in the folder: the menu updates itself, with no restart.
                """))
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Open shaders folder") {
                        NSWorkspace.shared.open(shadersDirectory())
                    }
                    Button("New preset from template") { newPreset() }
                    Button("Restore bundled presets") {
                        isConfirmingRestore = true
                    }
                    .confirmationDialog(
                        "Restore the bundled presets?",
                        isPresented: $isConfirmingRestore
                    ) {
                        Button("Restore", role: .destructive) { restoreBundled() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your edits to the bundled presets will be lost. Presets you added yourself are left alone.")
                    }
                }

                if let outcome {
                    Text(outcome)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // «открыть папку» без описания формата означает, что человек обязан
                // помнить манифест и сигнатуру фрагментной функции наизусть
                Link("How to write a preset", destination: shaderFormatURL)
                    .font(.callout)
            }

            if !effects.loadErrors.isEmpty {
                Section("Failed to load") {
                    ForEach(effects.loadErrors.indices, id: \.self) { index in
                        Text(effects.loadErrors[index].localizedDescription)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        // папка пресета лежит в контейнере песочницы, куда Finder сам не ходит:
        // перетаскивание это единственный способ поставить чужой пресет,
        // не пройдя пешком по служебному пути
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            install(providers)
            return true
        }
    }

    /// заготовка появляется в папке и сразу показывается в Finder: наблюдатель за папкой
    /// добавит её в меню сам, а человеку остаётся открыть shader.metal
    private func newPreset() {
        do {
            let created = try createPresetFromTemplate(in: shadersDirectory())
            NSWorkspace.shared.activateFileViewerSelecting([created])
            outcome = String(
                format: String(localized: "Created \"%@\" and showed it in Finder."),
                created.lastPathComponent
            )
        } catch {
            outcome = error.localizedDescription
        }
    }

    private func restoreBundled() {
        do {
            try effects.restoreBundled()
            outcome = String(localized: "The bundled presets are back the way they came.")
        } catch {
            outcome = error.localizedDescription
        }
    }

    private func install(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    do {
                        try effects.installDropped(url)
                        outcome = String(
                            format: String(localized: "Added \"%@\"."),
                            url.lastPathComponent
                        )
                    } catch {
                        outcome = error.localizedDescription
                    }
                }
            }
        }
    }
}
