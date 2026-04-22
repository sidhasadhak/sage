# Sage — Your Private AI Assistant

> A fully on-device AI assistant for iPhone that indexes your personal data and answers questions about your life — without sending anything to the cloud.

---

## Overview

Sage is a personal AI assistant built entirely around privacy. It reads your photos, contacts, calendar, reminders, and notes to build a searchable memory index on your device. You can then have natural conversations with a local large language model to recall information, surface connections, and get answers — all without a network request ever leaving your phone.

No subscriptions. No cloud processing. No data sharing. Everything runs on your iPhone.

---

## Features

### On-Device AI Chat
- Runs local LLMs downloaded directly to your device via [MLX](https://github.com/ml-explore/mlx-swift-examples) — Apple's machine learning framework optimised for Apple Silicon
- Supports a curated catalogue of models (Llama 3.2, Phi-3.5, Gemma 2, Mistral, Qwen 2.5, SmolLM and more)
- Streaming token generation with real-time responses
- Context-aware conversations — Sage searches your memory index before every reply to ground answers in your actual data

### Personal Memory Index
- **Photos** — indexes image metadata (date, location, reverse-geocoded place names) so you can ask "What photos did I take in Lisbon?"
- **Contacts** — indexes names, organisations, phone numbers, and emails so you can ask "Find everyone I know at Stripe"
- **Calendar & Reminders** — indexes events and tasks across a rolling 360-day window so you can ask "What meetings do I have this week?"
- **Notes** — full text of every note is embedded and searchable, including voice note transcriptions
- **Conversations** — past chat turns are indexed so Sage can reference what you previously discussed

### Semantic Search
- Embedding-based vector search powered by Apple's `NaturalLanguage` framework (`NLEmbedding`)
- Hybrid scoring: semantic similarity + keyword matching + recency weighting
- Hot/warm tiered memory — time-sensitive data (photos, events) older than 90 days is evicted from RAM automatically; contacts, notes and conversations stay available indefinitely

### Voice Notes
- Record voice memos directly in the app
- On-device speech recognition transcribes recordings automatically
- Transcriptions are indexed alongside written notes for unified search

### Model Management
- Browse and download models from a curated catalogue, filtered by family and capability
- Per-model metadata: parameter count, quantisation, context length, RAM requirements
- Download progress tracking with resume support
- One-tap model activation and unloading

### Memory Browser
- Browse, search, and filter every indexed memory chunk by source type
- Swipe-to-delete individual memories
- CoreSpotlight integration — memories are also surfaced in iOS system search

### Privacy & Sustainability
- **100% on-device** — zero network calls for AI inference or personal data processing
- **Delta indexing** — re-runs only process new or changed records; unchanged content is skipped entirely
- **Model eviction** — the LLM is automatically unloaded from GPU memory 3 minutes after the app backgrounds, freeing RAM for the rest of the system
- **Background processing** — heavy re-indexing is scheduled via `BGProcessingTask` to run only when the device is plugged in and idle

### Appearance
- Light, Dark, and System theme modes
- Persisted across launches via `AppStorage`

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 5.10 |
| UI | SwiftUI |
| Persistence | SwiftData |
| LLM Runtime | [MLX Swift](https://github.com/ml-explore/mlx-swift) · [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) 2.29.1 |
| Embeddings | `NaturalLanguage.NLEmbedding` (on-device, no model download required) |
| Vector Search | vDSP cosine similarity (Accelerate framework) |
| System Search | CoreSpotlight |
| Background Tasks | `BGProcessingTask` (BackgroundTasks framework) |
| Data Sources | Photos · Contacts · EventKit · Speech · AVFoundation |

---

## Requirements

- **Device:** iPhone with Apple Silicon (A-series or M-series chip)
- **OS:** iOS 17 or later
- **Storage:** 2 – 8 GB free depending on which model you download
- **Note:** LLM inference requires a physical device. The iOS Simulator does not support Metal GPU and cannot run models.

---

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/sage.git
cd sage
```

### 2. Open in Xcode

```bash
open Sage.xcodeproj
```

Swift Package Manager will resolve dependencies automatically on first open.

### 3. Configure signing

- Select the **Sage** target → **Signing & Capabilities**
- Set your **Team** to your Apple ID (a free Personal Team works)
- Update **Bundle Identifier** to something unique, e.g. `com.yourname.sage`

### 4. Run on device

Select your physical iPhone from the scheme picker and press `⌘R`.

> LLM models cannot be loaded in the Simulator. All other features (indexing, notes, search, settings) work in the Simulator.

### 5. Download a model

Navigate to the **Models** tab, pick a model suited to your device's RAM, and tap **Download**. Once downloaded, tap **Use This Model** and head to the **Chat** tab.

---

## Permissions

Sage requests the following permissions, all used exclusively on-device:

| Permission | Purpose |
|---|---|
| Photos | Index photo metadata (date, location) |
| Contacts | Index names, organisations, and contact details |
| Calendars | Index events and appointments |
| Reminders | Index tasks and deadlines |
| Microphone | Record voice notes |
| Speech Recognition | Transcribe voice notes on-device |

Sage never uploads personal data anywhere. All processing happens locally.

---

## Project Structure

```
Sage/
├── Design/
│   └── Theme.swift              # Colours, typography, animations
├── Models/                      # SwiftData model definitions
│   ├── Conversation.swift
│   ├── MemoryChunk.swift
│   ├── Message.swift
│   ├── Note.swift
│   └── LocalModel.swift
├── Services/
│   ├── Index/
│   │   ├── EmbeddingService.swift       # NLEmbedding wrapper
│   │   ├── IndexingService.swift        # Delta indexing orchestrator
│   │   ├── SemanticSearchEngine.swift   # Vector search + hot/warm tiering
│   │   └── SpotlightService.swift       # CoreSpotlight integration
│   ├── LLM/
│   │   ├── LLMService.swift             # MLX model lifecycle & generation
│   │   ├── ModelManager.swift           # Download, activation, deletion
│   │   ├── ModelCatalog.swift           # Curated model list
│   │   └── ContextBuilder.swift        # Memory retrieval for chat context
│   ├── Data/                    # Photos, Contacts, Calendar readers
│   ├── Permissions/             # Permission coordinator
│   └── Voice/                   # Audio recording & transcription
├── ViewModels/                  # @Observable view models
├── Views/
│   ├── Chat/                    # Chat list, chat view, message bubbles
│   ├── Memory/                  # Memory browser, filters
│   ├── Models/                  # Model library, model cards
│   ├── Notes/                   # Notes list, editor, voice recorder
│   ├── Root/                    # ContentView, tab structure
│   └── Settings/                # Permissions, indexing, appearance
├── AppContainer.swift           # Dependency container
├── SageApp.swift                # App entry point
└── Info.plist
```

---

## Roadmap

- [ ] iCloud / Files integration for cold-tier memory offloading
- [ ] Siri Shortcuts and App Intents support
- [ ] Share Extension for saving web content directly into Sage
- [ ] Email indexing (on-device Mail.app access)
- [ ] Proactive suggestions and daily briefings
- [ ] Export / backup of memory index

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Acknowledgements

- [MLX Swift Examples](https://github.com/ml-explore/mlx-swift-examples) — Apple's open-source MLX Swift model runner
- [HuggingFace Hub](https://huggingface.co) — model hosting
- Model families: Meta Llama, Microsoft Phi, Google Gemma, Mistral AI, Alibaba Qwen, HuggingFace SmolLM
