<h1 align="center">🦕 Osaurus (Intel)</h1>

<p align="center">
  <strong>The AI agent harness for the Macs everyone else gave up on.</strong><br>
  A fork of <a href="https://github.com/osaurus-ai/osaurus">Osaurus</a> that runs natively on <strong>Intel Macs</strong> — cloud-powered, fully native x86_64, no Rosetta.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%20(Intel%20x86__64)-black?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Inference-Cloud%20(DeepSeek%20%2F%20OpenAI--compatible)-brightgreen" alt="Inference">
  <img src="https://img.shields.io/badge/Built%20with-Swift-orange?logo=swift" alt="Swift">
</p>

---

## ☀️ Why this exists

Old tech shouldn't be trash.

Apple stops shipping updates, a machine gets labelled "obsolete," and a perfectly good computer is quietly pushed toward landfill. But a 2017 Intel MacBook is still a *lovely* machine — and there's no reason it can't be **AI-ready**, even if it can't run a language model locally.

Upstream [Osaurus](https://github.com/osaurus-ai/osaurus) is an Apple-Silicon–only app: it leans on MLX for on-device inference, Apple's Containerization for sandboxing, and other arm64-bound frameworks. This fork **amputates the Apple-Silicon-only pieces** and replaces local inference with **cloud APIs**, so the whole agent experience — chat, tools, plugins, schedules, memory, RAG — runs on an Intel Mac through a remote model.

It was built, in large part, to give one specific 2017 MacBook a second life. We named her **Rosy**. She runs macOS Sequoia via [OpenCore Legacy Patcher](https://dortania.github.io/OpenCore-Legacy-Patcher/), and now she runs Osaurus. 🌸

> This is a personal labour of love, not an official Osaurus build. Enormous gratitude to the upstream team — please support the [original project](https://github.com/osaurus-ai/osaurus) first.

---

## ✅ What works on Intel

- 💬 **Cloud chat** — DeepSeek and any OpenAI-compatible provider, configured in Settings → Providers
- 🧠 **Live reasoning** — watch the model think in real time
- 🔧 **Tool calling** — built-in tools + an agentic loop, with live "calling…" cards
- 🧩 **Native x86_64 plugins** — the slim plugin host `dlopen`s real x86_64 dylibs (search, fetch, time, custom RAG, …)
- 🗂️ **Folder context** — point a chat at a working directory; file tools operate on the real filesystem
- ⏰ **Schedules & 👁️ watchers** — automate runs on a timer or on file changes
- 🎨 **Themes**, 🧑‍🤝‍🧑 **agents**, 🔌 **MCP tools**, and 🆔 **identity sync** (iCloud Keychain)
- ⌨️ **Global hotkey** to summon the chat window from anywhere

## 🚫 What's amputated (Apple Silicon only)

These depend on arm64-only frameworks and are disabled on Intel:

- **Local model inference** (MLX) — replaced by cloud providers
- **Voice / transcription** (FluidAudio)
- **Sandbox / containerization** (Apple Containerization) — tools run un-sandboxed (a non-sandboxed app already has full filesystem access)
- **Local vector index** (VecturaKit) — bring your own embeddings via a plugin

---

## 📦 Install (Intel Mac)

1. Download the latest `.app` from [Releases](https://github.com/reneezmp/osaurus/releases).
2. **Transfer it as a ZIP** (the build's frameworks use symlinks that iCloud Drive will mangle — always move it zipped).
3. Unzip, drag `osaurus.app` to `/Applications`.
4. Clear the quarantine flag:
   ```bash
   xattr -dr com.apple.quarantine /Applications/osaurus.app
   ```
5. Launch, then open **Settings → Providers** and add your API key (e.g. DeepSeek).

Requires an Intel Mac running a recent macOS (Sequoia tested via OCLP). Cloud inference needs an API key — there is no local model.

---

## 🔨 Build from source

```bash
# Core package (x86_64)
cd Packages/OsaurusCore && swift build --arch x86_64

# Full app (Debug, x86_64, ad-hoc signed)
cd ~/Developer/osaurus
xcodebuild -workspace osaurus.xcworkspace -scheme osaurus \
  -configuration Debug -arch x86_64 -derivedDataPath build/intel-debug \
  ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# Deploy build for an Intel Mac (canonical ~/.osaurus data path, ad-hoc signed)
CONFIG=Debug scripts/build/build_rosy.sh
```

The Intel fork is gated behind the `OSAURUS_INTEL` compilation flag. Amputated subsystems are listed in `Packages/OsaurusCore/Package.swift` (`exclude:`) and replaced by Intel mirrors under `Models/Chat/IntelConformers/`.

---

## 🏗️ How the port works

Upstream managers that pull in arm64-only dependencies are excluded from the Intel build and replaced by lean "Intel mirror" implementations (`IntelConformers/*.swift`). Local inference is swapped for `CloudChatEngine`, which speaks the OpenAI-compatible streaming API and runs the tool/agent loop engine-side. Plugins are native x86_64 dylibs loaded through a frozen C ABI. The full archaeology — every excluded subsystem, every mirror, every fix — lives in [`INTEL_ARCHEOLOGY.md`](./INTEL_ARCHEOLOGY.md).

---

## 🙏 Credits

Built on [Osaurus](https://github.com/osaurus-ai/osaurus) by the Osaurus team. This fork only exists because they made something worth porting. All upstream licenses and copyrights apply — see [`LICENSE`](./LICENSE).

<p align="center"><em>For Rosy, and every machine they told us to throw away.</em> 🌸☀️</p>
