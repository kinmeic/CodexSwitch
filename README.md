# CodexSwitch

A native macOS menu bar app for managing OpenAI Codex CLI providers, with optional local proxy for protocol conversion.

Built with Swift + SwiftUI. No external dependencies.

## Features

- **Two Operating Modes**
  - **Direct Mode** — Provider supports OpenAI Responses API natively; Codex CLI connects directly, no proxy overhead
  - **Proxy Mode** — Provider uses Chat Completions API (DeepSeek, Kimi, Qwen, etc.); local proxy converts Responses ↔ Chat Completions in real time
- **Config Management** — Writes `~/.codex/auth.json`, `config.toml`, and model catalog JSON automatically
- **Protocol Conversion** — Full bidirectional conversion: request body, response body, streaming SSE, and error formats
- **Thinking / Reasoning Support** — Maps `reasoning.effort` to provider-specific parameters (`thinking`, `enable_thinking`, `reasoning_split`, etc.)
- **Cross-Turn History** — LRU cache (512 entries) restores `function_call` context for multi-turn tool-use conversations
- **Model Catalog** — Generates `cc-switch-model-catalog.json` from provider model definitions, using Codex CLI's built-in templates
- **Request Logs** — Color-coded log viewer with method, status, path, provider, and duration
- **Menu Bar Control** — Quick provider switching, proxy start/stop, and window access from the system tray

## Requirements

- macOS 13.0+ (Ventura)
- Xcode 15+
- [OpenAI Codex CLI](https://github.com/openai/codex)

## Build

```bash
cd CodexSwitch
bash build-debug.sh
open build/Debug/CodexSwitch.app
```

Or manually:

```bash
ruby generate_project.rb
xcodebuild -project CodexSwitch.xcodeproj -target CodexSwitch \
  -configuration Debug CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ARCHS=arm64
```

## Usage

1. Launch CodexSwitch — it appears as a menu bar icon
2. Go to the **Providers** tab and click **+** to add a provider
3. Fill in Name, Base URL, API Key, and select the API Format:
   - **Responses API (Direct)** — for OpenAI-compatible providers (OpenAI, Azure, some aggregators)
   - **Chat Completions (Proxy)** — for providers using the Chat Completions protocol (DeepSeek, Kimi, Qwen, GLM, etc.)
4. Add models to the catalog (Model ID + Display Name + optional context window)
5. For Chat Completions providers, configure reasoning parameters if the upstream supports thinking
6. Click **Test Connection** to verify the endpoint
7. Click **Save**, then **Start** on the Status tab
8. Run `codex` in your terminal — it reads the config written by CodexSwitch

## How It Works

### Direct Mode (Responses API)

```
Codex CLI ──(Responses API)──→ Upstream Provider
                   ↑
          config.toml base_url points
          directly to provider
```

CodexSwitch writes `~/.codex/config.toml` with `base_url` pointing to the provider and `experimental_bearer_token` for auth. No proxy is started.

### Proxy Mode (Chat Completions)

```
Codex CLI ──(Responses API)──→ 127.0.0.1:16827 ──(Chat Completions)──→ Upstream Provider
                                    │
                            CodexSwitch Proxy
                            • Enrich history
                            • Convert request body
                            • Map reasoning params
                            • Forward to /v1/chat/completions
                            • Convert response back
                            • Cache function calls
```

CodexSwitch writes `config.toml` with `base_url = "http://127.0.0.1:16827"` and starts a local HTTP proxy that:

1. Receives Responses API requests from Codex CLI
2. Enriches with cached `function_call` history for multi-turn tool use
3. Converts the request body from Responses format to Chat Completions format
4. Maps `reasoning.effort` to the provider's thinking/reasoning parameters
5. Forwards to the upstream `/v1/chat/completions` endpoint
6. Converts the response (or streaming SSE) back to Responses API format
7. Caches `function_call` outputs for the next turn

## Config Files

CodexSwitch manages three files in `~/.codex/`:

| File | Purpose |
|---|---|
| `auth.json` | API key storage (`OPENAI_API_KEY`) or ChatGPT OAuth tokens |
| `config.toml` | Provider routing, model selection, `wire_api`, auth config |
| `codex-switch-model-catalog.json` | Model definitions for Codex CLI's model picker |

When switching back to **OpenAI Official**, `config.toml` is pruned (managed keys/sections removed) while `auth.json` is preserved (protecting your ChatGPT login cache).

## Reasoning Configuration

For Chat Completions providers, CodexSwitch maps Codex's `reasoning.effort` to provider-specific parameters:

| Provider | thinking_param | effort_param | effort_mode | output_format |
|---|---|---|---|---|
| DeepSeek | `thinking` | `reasoning_effort` | deepseek | `reasoning_content` |
| Kimi / Moonshot | `thinking` | none | — | `reasoning_content` |
| Qwen / DashScope | `enable_thinking` | none | — | `reasoning_content` |
| GLM / Zhipu | `thinking` | none | — | `reasoning_content` |
| MiniMax | `reasoning_split` | none | — | `reasoning_details` |
| MiMo | `thinking` | none | — | `reasoning_content` |

## Architecture

```
CodexSwitch/
├── Models/              CodexProvider, CodexApiFormat, CodexCatalogModel, CodexChatReasoning
├── ViewModels/          AppState (central state + persistence + proxy lifecycle)
├── Views/               Status, Logs, Providers, Settings, MenuBar, OAuth
├── Services/
│   ├── CodexConfigManager     Read/write ~/.codex/ config files
│   ├── CodexOAuthManager      ChatGPT device-code OAuth flow + Keychain storage
│   ├── ProxyServer            NWListener-based HTTP proxy (port 16827)
│   ├── ProtocolConverter      Responses ↔ Chat Completions (request + response + errors)
│   ├── StreamingConverter     Chat Completions SSE → Responses API event stream
│   ├── ChatHistoryStore       Cross-turn function_call LRU cache (512 entries)
│   ├── CircuitBreaker         Per-provider failure isolation (Closed/Open/HalfOpen)
│   ├── RequestRectifier       Media sanitization + retry on image rejection
│   ├── CodexToolContext       Flatten/restore all 4 Responses tool kinds
│   ├── InlineThinkSplitter    Extract <think> tags from streaming content
│   ├── PresetProviders        Built-in OpenAI Official preset
│   └── Localization           Runtime in-app i18n (English + Simplified Chinese)
├── CodexSwitchApp.swift       @main entry + AppDelegate
└── AppEnvironment.swift       UserDefaults suite + paths + NetworkSessionManager
```

~2400 lines of Swift, no dependencies beyond Apple frameworks.

## License

MIT
