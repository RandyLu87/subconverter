# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build commands

- **Core engine release build (matches CI):** `cd src/subconverter && bash scripts/build.macos.release.sh`
  Canonical packaging path from `.github/workflows/build.yml`. Vendors/builds C++ deps, refreshes rules with `python scripts/update_rules.py -c scripts/rules_config.conf`, and produces the packaged runtime at repo-root `subconverter/`.
- **Core engine fast local build:** `cmake -S src/subconverter -B build/subconverter -DCMAKE_BUILD_TYPE=Release && cmake --build build/subconverter -j6`
  Use when libs from `src/subconverter/CMakeLists.txt` are already installed.
- **macOS app debug build:** `xcodebuild -project mac-app/SubConfigStudio.xcodeproj -scheme SubConfigStudio -configuration Debug build`
- **macOS app DMG:** `mac-app/scripts/package_dmg.sh` (writes `mac-app/build/clashconvert.dmg`).
- **Run engine standalone:** `cd subconverter && ./subconverter` — listens on `127.0.0.1:25500`.
- **OpenClash shell flow:** `cd src/openclash/shell && cp config.yaml.example config.yaml && ./generate.sh` (requires `yq`, `curl`, `python3`).

No automated test suite, no Xcode test target, no repo-level lint.

## Architecture

This repo combines a C++ subscription-conversion engine (forked from tindy2013/subconverter) with a SwiftUI macOS GUI (`clashconvert`) and a shell-script workflow, all sharing the same local HTTP engine.

### Engine (`src/subconverter/`)

`src/main.cpp` boots the HTTP server, loads `pref.toml` / `pref.yml` / `pref.ini`, and registers routes (`/sub`, `/getruleset`, `/getprofile`, `/render`) on `127.0.0.1:25500`.

The conversion pipeline behind `/sub` is in `src/handler/interfaces.cpp`: parse flags → load optional external config → fetch subs → run `parser/*` and `generator/config/*` → return either a full target config or a `proxies:` list when `list=true`.

`src/handler/settings.cpp` is the config-loading hub — TOML/YAML/INI preferences plus `import` / `!!import:` expansion, preloading rulesets and shared settings.

### Two runtime trees — both matter

- `src/subconverter/base/` — source template used by C++ build scripts.
- repo-root `subconverter/` — packaged output consumed by the macOS app (`mac-app/SubConfigStudio.xcodeproj` references `../subconverter/subconverter`, `../subconverter/base`, `../subconverter/rules`, `../subconverter/snippets`).

If you change runtime assets or the engine binary used by the app, refresh the repo-root `subconverter/` payload too.

### macOS app (`mac-app/SubConfigStudio/`)

A SwiftUI wrapper, **not** a re-implementation of the converter:

- `RuntimeInstaller` copies the bundled runtime into `~/Library/Application Support/SubConfigStudio/runtime` and writes a minimal `pref.toml`.
- `EngineController` launches the bundled engine and speaks `http://127.0.0.1:25500`.
- The app only uses the engine to fetch merged Clash-format proxy data via `/sub?target=clash&list=true&config=...`. It then runs `ProxyListParser` → `YAMLPostProcessor` (dedup + rename collisions) → `ProxyCountryClassifier` → `ClashConfigBuilder`, assembling the final Clash YAML using `mac-app/SubConfigStudio/Resources/AppRules/`.

### Wire contract between app and engine

The Swift code expects `/sub?...&target=clash&list=true` to return text beginning with `proxies:`, with each entry as an inline `- { key: value, ... }` map. Keep both sides in sync if you touch this.

## Conventions that aren't obvious from the code

- **Source ordering is meaningful.** `AppModel` persists `SourceItem.order`; merged subscription order is preserved intentionally during generation.
- **YAML imports are validated by round-tripping through the engine.** `SourceImportService` uses the same `/sub?...list=true` path as generation. Keep the import validation path in sync with the generation path.
- **The app disables the engine's rule generator.** `PresetBuilder.buildExternalConfig()` writes `enable_rule_generator = false`. The app builds its own policy groups and final rules locally — routing/group changes usually belong in the Swift services, not the C++ rule generator.
- **App rule lists are loaded by an explicit hard-coded list** in `PresetBuilder.ruleFiles`. If you add or rename a file in `Resources/AppRules/`, update both places.
- **Policy groups are user-toggleable, and disabling one must drop its rules too.** `PresetBuilder.enabledPolicyGroups(disabled:)` is the single arbiter — both group rendering (`ClashConfigBuilder.build`) and rule filtering (`PresetBuilder.loadRuleLines`) go through it. A rule whose target group was not rendered makes mihomo reject the entire config, so the two must never drift. `Other` is in `alwaysEnabledPolicyGroups` because it is the `MATCH` target. The persisted state stores *disabled* groups, so groups added in later versions default to on for existing users.
- **`subconverter/metaconfig.ini` is the canonical Clash Meta template** for the shell-script flow (five-region HK/TW/JP/SG/US fallback + a `🧊 冷门节点` group). The macOS app does not use it — it has its own preset.
- **`subconverter/direct-whitelist.list`** is a project-specific custom direct-rule list (not an upstream subconverter concept). Format: `DOMAIN-SUFFIX,example.com` / `DOMAIN-KEYWORD,foo` etc.
- This fork adds **AnyTLS** subscription parsing on top of upstream.

## Agent skills

### Issue tracker

Issues live as GitHub issues in `RandyLu87/subconverter`, driven via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` + `docs/adr/` at the repo root (created lazily by `/domain-modeling`). See `docs/agents/domain.md`.
