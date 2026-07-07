# PRD：Nest —— iOS 版 sing-box 代理客户端（从 SFI 剥离重建）

> 文档状态：草案 v1（2026-07-06）
> 作者：Randy　｜　产品代号：**Nest**（沿用已配置的 App ID `com.magicowl.nest`）
> 前置文档：`01-sfi-ne-layer.md`（NE 层结构）、`02-stability-poc-plan.md`（稳定性验证）、`03-learning-path.md`（学习路径）
> 关联记忆：`ios-clash-vpn-plan`（内核走 sing-box、订阅由本仓库 subconverter 转换）

---

## 1. 背景与目标

### 1.1 背景
- 已基于 SFI（sing-box-for-apple, GPL-3.0）在真机验证了完整链路：Libbox 内核跑进 NE 进程、TUN 建立、fakeip DNS 分流、国内直连/外网走代理全部跑通。
- SFI 是一个 **iOS + macOS + tvOS + 越狱** 的多平台超集工程，携带大量与 iOS 无关的 target、SPM 依赖和历史配置，不适合作为长期产品基座。
- 现在要**新建一个纯 iOS 工程 Nest**，只保留 SFI 中的 iOS 核心能力，作为后续自研（产品化 UI、subconverter 订阅转换接入）的干净起点。

### 1.2 本阶段目标（In Scope）
1. **产出一个纯 iOS 的 Xcode 工程**，只含 App 主体 + NE 扩展 + Widget 三个 target，从 SFI 拷贝必要的核心 Swift 文件与 `Libbox.xcframework`。
2. **完整保留 SFI 当前 iOS target 的核心功能**（见 §4），真机跑通，行为与现在验证过的一致。
3. 复用 SFI 现有 iOS SwiftUI 界面，**不重写 UI**（产品化 UI 留到后续阶段）。
4. 首版配置来源为**手动导入 sing-box JSON**（本地文件 / URL / iCloud / 二维码），与现状一致。

### 1.3 本阶段非目标（Explicitly Out of Scope）
- ❌ macOS / tvOS / 越狱 版本及其一切专属能力。
- ❌ subconverter 订阅转换接入（Clash 订阅 → sing-box JSON）——**延后到独立阶段**。
- ❌ Stash 风格的产品化 UI 重做——**延后**。
- ❌ Siri 快捷指令 / Intents。
- ❌ 后端服务、账号体系、内购、多语言润色等产品化外围。
- ❌ 自编 Libbox（裁剪协议 / 调内存参数）——先用 SFI 现成 xcframework，压测不过关再回到内核层（见 `01` §8）。

---

## 2. 目标用户与定位
- **单一用户：作者自用**（资深 iOS/Flutter 工程师），iPhone 真机，付费个人开发者账号自签 / TestFlight 安装。
- **定位：自用 + 开源**（GPL-3.0 合规，见 §7 风险）。不做商业分发、不做规模化，规避法律风险。
- **价值主张**：一个自己完全掌控、代码干净、可持续演进的 iOS Clash 生态客户端底座。

---

## 3. 平台与技术基线
| 项 | 决策 |
|---|---|
| 平台 | 仅 iOS（真机；NE 无法在模拟器运行） |
| 最低系统 | iOS 15.0+（50MiB NE 内存上限档；具体值构建时按 SFI 现有 deployment target 对齐，待确认见 §9） |
| 内核 | sing-box，via 预编译 `Libbox.xcframework`（带 `with_gvisor / with_clash_api / with_low_memory` 等 tag） |
| 语言 | Swift / SwiftUI（NE 进程必须原生，Flutter 引擎进不去） |
| 数据层 | GRDB（SQLite，建在 App Group 共享容器） |
| 进程模型 | 主 App + NE 扩展 + App Group 共享容器（三进程模型，见 `01` §1） |
| 标识符 | App `com.magicowl.nest`、NE `com.magicowl.nest.extension`、App Group `group.com.magicowl.nest`（已在 Apple 后台配置） |

---

## 4. 功能范围（核心保留清单）★本文重点

以「模块」为单位，标注**决策**（✅保留 / 🔧保留并改 / ⏭️延后 / ❌剥离）与**来源**（SFI 中对应文件/目录，路径相对 `sing-box-for-apple/`）。

### 4.1 隧道内核与生命周期（绝对核心，全保留）
| 功能 | 决策 | 来源 |
|---|---|---|
| NE 入口（PacketTunnelProvider，4 行继承） | ✅ | `Extension/PacketTunnelProvider.swift` |
| 隧道启停/睡眠/唤醒/热重载、Libbox 初始化、内存参数 `oomKillerEnabled` | ✅🔧 | `Library/Network/ExtensionProvider.swift` |
| Libbox↔Swift 桥：TUN fd 获取、`NEPacketTunnelNetworkSettings`、网络/WiFi 监控 | ✅🔧 iOS 路径，删 macOS/越狱分支 | `Library/Network/ExtensionPlatformInterface.swift` |
| 主 App 侧隧道控制器：安装 `NETunnelProviderManager`、start/stop/restart、下发启动参数 | ✅ | `Library/Network/ExtensionProfile.swift` |
| 启动参数打包（含 configContent）与 App Group 快照 | ✅ | `Library/Network/ExtensionStartOptions.swift` |
| on-demand 规则（被杀后自动复活兜底） | ✅ | `Library/Network/OnDemandRule.swift` |

