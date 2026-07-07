# 执行文档：Nest M1/M2 —— 新建纯 iOS 工程 + 文件搬运

> 状态：可执行草案 v1（2026-07-06）　｜　对应 PRD `05-prd.md` 里程碑 M1–M2
> 目标：从 SFI **逐文件拷贝**核心源码，用 XcodeGen 生成一个纯 iOS 的 `Nest` 工程，真机跑通，行为对齐现状。
> 已定参数：iOS 16+ / 无 FileProvider / 名字 **Nest** / 逐文件拷贝 / 保留 SwiftLint。

---

## 0. 环境与前置（已具备）
| 项 | 现状 |
|---|---|
| XcodeGen | `/opt/homebrew/bin/xcodegen` v2.44.1 ✅ |
| Xcode | 26.4（17E192）✅ |
| 内核 | `sing-box-for-apple/Libbox.xcframework`（含 ios-arm64 slice）✅ |
| 标识符 | App `com.magicowl.nest` / NE `com.magicowl.nest.extension` / Widget `com.magicowl.nest.widget` / App Group `group.com.magicowl.nest`（Apple 后台已建 App ID + App Group）✅ |
| Team | `FNLBJBJRM9` ✅ |
| SFI 源码 | `/Users/user/Documents/develop/sing-box-for-apple`（GPL-3.0）✅ |

**新工程位置**：`/Users/user/Documents/develop/Nest`（subconverter 仓库外的独立 GPL 项目；文档仍留在 `subconverter/docs/ios-app/`）。

---

## 1. 工程生成方式：XcodeGen（`project.yml` as code）
不手改 `.pbxproj`。用一份 `project.yml` 声明 3 个 target，`xcodegen generate` 产出 `Nest.xcodeproj`。好处：可复现、可 diff、可入 git、改 target/依赖只改 yml。

### 目标工程布局
```
Nest/
├── project.yml                  # XcodeGen 定义
├── Libbox.xcframework           # 从 SFI 拷入
├── App/                         # 主 App target（源自 SFI/ + ApplicationLibrary/ + Library/）
├── PacketTunnel/                # NE 扩展 target（源自 Extension/）
├── Widget/                      # Widget target（源自 WidgetExtension/）
├── Shared/                      # 三 target 共享的 Library/ 源码
└── .swiftlint.yml               # 从 SFI 拷
```
> 说明：SFI 用 Library/ApplicationLibrary 两个**独立 framework target** 被多平台共享。Nest 只有 iOS，不必拆 framework——可把 Library+ApplicationLibrary 源码直接编进各 target（用 XcodeGen 的 `sources` + `dependencies` 组织）。M1 先用「App 直接编译全部共享源码 + NE 只编译它需要的 Library 子集」的简化结构。

### 3 个 target（project.yml 概要）
| target | 类型 | Bundle ID | 关键设置 |
|---|---|---|---|
| `Nest`（App） | application | `com.magicowl.nest` | iOS 16、App Group、embeds PacketTunnel+Widget |
| `NestPacketTunnel` | app-extension（NEPacketTunnelProvider） | `com.magicowl.nest.extension` | iOS 16、App Group、networkextension entitlement、链接 Libbox.xcframework |
| `NestWidget` | app-extension（WidgetKit） | `com.magicowl.nest.widget` | iOS 16、App Group |

公共 build settings：`IPHONEOS_DEPLOYMENT_TARGET = 16.0`、`DEVELOPMENT_TEAM = FNLBJBJRM9`、`SWIFT_VERSION = 5.0`（对齐 SFI）、自动签名、SwiftLint build-tool plugin。

---

## 2. 文件搬运清单

标注：✅拷贝　❌不拷（iOS 无关）　🔧拷后改　✂️M2b 剪裁（先拷跑绿，再删）

### 2.1 `Library/` → `Nest/Shared/`
**✅ 全拷（无 guard / 混合 `#if os` / iOS 分支）：**
- Network：`CommandClient` `CommandTarget`🔧(删远程分支) `Extension+Iterator` `Extension+RunBlocking` `ExtensionEnvironments` `ExtensionErrors` `ExtensionPlatformInterface`🔧(删 macOS 分支) `ExtensionProfile` `ExtensionProvider` `ExtensionStartOptions` `HTTPClient` `NEVPNStatus+isConnected` `OnDemandRule` `OutboundGroup`
- Shared：`AppConfiguration`🔧(改标识符) `BlockingIO` `Bundle+Version` `Color+Extension` `CrashReportArchive` `CrashReportManager` `FilePath`🔧(改容器) `ImportedFontStore` `Logger+Extension` `NativeCrashReporter` `OOMReportArchive` `OOMReportManager` `ScreenshotLocalization` `URL+SecurityScopedAccess` `Variant`🔧
- Library.swift

