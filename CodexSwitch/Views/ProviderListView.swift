import SwiftUI

struct ProviderListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedId: UUID?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            // Provider list — narrow sidebar
            VStack(spacing: 0) {
                List(selection: $selectedId) {
                    ForEach(appState.providers) { provider in
                        ProviderRow(provider: provider, isActive: provider.id == appState.activeProviderId)
                            .tag(provider.id)
                            .contextMenu {
                                if !provider.isOfficial {
                                    Button("Duplicate") {
                                        let copy = appState.duplicateProvider(provider)
                                        selectedId = copy.id
                                    }
                                    Button("Set Active") {
                                        appState.setActive(provider)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        appState.removeProvider(provider)
                                        if selectedId == provider.id { selectedId = nil }
                                    }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)

                // Bottom toolbar
                HStack {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add provider")
                    Spacer()
                    if let selectedId, let provider = appState.providers.first(where: { $0.id == selectedId }) {
                        Button { appState.setActive(provider) } label: { Image(systemName: "checkmark.circle") }
                            .buttonStyle(.borderless)
                            .help("Set as active provider")
                        if !provider.isOfficial {
                            Button {
                                appState.removeProvider(provider)
                                self.selectedId = nil
                            } label: { Image(systemName: "minus") }
                                .buttonStyle(.borderless)
                                .help("Remove provider")
                        }
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 170, idealWidth: 200, maxWidth: 240)

            // Detail editor
            if let selectedId, let provider = appState.providers.first(where: { $0.id == selectedId }) {
                ProviderEditor(provider: provider)
                    .environmentObject(appState)
                    .id(provider.id)
                    .frame(maxWidth: .infinity)
            } else {
                VStack { Spacer(); Text("Select a provider").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { selectInitialProviderIfNeeded() }
        .onChange(of: appState.providers) { _ in reconcileSelection() }
        .sheet(isPresented: $showAddSheet) {
            AddProviderSheet().environmentObject(appState)
        }
    }

    private func selectInitialProviderIfNeeded() {
        guard selectedId == nil else { return }
        selectedId = appState.activeProviderId ?? appState.providers.first?.id
    }

    private func reconcileSelection() {
        if let selectedId, appState.providers.contains(where: { $0.id == selectedId }) {
            return
        }
        selectedId = appState.activeProviderId ?? appState.providers.first?.id
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let provider: CodexProvider
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(provider.name)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                    if provider.isOfficial {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }
                }
                if !provider.isOfficial {
                    Text(provider.apiFormat.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Provider Editor

struct ProviderEditor: View {
    @EnvironmentObject private var appState: AppState
    let provider: CodexProvider

    @StateObject private var oauth = CodexOAuthManager.shared
    @State private var draft: CodexProvider = PresetProviders.officialProvider
    @State private var hasChanges = false
    @State private var isLoaded = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if provider.isOfficial {
                        officialView
                    } else {
                        customView
                    }
                }
            }

            // Bottom bar: Test Connection + Save (outside scroll)
            if !provider.isOfficial {
                Divider()
                HStack {
                    Button {
                        testing = true
                        testResult = nil
                        appState.testConnection(provider: draft) { result in
                            testing = false
                            switch result {
                            case .success(let msg): testResult = msg
                            case .failure(let err): testResult = "Failed: \(err.localizedDescription)"
                            }
                        }
                    } label: {
                        HStack {
                            if testing { ProgressView().controlSize(.small) }
                            Text("Test Connection")
                        }
                    }
                    .disabled(testing || draft.apiKey.isEmpty)

                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.contains("successful") ? .green : .secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if hasChanges {
                        Button("Save") { save() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load(provider) }
        .onChange(of: provider.id) { _ in load(provider) }
        .onChange(of: draft.name) { _ in markChanged() }
        .onChange(of: draft.baseURL) { _ in markChanged() }
        .onChange(of: draft.apiKey) { _ in markChanged() }
        .onChange(of: draft.apiFormat) { newValue in
            if newValue == .responses {
                draft.chatReasoning = nil
            } else if draft.chatReasoning == nil {
                draft.chatReasoning = .default
            }
            markChanged()
        }
        .onChange(of: draft.modelCatalog) { _ in markChanged() }
        .onChange(of: draft.chatReasoning) { _ in markChanged() }
        .onChange(of: draft.reviewModel) { _ in markChanged() }
        .onChange(of: draft.goalsEnabled) { _ in markChanged() }
    }

    // MARK: Subviews

    private var officialView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenAI Official")
                .font(.headline)
            Text("Uses your ChatGPT login for authentication. Select this provider to restore the official Codex CLI configuration.")
                .foregroundStyle(.secondary)

            // Current ChatGPT login state (from Keychain or ~/.codex/auth.json).
            // Info-only; the action button (sign in / sign out) lives in the
            // row below alongside "Restore Official Login".
            ChatGPTLoginStatus(oauth: oauth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

            HStack {
                if case .idle = oauth.phase {
                    Button("Sign in with ChatGPT") {
                        oauth.startDeviceFlow()
                    }
                    .buttonStyle(.bordered)
                } else if case .authenticated = oauth.phase {
                    Button("Sign out") {
                        oauth.signOut()
                    }
                    .buttonStyle(.bordered)
                } else if case .failed = oauth.phase {
                    Button("Try again") {
                        oauth.startDeviceFlow()
                    }
                    .buttonStyle(.bordered)
                }
                // Awaiting/exchanging phases: no extra button needed —
                // the flow's own controls live inside ChatGPTLoginStatus.

                Button("Restore Official Login") {
                    appState.setActive(provider)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            oauth.loadStoredAccount()
            if let account = oauth.account, case .idle = oauth.phase {
                oauth.surfaceStoredAccount(account)
            } else {
                oauth.surfaceAuthJSONAccountIfPresent()
            }
        }
        .padding(20)
    }

    private var customView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // General
            sectionHeader("General")
            VStack(spacing: 0) {
                fieldRow(label: "Name") {
                    TextField("", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: "Base URL") {
                    TextField("https://api.example.com", text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: "API Key") {
                    SecureField("", text: $draft.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: "API Format") {
                    Picker("", selection: $draft.apiFormat) {
                        ForEach(CodexApiFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: "Review Model") {
                    TextField("gpt-5.5", text: $draft.reviewModel)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: "Goal Mode") {
                    Spacer()
                    Toggle("", isOn: $draft.goalsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Model Catalog
            sectionHeader("Model Catalog")
            Text("Model ID is what Codex CLI sees. Display Name appears in Codex; both are sent to the provider as available models.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ModelCatalogTable(models: $draft.modelCatalog)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            // Chat Reasoning (Chat Completions only)
            if draft.apiFormat == .chatCompletions {
                sectionHeader("Chat Reasoning")
                VStack(spacing: 0) {
                    fieldRow(label: "Enable Thinking") {
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { draft.chatReasoning?.supportsThinking ?? false },
                            set: { draft.chatReasoning?.supportsThinking = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: "Enable Effort") {
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { draft.chatReasoning?.supportsEffort ?? false },
                            set: { draft.chatReasoning?.supportsEffort = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: "Thinking Param") {
                        Picker("", selection: Binding(
                            get: { draft.chatReasoning?.thinkingParam ?? "thinking" },
                            set: { draft.chatReasoning?.thinkingParam = $0 }
                        )) {
                            Text("thinking (GLM/Kimi Style)").lineLimit(1).tag("thinking")
                            Text("enable_thinking (Qwen/SiliconFlow Style)").lineLimit(1).tag("enable_thinking")
                            Text("reasoning_split (MiniMax Style)").lineLimit(1).tag("reasoning_split")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: "Effort Param") {
                        Picker("", selection: Binding(
                            get: { draft.chatReasoning?.effortParam ?? "none" },
                            set: { draft.chatReasoning?.effortParam = $0 }
                        )) {
                            Text("none").lineLimit(1).tag("none")
                            Text("reasoning_effort (DeepSeek Style)").lineLimit(1).tag("reasoning_effort")
                            Text("reasoning.effort (OpenRouter Style)").lineLimit(1).tag("reasoning.effort")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: "Effort Mode") {
                        Picker("", selection: Binding(
                            get: { draft.chatReasoning?.effortValueMode ?? .deepseek },
                            set: { draft.chatReasoning?.effortValueMode = $0 }
                        )) {
                            Text("DeepSeek").lineLimit(1).tag(CodexEffortValueMode.deepseek)
                            Text("Low/High").lineLimit(1).tag(CodexEffortValueMode.lowHigh)
                            Text("OpenRouter").lineLimit(1).tag(CodexEffortValueMode.openrouter)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: "Output Format") {
                        Picker("", selection: Binding(
                            get: { draft.chatReasoning?.outputFormat ?? "reasoning_content" },
                            set: { draft.chatReasoning?.outputFormat = $0 }
                        )) {
                            Text("reasoning_content (DeepSeek/GLM/Kimi/Qwen Style)").lineLimit(1).tag("reasoning_content")
                            Text("reasoning_details (MiniMax Style)").lineLimit(1).tag("reasoning_details")
                            Text("reasoning (Other Providers)").lineLimit(1).tag("reasoning")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .padding(.top, 20)
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 120, alignment: .leading)
                .font(.body)
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func markChanged() {
        guard isLoaded else { return }
        hasChanges = true
    }

    private func load(_ provider: CodexProvider) {
        isLoaded = false
        draft = provider
        testResult = nil
        testing = false
        hasChanges = false
        DispatchQueue.main.async { isLoaded = true }
    }

    private func save() {
        appState.updateProvider(draft)
        hasChanges = false
    }
}

// MARK: - Model Catalog Table

struct ModelCatalogTable: View {
    @Binding var models: [CodexCatalogModel]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("Model ID")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Display Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Context")
                    .frame(width: 90, alignment: .leading)
                Color.clear.frame(width: 24)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Rows
            if models.isEmpty {
                Text("No models defined")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(models.indices, id: \.self) { index in
                        HStack(spacing: 12) {
                            TextField("model-id", text: $models[index].model)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            TextField("Display Name", text: $models[index].displayName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            TextField("128000", value: $models[index].contextWindow, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Button {
                                models.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 24)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        if index != models.indices.last {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }

            Divider()

            // Actions
            HStack(spacing: 8) {
                Button {
                    models.append(CodexCatalogModel(model: "", displayName: "", contextWindow: nil))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add Model")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
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
            Text("Add Provider").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
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
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
