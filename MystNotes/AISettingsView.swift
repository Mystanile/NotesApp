import SwiftUI

/// Settings for the opt-in AI Study Helper. Keys go to the Keychain only.
struct AISettingsView: View {
    @AppStorage(AppSettings.Keys.aiEnabled) private var aiEnabled = false
    @AppStorage(AppSettings.Keys.aiModel) private var aiModel = AIClient.defaultModel
    @AppStorage(AppSettings.Keys.elevenVoiceID) private var voiceID = SpeechClient.defaultVoiceID

    @State private var featherlessKey = ""
    @State private var elevenKey = ""
    @State private var featherlessSaved = false
    @State private var elevenSaved = false
    @State private var keyError: String?

    @State private var isTesting = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var player = ReadAloudPlayer()

    private static let suggestions = [
        "Qwen/Qwen2.5-7B-Instruct",
        "meta-llama/Meta-Llama-3.1-8B-Instruct",
        "mistralai/Mistral-Nemo-Instruct-2407",
        "google/gemma-2-9b-it"
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI Study Helper", isOn: $aiEnabled)
            } footer: {
                Text("Off by default. When on, AI actions appear on pages and notebooks, and only run when you tap them.")
            }

            Section {
                SecureField("API key", text: $featherlessKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { saveFeatherless() }
                if featherlessSaved {
                    HStack {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove Key", role: .destructive) { removeFeatherless() }
                    }
                }
                TextField("Model", text: $aiModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        ForEach(Self.suggestions, id: \.self) { name in
                            Button { aiModel = name } label: {
                                Chip(title: name.components(separatedBy: "/").last ?? name,
                                     isSelected: aiModel == name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                Button {
                    runTest()
                } label: {
                    HStack {
                        Text("Test Connection")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting)
                if let testResult {
                    Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(Typography.caption)
                        .foregroundStyle(testResult.ok ? Color.green : Color.secondary)
                }
            } header: {
                Text("Featherless (text)")
            } footer: {
                if let url = URL(string: "https://featherless.ai") {
                    Link("Get a key at featherless.ai", destination: url)
                }
            }

            Section {
                SecureField("API key (optional)", text: $elevenKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { saveEleven() }
                if elevenSaved {
                    HStack {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove Key", role: .destructive) { removeEleven() }
                    }
                }
                TextField("Voice ID", text: $voiceID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    saveEleven()
                    if player.isPlaying || player.isLoading {
                        player.stop()
                    } else {
                        player.play(text: "This is how Linework sounds.")
                    }
                } label: {
                    HStack {
                        Text(player.isPlaying || player.isLoading ? "Stop" : "Test Voice")
                        if player.isLoading { Spacer(); ProgressView() }
                    }
                }
                if let error = player.error {
                    Text(error).font(Typography.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("ElevenLabs (read aloud)")
            } footer: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Without a key, Read Aloud uses your device's built-in voice.")
                    if let url = URL(string: "https://elevenlabs.io") {
                        Link("Get a key at elevenlabs.io", destination: url)
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("What is sent: only the text of the page or notebook you choose, when you tap an AI action. Ink images are never sent, and nothing is sent automatically. Your keys stay in this device's Keychain; they are not synced or exported.")
            }

            if let keyError {
                Section { Text(keyError).font(Typography.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("AI Study Helper")
        .onAppear {
            featherlessSaved = Keychain.get(Keychain.Account.featherless) != nil
            elevenSaved = Keychain.get(Keychain.Account.elevenlabs) != nil
        }
        .onDisappear {
            saveFeatherless()
            saveEleven()
            player.stop()
        }
    }

    private func saveFeatherless() {
        let trimmed = featherlessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.set(trimmed, for: Keychain.Account.featherless)
            featherlessKey = ""
            featherlessSaved = true
            keyError = nil
        } catch { keyError = error.localizedDescription }
    }

    private func removeFeatherless() {
        try? Keychain.set(nil, for: Keychain.Account.featherless)
        featherlessKey = ""
        featherlessSaved = false
        testResult = nil
    }

    private func saveEleven() {
        let trimmed = elevenKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.set(trimmed, for: Keychain.Account.elevenlabs)
            elevenKey = ""
            elevenSaved = true
            keyError = nil
        } catch { keyError = error.localizedDescription }
    }

    private func removeEleven() {
        try? Keychain.set(nil, for: Keychain.Account.elevenlabs)
        elevenKey = ""
        elevenSaved = false
    }

    private func runTest() {
        saveFeatherless()
        let model = aiModel
        isTesting = true
        testResult = nil
        Task {
            let client = AIClient(model: model)
            do {
                try await client.testConnection()
                testResult = (true, "Connected.")
            } catch {
                testResult = (false, (error as? LocalizedError)?.errorDescription ?? "Couldn't connect.")
            }
            isTesting = false
        }
    }
}
