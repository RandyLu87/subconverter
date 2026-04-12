# Copilot instructions

## Build, test, and lint commands

- **Core engine release build (matches CI):** `cd src/subconverter && bash scripts/build.macos.release.sh`
  - This is the canonical macOS packaging path from `.github/workflows/build.yml`.
  - It vendors/builds C++ dependencies, refreshes rules with `python scripts/update_rules.py -c scripts/rules_config.conf`, and produces the packaged runtime directory at repo root: `subconverter/`.
- **Core engine local CMake build:** `cmake -S src/subconverter -B build/subconverter -DCMAKE_BUILD_TYPE=Release && cmake --build build/subconverter -j6`
  - Use this for faster iteration when the required libraries from `src/subconverter/CMakeLists.txt` are already installed.
- **macOS app build:** `xcodebuild -project mac-app/SubConfigStudio.xcodeproj -scheme SubConfigStudio -configuration Debug build`
  - The Xcode project has a single app target and no separate test target.
- **Tests:** there is no automated test suite or Xcode test target in this checkout, so there is no full-suite or single-test command to run.
- **Lint:** there is no repo-level lint command or linter config checked in.

## High-level architecture

- `src/subconverter/` is the original C++ engine. `src/main.cpp` boots the local HTTP server, loads `pref.toml` / `pref.yml` / `pref.ini`, registers routes such as `/sub`, `/getruleset`, `/getprofile`, and `/render`, and then serves requests on `127.0.0.1:25500` by default.
- The conversion pipeline lives behind the `/sub` route in `src/subconverter/src/handler/interfaces.cpp`. That handler parses request flags, loads optional external config, fetches subscriptions, applies parsing/transformation in `parser/*` and `generator/config/*`, and returns either a full target config or a `proxies:` list when `list=true`.
- `src/subconverter/src/handler/settings.cpp` is the config-loading hub. It supports TOML/YAML/INI preferences plus `import` / `!!import:` expansion, and it preloads rulesets and other shared settings that the route handlers consume.
- The repo-root `subconverter/` directory is the packaged runtime payload, not just sample data. It contains the built `subconverter` executable plus `base/`, `rules/`, `snippets/`, `config/`, and `profiles/`. The macOS app bundles resources from this directory.
- `mac-app/SubConfigStudio/` is a SwiftUI wrapper around the C++ engine, not a second implementation of the converter. `RuntimeInstaller` copies the bundled runtime into `~/Library/Application Support/SubConfigStudio/runtime`, writes a minimal `pref.toml`, and `EngineController` launches the bundled binary and talks to it over `http://127.0.0.1:25500`.
- The macOS app only uses the engine to fetch merged Clash-format proxy data (`/sub?target=clash&list=true&config=...`). After that, the app parses the inline proxy list in `ProxyListParser`, deduplicates and renames collisions in `YAMLPostProcessor`, groups proxies by country in `ProxyCountryClassifier`, and assembles the final Clash YAML in `ClashConfigBuilder` using rule files from `mac-app/SubConfigStudio/Resources/AppRules/`.

## Key conventions

- There are **two runtime trees** in play:
  - `src/subconverter/base/` is the source template used by the C++ build scripts.
  - repo-root `subconverter/` is the packaged output consumed by the macOS app project (`mac-app/SubConfigStudio.xcodeproj` points at `../subconverter/subconverter`, `../subconverter/base`, `../subconverter/rules`, and `../subconverter/snippets`).
  - If you change runtime assets or the engine binary for the app, make sure the packaged repo-root `subconverter/` payload is updated too.
- Keep the engine/app wire contract stable unless you update both sides together. The Swift app expects `/sub?...&target=clash&list=true` to return text beginning with `proxies:` and proxy entries formatted as inline `- { key: value, ... }` maps.
- In the app, source ordering is meaningful. `AppModel` persists `SourceItem.order`, generation always sorts enabled sources by that order, and merged subscription order is preserved intentionally.
- Imported YAML files are validated by round-tripping them through the local engine (`SourceImportService` calls the same `/sub?...list=true` path used during generation). If you change import behavior, keep that validation path in sync.
- The app’s preset file intentionally disables the engine’s rule generator (`PresetBuilder.buildExternalConfig()` writes `enable_rule_generator = false`). The app builds its own policy groups and final rules locally, so changes to routing/group behavior usually belong in the Swift services, not the C++ rule generator.
- If you add or rename app rule lists, update both `mac-app/SubConfigStudio/Resources/AppRules/` and `PresetBuilder.ruleFiles`; the builder loads rule files by an explicit hard-coded list.