**❌ 不拷（整文件 `#if os(macOS)` / `|| JAILBREAK`，iOS 下为空、仅被 macOS 分支引用）：**
`CommandXPC` `ConnectionOwnerLookup` `HelperServiceManager` `MachServiceClient` `RootHelperXPC` `ShellHelperXPC` `ShellSessionManager` `SystemExtension` `UserServiceEndpointPublisher` `UserServiceEndpointRegistry` `UserServiceXPC` `XPCMachServiceBridge` `JailbreakHelperManager` `JailbreakConfiguration` `Update/PKGDownloader` `Update/PKGInstaller`

**✂️ 先拷后议（M2b 决定去留）：**
`Update/GitHubUpdateChecker` `Update/UpdateInfo` `Update/UpdateTrack`（App 自更新，iOS 自签无意义，倾向删）；`Shared/TailscaleSSHPeerEntry` `Shared/TailscaleSSHPresentedSession`（Tailscale SSH 功能，倾向删）；`Database/Profile+Share` `Profile+Transferable`（分享/拖拽，看是否保留二维码分享）；`Database/RemoteServer*`（远程管理，倾向删）

**Database ✅ 全拷**：`Database` `Profile` `Profile+Date` `Profile+Hashable` `Profile+RW` `Profile+Update` `ProfileManager` `SharedPreferences` `SharedPreferences+Database`

### 2.2 `ApplicationLibrary/` → `Nest/App/`
**✅ 拷（核心 + 复用的 iOS UI）：**
`ApplicationLibrary.swift`、`Assets.xcassets`、`Service/*`（NWSocket/ProfileServer/ProfileUpdateTask/ReportTransfer*/UIProfileUpdateTask/UpdateManager）、`LubyTransform/*`（二维码 fountain code，配二维码分享）、`Views/Abstract/*`、`Views/Connections/*`、`Views/Dashboard/*`(除 `Components/InstallSystemExtensionButton`✂️、`RemoteDashboardView`✂️)、`Views/Groups/*`、`Views/Log/*`、`Views/Profile/*`、`Views/Scanner/QRScanner*`(除 `+macOS`❌)、`Views/NavigationPage` `EnvironmentValues`

**✂️ M2b 剪裁（与代理客户端无关的 SFI 小众功能，先拷跑绿再删，需连带改聚合视图）：**
- `Views/Tools/*` 里：`Tailscale*`（8 个）、`USBIP*`（5 个）、`STUNTest*`、`NetworkQuality*` → 删；`ToolsView` 🔧大改（删这些引用）
- `Views/Terminal/*`（11 个，Ghostty 终端 / Tailscale SSH）→ 全删
- `Views/RemoteControl/*`（4 个）→ 删；`SettingView`🔧删引用
- `Views/Setting/`：`EditGhosttyConfigView` `GhosttyConfigEditorEnvironment` `GhosttyConfigurationView` `JailbreakView` `MacAppView` `SponsorsView` `UpdateSheet` `FontPickerView`(看 ImportedFontStore) → 删；`SettingView`/`CoreView`🔧删引用
- `Views/Tools/`：`CrashReport*` `OOMReport*` `ExportReport*` `ReportShared` `OutboundPickerView` → ✅保留（内存/崩溃取证，压测要用）

### 2.3 `Extension/` → `Nest/PacketTunnel/`
✅ 全拷 3 个：`PacketTunnelProvider.swift`、`Info.plist`🔧、`Extension.entitlements`🔧(改 group)

### 2.4 `SFI/` → `Nest/App/`
✅ 拷：`Application.swift` `ApplicationDelegate.swift` `MainView.swift`🔧(删 Ghostty/Remote 引用) `ProfileEditorTheme` `ProfileEditorWrapperView` `RunestoneTextView`（Runestone 编辑器，保留）、`Assets.xcassets`、`Info.plist`🔧、`SFI.entitlements`🔧→`Nest.entitlements`
❌ 不拷：`GhosttyConfigEditorWrapperView`、`Export.plist`/`Upload.plist`（fastlane 上传，暂不需要）

### 2.5 `WidgetExtension/` → `Nest/Widget/`
✅ 全拷：`ExtensionBundle` `ServiceToggleControl` `WidgetTunnelControl` `Info.plist`🔧 `WidgetExtension.entitlements`🔧 `Assets.xcassets`

### 2.6 根级
✅ 拷：`Libbox.xcframework`、`Localizable.xcstrings`（本地化字串，UI 复用需要）、`.swiftlint.yml`（若 SFI 根有）

