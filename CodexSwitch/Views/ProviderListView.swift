import SwiftUI

struct ProviderListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedProviderId: UUID?
    @State private var showingAddSheet = false

    var body: some View {
        HSplitView {
            // Left: Provider List
            VStack(spacing: 0) {
                List(selection: $selectedProviderId) {
                    ForEach(appState.providers) { provider in
                        ProviderRow(
                            provider: provider,
                            isActive: provider.id == appState.activeProviderId
                        )
                        .tag(provider.id)
                        .contextMenu {
                            if !provider.isOfficial {
                                Button("Duplicate") {
                                    let copy = appState.duplicateProvider(provider)
                                    selectedProviderId = copy.id
                                }
                                Button("Set Active") {
                                    appState.setActive(provider)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    appState.removeProvider(provider)
                                }
                            }
                        }
                    }
                }

                Divider()

                HStack {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }

                    Button {
                        if let id = selectedProviderId,
                           let provider = appState.providers.first(where: { $0.id == id }) {
                            appState.setActive(provider)
                        }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(selectedProviderId == nil)

                    Spacer()

                    Button {
                        if let id = selectedProviderId,
                           let provider = appState.providers.first(where: { $0.id == id }),
                           !provider.isOfficial {
                            appState.removeProvider(provider)
                            selectedProviderId = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedProviderId == nil || appState.providers.first(where: { $0.id == selectedProviderId })?.isOfficial == true)
                }
                .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 200)

            // Right: Provider Editor
            if let id = selectedProviderId,
               let provider = appState.providers.first(where: { $0.id == id }) {
                ProviderEditor(provider: provider)
            } else {
                VStack {
                    Spacer()
                    Text("Select a provider")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddProviderSheet()
        }
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let provider: CodexProvider
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.name)
                        .font(.body)
                    if provider.isOfficial {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }
                }
                HStack(spacing: 4) {
                    if !provider.isOfficial {
                        Text(provider.apiFormat.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Provider Editor

struct ProviderEditor: View {
    let provider: CodexProvider
    @EnvironmentObject private var appState: AppState

    @State private var editName: String = ""
    @State private var editBaseURL: String = ""
    @State private var editApiKey: String = ""
    @State private var editApiFormat: CodexApiFormat = .responses
    @State private var editModels: [CodexCatalogModel] = []
    @State private var editReasoning: CodexChatReasoning?
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if provider.isOfficial {
                    officialView
                } else {
                    customView
                }
            }
            .padding()
        }
        .onAppear { loadProvider() }
    }

    private var officialView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenAI Official")
                .font(.title2.bold())

            Text("Uses your ChatGPT login for authentication. Select this provider to restore the official Codex CLI configuration.")
                .foregroundStyle(.secondary)

            Button("Restore Official Login") {
                appState.setActive(provider)
            }
            .buttonStyle(.bordered)
        }
    }

    private var customView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // General
            GroupBox("General") {
                VStack(alignment: .leading, spacing: 12) {
                    labeledField("Name", text: $editName)
                    labeledField("Base URL", text: $editBaseURL, placeholder: "https://api.example.com")
                    labeledSecureField("API Key", text: $editApiKey)

                    Picker("API Format", selection: $editApiFormat) {
                        ForEach(CodexApiFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .onChange(of: editApiFormat) { newValue in
                        if newValue == .responses {
                            editReasoning = nil
                        } else if editReasoning == nil {
                            editReasoning = .default
                        }
                    }
                }
                .padding(8)
            }

            // Model Catalog
            GroupBox("Model Catalog") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Define the models available for this provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            editModels.append(CodexCatalogModel(model: "", displayName: "", contextWindow: nil))
                        } label: {
                            Label("Add Model", systemImage: "plus")
                        }
                        .controlSize(.small)
                    }

                    if editModels.isEmpty {
                        Text("No models defined")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        // Header
                        HStack {
                            Text("Model ID")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Display Name")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Context")
                                .font(.caption.bold())
                                .frame(width: 90)
                            Spacer()
                                .frame(width: 24)
                        }

                        ForEach(editModels.indices, id: \.self) { index in
                            HStack {
                                TextField("model-id", text: $editModels[index].model)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                                TextField("Display Name", text: $editModels[index].displayName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                                TextField("128000", value: $editModels[index].contextWindow, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 90)
                                Button {
                                    editModels.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .frame(width: 24)
                            }
                        }
                    }
                }
                .padding(8)
            }

            // Chat Reasoning (only for Chat Completions mode)
            if editApiFormat == .chatCompletions {
                GroupBox("Chat Reasoning") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Supports Thinking", isOn: Binding(
                            get: { editReasoning?.supportsThinking ?? false },
                            set: { editReasoning?.supportsThinking = $0 }
                        ))

                        Toggle("Supports Effort", isOn: Binding(
                            get: { editReasoning?.supportsEffort ?? false },
                            set: { editReasoning?.supportsEffort = $0 }
                        ))

                        Picker("Thinking Param", selection: Binding(
                            get: { editReasoning?.thinkingParam ?? "thinking" },
                            set: { editReasoning?.thinkingParam = $0 }
                        )) {
                            Text("thinking").tag("thinking")
                            Text("enable_thinking").tag("enable_thinking")
                            Text("reasoning_split").tag("reasoning_split")
                        }

                        Picker("Effort Param", selection: Binding(
                            get: { editReasoning?.effortParam ?? "none" },
                            set: { editReasoning?.effortParam = $0 }
                        )) {
                            Text("none").tag("none")
                            Text("reasoning_effort").tag("reasoning_effort")
                            Text("reasoning.effort").tag("reasoning.effort")
                        }

                        Picker("Effort Value Mode", selection: Binding(
                            get: { editReasoning?.effortValueMode ?? "passthrough" },
                            set: { editReasoning?.effortValueMode = $0 == "passthrough" ? nil : $0 }
                        )) {
                            Text("Passthrough").tag("passthrough")
                            Text("DeepSeek").tag("deepseek")
                            Text("Low/High").tag("low_high")
                            Text("OpenRouter").tag("openrouter")
                        }

                        Picker("Output Format", selection: Binding(
                            get: { editReasoning?.outputFormat ?? "reasoning_content" },
                            set: { editReasoning?.outputFormat = $0 }
                        )) {
                            Text("reasoning_content").tag("reasoning_content")
                            Text("reasoning_details").tag("reasoning_details")
                            Text("reasoning").tag("reasoning")
                        }
                    }
                    .padding(8)
                }
            }

            // Actions
            HStack {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(isTesting)

                if isTesting {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Spacer()

                if hasChanges {
                    Button("Save") {
                        saveProvider()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.contains("successful") ? .green : .secondary)
            }
        }
    }

    private var hasChanges: Bool {
        editName != provider.name ||
        editBaseURL != provider.baseURL ||
        editApiKey != provider.apiKey ||
        editApiFormat != provider.apiFormat ||
        editModels != provider.modelCatalog ||
        editReasoning != provider.chatReasoning
    }

    private func loadProvider() {
        editName = provider.name
        editBaseURL = provider.baseURL
        editApiKey = provider.apiKey
        editApiFormat = provider.apiFormat
        editModels = provider.modelCatalog
        editReasoning = provider.chatReasoning
        testResult = nil
    }

    private func saveProvider() {
        var updated = provider
        updated.name = editName
        updated.baseURL = editBaseURL
        updated.apiKey = editApiKey
        updated.apiFormat = editApiFormat
        updated.modelCatalog = editModels
        updated.chatReasoning = editReasoning
        appState.updateProvider(updated)
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        var testProvider = provider
        testProvider.name = editName
        testProvider.baseURL = editBaseURL
        testProvider.apiKey = editApiKey
        testProvider.apiFormat = editApiFormat
        testProvider.modelCatalog = editModels

        appState.testConnection(provider: testProvider) { result in
            isTesting = false
            switch result {
            case .success(let msg):
                testResult = msg
            case .failure(let error):
                testResult = "Failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Field Helpers

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label)
                .frame(width: 80, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledSecureField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 80, alignment: .leading)
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Add Provider Sheet

struct AddProviderSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Provider")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(height: 100)

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Add") {
                    let provider = CodexProvider(
                        name: name.isEmpty ? "New Provider" : name,
                        baseURL: baseURL,
                        apiKey: "",
                        apiFormat: .chatCompletions,
                        modelCatalog: [],
                        chatReasoning: .default,
                        isOfficial: false
                    )
                    appState.addProvider(provider)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