### 4.2 跨进程 IPC 与运行时状态（核心，全保留）
| 功能 | 决策 | 来源 |
|---|---|---|
| IPC 客户端：订阅 status/groups/log/clashMode/connections/outbounds | ✅ | `Library/Network/CommandClient.swift` |
| 出站分组模型（≈Clash 策略组，供切节点） | ✅ | `Library/Network/OutboundGroup.swift` |
| Clash API 兼容面板（metacubexd/yacd 直连，内核内置） | ✅ | 内核 `with_clash_api`，无需额外代码 |
| 本地/远程 command 通道抽象中的**远程管理**部分 | ❌ 只留本地通道 | `Library/Network/CommandTarget.swift`（裁远程分支） |

### 4.3 配置与数据管理（保留核心，裁订阅转换）
| 功能 | 决策 | 来源 |
|---|---|---|
| 配置持久化（SQLite / App Group） | ✅🔧 表结构可简化 | `Library/Database/Database.swift` |
| Profile 增删改查、本地/远程(URL)/iCloud 三种来源、导入 | ✅ | `Library/Database/Profile*.swift`、`ProfileManager.swift` |
| 偏好开关（on-demand、includeAllNetworks 等） | ✅ | `Library/Database/SharedPreferences.swift` |
| App Group 容器路径（内核工作目录） | ✅🔧 改标识符 | `Library/Shared/FilePath.swift` |
| 标识符集中定义 | 🔧 全改为 `com.magicowl.nest` 系 | `Library/Shared/AppConfiguration.swift` |
| 订阅**自动更新**任务、profile server | ✅ | `ApplicationLibrary/Service/*` |
| **手动导入** sing-box JSON（本地/URL/iCloud/二维码） | ✅ | 现有导入路径 |
| Clash 订阅 → sing-box JSON 转换（subconverter） | ⏭️ 延后独立阶段 | — |

### 4.4 界面（首版复用 SFI iOS 视图，不重写）
| 功能 | 决策 | 来源 |
|---|---|---|
| 全套 iOS SwiftUI 界面（配置列表/连接开关/日志/流量/分组切换/设置） | ✅ 直接复用 iOS 分支 | `ApplicationLibrary/Views/*` |
| 内置配置编辑器（JSON5 语法高亮） | ✅ 保留 | `Frameworks/Runestone` + `TreeSitterJSON5` + CodeEdit* 依赖簇 |
| 二维码分享/扫码导入 | ✅ 保留 | `QRCode` / `swift-qrcode-generator` 依赖 |
| macOS/tvOS 专属视图 | ❌ | `MacLibrary/`、`ApplicationLibrary/Views` 内 macOS 分支 |

### 4.5 内存治理与可观测（保留，压测配套）
| 功能 | 决策 | 来源 |
|---|---|---|
| OOM 上报（jetsam 被杀取证） | ✅ | `Library/Shared/OOMReport*` |
| 崩溃上报 | ✅ | `Library/Shared/CrashReport*`、`NativeCrashReporter.swift`（PLCrashReporter） |
| 编译期变体开关 | ✅🔧 | `Library/Shared/Variant.swift` |

### 4.6 可选模块（按 §决策取舍）
| 模块 | 决策 | 来源 target |
|---|---|---|
| Widget 小组件（状态/流量） | ✅ 保留 | `WidgetExtension` |
| iCloud 配置同步 | ✅ 保留 | Profile iCloud 分支 + iCloud entitlement |
| 二维码分享 | ✅ 保留 | 见 4.4 |
| Siri 快捷指令 / Intents | ❌ 剥离 | `IntentsExtension` |
| 文件 Provider（Files.app 暴露配置） | ❌ 剥离（默认；如需再加，见 §9） | `FileProviderExtension` |

---

## 5. Target 与依赖剥离矩阵

### 5.1 Target 去留（基于 `xcodebuild -list` 实测 18 个 target）
**保留（4）**：`SFI`→重命名为 App、`Extension`、`Library`、`ApplicationLibrary`、`WidgetExtension`
（注：Library/ApplicationLibrary 是共享框架 target，保留但裁其中 macOS/tvOS/越狱代码。）

**剥离（macOS/tvOS/越狱/其他，全删）**：
`SFM`、`SFM.System`、`SystemExtension`、`SFT`、`TVExtension`、`MacLibrary`、`RootHelper`、`JailbreakDaemon`、`IntentsExtension`、`FileProviderExtension`、`SFMUITests`、`SFTUITests`
对应目录：`SFM*`、`SFT*`、`SystemExtension/`、`TVExtension/`、`MacLibrary/`、`HelperService/`、`Jailbreak/`、`JailbreakDaemon/`、`IntentsExtension/`、`FileProviderExtension/`