---

## 3. SPM 依赖（project.yml `packages`）
**M2a 跑绿先全保留 iOS 用得到的**：`GRDB` `PLCrashReporter` `BinaryCodable` `swift-collections` `Runestone`(local) `TreeSitterJSON5`(local) `SwiftTreeSitter` `TreeSitter` `Rearrange` `TextStory` `TextFormation` CodeEdit系 `QRCode` `swift-qrcode-generator` `NetworkImage` `swift-markdown-ui`+`cmark-gfm` `DeviceKit` `SwiftImageReadWrite` `SwiftLintPlugin`

**❌ 直接剥离（macOS 专属）**：`GhosttyKit`（终端）、`MSDisplayLink`
> 注：剥离 GhosttyKit 的前提是 §2.2 的 Terminal/Ghostty 视图已删——所以 M2a 若还没删 Terminal，则 GhosttyKit 暂留；M2b 删 Terminal 后同步删 GhosttyKit。

**M2b 复查可再砍**：`DeviceKit` `SwiftImageReadWrite` `swift-markdown-ui`（SponsorsView 用，删 Sponsors 后可去）

---

## 4. entitlements / Info.plist 要点
- **App（Nest.entitlements）**：`com.apple.security.application-groups = [group.com.magicowl.nest]`；iCloud（保留同步则加 `com.apple.developer.icloud-container-identifiers` + `ubiquity`）。
- **NE（Extension.entitlements）**：`com.apple.developer.networking.networkextension = [packet-tunnel-provider]`、`application-groups`、`com.apple.developer.networking.wifi-info`。
- **Widget**：`application-groups`。
- **NE Info.plist**：`NSExtensionPointIdentifier = com.apple.networkextension.packet-tunnel`、`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).PacketTunnelProvider`。
- 全局把 SFI 旧标识符 `io.nekohasekai.sfavt`/`group.io.nekohasekai.sfavt` 替换为 `com.magicowl.nest` 系（`AppConfiguration.swift` 是集中点）。

---

## 5. 执行步骤（分阶段，每步可编译校验）
- **M1a 骨架**：建 `Nest/` 目录 + `project.yml`（3 target、依赖、签名、iOS16、SwiftLint）+ 拷 `Libbox.xcframework` → `xcodegen generate` → 空壳能 `xcodebuild build`（CODE_SIGNING_ALLOWED=NO 冒烟）。
- **M1b 拷核心 Library**：按 §2.1 拷 Shared 源码，改 `AppConfiguration`/`FilePath`/`Variant` 标识符 → 编译共享层。
- **M2a 拷全 UI 跑绿**：按 §2.2/2.4/2.5 拷 UI（含暂留的 Tools/Terminal），拷 Extension → `xcodegen` → **真机 build**（Team 自动签名）→ 装机、导入 §nest-test-config.json → 连上能上网、fakeip+国内直连行为对齐。
- **M2b 剪裁无关模块**：按 §2.2✂️ 删 Terminal/Tailscale/USBIP/RemoteControl/Ghostty/Jailbreak/Sponsors/Update/STUN/NetworkQuality，改 `ToolsView`/`SettingView`/`CoreView`/`MainView` 删引用，同步删 §3❌ 依赖 → 编译器逐个报错修复直到再次跑绿。
- **M3 收尾**：Runestone 编辑器验证、Widget/iCloud 验证、`git init` 提交 project.yml + 源码。

---

## 6. 已知风险 / 验证点
- **TUN fd 私有 KVC**：`ExtensionPlatformInterface.openTun0` 那段换 iOS 大版本要回归（Xcode26/iOS18+ 已在真机验证过一次）。
- **XcodeGen 与 SFI 原 pbxproj 差异**：SFI 有 fastlane/多 scheme，Nest 用 XcodeGen 从零声明，首次生成后要核对：Libbox embed & sign、NE 的 `NSExtension` 键、App 对 NE/Widget 的 `embed without signing=false`（extension 要签名）。
- **共享源码编进多 target 的重复符号**：Library 源码若同时被 App 和 NE 直接编译，公共类型会各自有一份（不同 module 命名空间，不冲突），但 IPC 双方要用同一套 `LibboxSetupOptions` 序列化——沿用 SFI 逻辑即可，不动协议。
- **验证基线**：以 `subconverter/docs/ios-app/nest-test-config.json` 为测试配置，跑通=能上网 + baidu 走 direct + google 走 proxy(fakeip 198.18.x)。

---

*下一步：执行 M1a——创建 `Nest/` 骨架与 `project.yml`，生成工程并冒烟编译。*