**UI 测试**：保留 `SFIUITests`（可选），删 macOS/tvOS 测试 target。

### 5.2 SPM 依赖去留
**保留**（iOS 核心/UI/编辑器/二维码/可观测）：
`GRDB`、`PLCrashReporter`、`BinaryCodable`、`swift-collections`、`Runestone`(local)、`TreeSitterJSON5`(local)、`SwiftTreeSitter`、`TreeSitter`、CodeEdit 系（`CodeEditLanguages/Symbols/TextView/SourceEditor`）、`TextStory/TextFormation/Rearrange`（Runestone 依赖链）、`QRCode`、`swift-qrcode-generator`、`NetworkImage`、`swift-markdown-ui`+`cmark-gfm`、`DeviceKit`、`SwiftImageReadWrite`、`SwiftLintPlugin`

**剥离**（macOS 专属）：
`GhosttyKit`（终端，macOS）、`MSDisplayLink`（macOS 刷新率）

> 说明：编辑器依赖簇（Runestone/TreeSitter/CodeEdit）体积不小但你选择保留配置编辑器，故整簇保留。若后续想瘦身，这是第一个可砍的模块。

---

## 6. 非功能需求
| 维度 | 要求 |
|---|---|
| 内存 | NE 进程稳态 ≤ 40MiB、测速尖峰不撞 50MiB（jetsam 上限）。验证方法见 `04-memory-stress-test.md`。 |
| 稳定性 | 长时间挂机不被杀；被杀能靠 on-demand 自动复活；OOM 可取证。 |
| 启动 | 冷启动到隧道就绪（"Here I stand"）秒级；配置热重载不断流。 |
| 兼容 | fakeip DNS + geosite/geoip-cn 分流行为与现验证配置一致（国内直连、外网走代理）。 |
| 可维护 | 工程干净、无 macOS/越狱死代码；标识符统一 `com.magicowl.nest` 系。 |

---

## 7. 约束与风险
- **GPL-3.0 传染**：Nest 源自 SFI（GPL-3.0），整个 App 需同以 GPL 开源（Hiddify/Karing 模式）。定位「自用+开源」正好合规；**不可闭源商业化**。
- **TUN fd 靠私有 KVC**（`packetFlow.value(forKeyPath:"socket.fileDescriptor")`）：Apple 未文档化，换 iOS 大版本需回归测试（见 `01` §4）。
- **分发**：个人账号只能自签/TestFlight；正式上架 App Store 需组织账号（Guideline 5.4）。本阶段不受影响。
- **法律风险**：中国大陆制作/分发翻墙工具有刑事判例，收费+规模化显著加重。严格按「自用+开源、不分发」推进。
- **`includeAllNetworks` 深坑**：默认关闭，做防泄漏前充分评估（见 `01` §11）。

---

## 8. 里程碑（衔接 `02-stability-poc-plan.md`）
- **M1 工程骨架**：新建纯 iOS 工程，App + NE + Widget 三 target，接入 `Libbox.xcframework`，标识符/entitlements/App Group 配好，能编译。
- **M2 核心链路跑通**：拷入 §4.1/4.2/4.3 核心文件，手动导入 sing-box JSON，真机连上能上网，行为对齐现状（fakeip + 国内直连）。
- **M3 界面接回**：复用 SFI iOS 视图 + Runestone 编辑器 + 二维码，形成可用 App。
- **M4 可选模块**：Widget、iCloud 同步接回并验证。
- **M5 稳定性验证**：执行 `04` 内存压测手册，确认 50MiB 约束下达标。
- （后续独立阶段）**M6**：接入 subconverter 订阅转换；**M7**：产品化 UI 重做。

---

## 9. 待确认 / 开放问题
1. **最低系统版本**：跟随 SFI 现有 deployment target，还是收敛到 iOS 16/17 以简化？（影响 API 可用性与内存档位）
2. **文件 Provider**：默认剥离。你是否需要在系统「文件」App 里直接看到/编辑配置？需要则保留 `FileProviderExtension`。
3. **App 显示名与图标**：`Nest`？还是另起名字？（App ID 已定 `com.magicowl.nest`，显示名可另取）
4. **工程搬运方式**：新工程是「手动逐文件拷贝 + 重配 target」还是「复制整个 SFI 后原地删非 iOS 部分再重命名」？前者更干净、后者更快，实现阶段再定。
5. **SwiftLint**：保留（推荐，维持代码规范）还是剥离以减依赖？

---

*下一步：本 PRD 定稿后，进入实现阶段第一步 = M1 工程骨架。实现前会再出一份「文件搬运清单 + target/entitlements 配置步骤」的可执行操作文档。*
