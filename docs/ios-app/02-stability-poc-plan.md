# iOS 稳定性验证 POC —— 详细执行计划

> 目标：把 SFI fork 到自己账号下，在**真机**上跑起来，用真实流量长时间验证 **NE 扩展进程在 iOS 50MiB 内存上限下的稳定性**。
> 非目标（本阶段不做）：subconverter 订阅转换集成、产品 UI 重做、上架、多端（macOS/tvOS）。
> 前置：已有付费 Apple 开发者个人账号；本机 Go 1.25.6 / Xcode 26.4；SFI 已 clone 到 `/Users/user/Documents/develop/sing-box-for-apple`。
> 关联：可行性见记忆 `ios-clash-vpn-plan`，NE 层结构见 `01-sfi-ne-layer.md`。

---

## 0. 核心策略：最小改动先跑通，瘦身留到后面

本阶段唯一要验证的风险是**内存/稳定性**，不是工程整洁度。因此：
- **不删** macOS/tvOS/越狱等 target，只改到"SFI scheme 能真机编译"为止；
- 无关的重型 SPM 依赖（Ghostty 终端、代码编辑器）**只在它们阻塞编译时才针对性移除**，不主动裁剪；
- 用**现成的 sing-box JSON 配置**（在线转换或手写）喂进去，不接自己的转换层。

把所有精力放在"跑起来 + 观测内存"这条主线上。

---

## 1. 关键事实快照（决定计划的硬约束）

| 事实 | 影响 |
|---|---|
| `Libbox.xcframework` 被 `.gitignore` 排除，**仓库里没有** | 必须先自己编内核产物（阶段 A），这是关键路径第一步 |
| sing-box `go.mod` 要求 Go ≥ 1.24.7，本机 1.25.6 | ✓ 满足；但 gomobile 需装 sagernet fork 版 |
| 本机无 `gomobile` | 需 `make lib_install` 安装 sagernet/gomobile@v0.1.13 |
| 签名 `CODE_SIGN_STYLE=Automatic`，`DEVELOPMENT_TEAM=287TTNZF8L`（原作者） | 改成自己的 Team ID |
| `BASE_PACKAGE_IDENTIFIER = io.nekohasekai.sfavt`（pbxproj 2 处） | 改成自己的 bundle id 前缀 |
| App Group / iCloud / entitlements 里硬编码 `io.nekohasekai.sfavt` | 全部改；iCloud 可直接去掉 |
| SFI 工程链接 Ghostty(GhosttyTerminal/Theme)、CodeEditSourceEditor、Runestone、MarkdownUI、QRCode、GRDB、DeviceKit、plcrashreporter、BinaryCodable | 首次构建会全拉；Ghostty/编辑器与稳定性验证无关，是潜在编译阻塞点 |
| 模拟器不支持 NE | 全程真机调试 |

---

## 2. 里程碑总览（关键路径）

```
A. 编出 Libbox.xcframework ──▶ B. 工程改造到能真机编译 ──▶ C. 真机跑通+塞配置 ──▶ D. 稳定性验证
   (Go/gomobile，~30-60min)       (签名/标识符/按需瘦身)        (装机+连上网)         (场景矩阵+挂机观测)
        ▲ 主要不确定性在这                                                            ▲ 项目成败在这
```

每个里程碑都有明确的"完成信号"，卡住就走对应的排错预案（第 7 节）。

---

## 3. 阶段 A：获取 Libbox.xcframework（内核）

**目标产物**：`sing-box-for-apple/Libbox.xcframework`（含 ios-arm64 slice）。

**步骤**：
1. 与 SFI 并排 clone sing-box 主仓库：
   ```bash
   cd /Users/user/Documents/develop
   git clone https://github.com/SagerNet/sing-box.git
   cd sing-box
   ```
   > 目录必须与 `sing-box-for-apple` 同级——`build_libbox` 默认把产物拷到 `../sing-box-for-apple/Libbox.xcframework`。
2. 装 gomobile（sagernet fork）：
   ```bash
   make lib_install      # go install github.com/sagernet/gomobile/cmd/{gomobile,gobind}@v0.1.13
   export PATH="$PATH:$(go env GOPATH)/bin"
   ```
3. 编 Apple 版内核：
   ```bash
   make lib_apple        # go run ./cmd/internal/build_libbox -target apple
   ```
   带的关键 tag：`with_gvisor with_quic with_wireguard with_clash_api ...` + **iOS 专属 `with_low_memory`**（省内存关键）。

**完成信号**：`ls ../sing-box-for-apple/Libbox.xcframework/ios-arm64/` 有 `Libbox.framework`。

**不确定性 & 备选**：gomobile 对 Xcode 26 / 新 iOS SDK 偶有兼容问题。若 `make lib_apple` 失败：
- 备选 1：用 sing-box 某个已发布 tag（如最新 stable）而非 main 分支重试，版本更稳。
- 备选 2：从 sing-box GitHub Actions 的 `build_libbox` workflow artifact 下载预编译 xcframework（省去本地 Go 编译）。
- 备选 3：临时只编 iOS slice 加快速度（如无该 make 目标则改 `build_libbox` 参数）。

---

## 4. 阶段 B：工程改造到"SFI 能真机编译"

**目标**：Xcode 里选 SFI scheme + 真机，Archive 前的 Build 通过、签名有效。

### B0. Apple Developer 后台标识符配置（**先做这一步**）

> 涉及 App Group + Network Extension 的 App ID **必须是 explicit（不能用 wildcard `*`）**，所以要手动在后台建。
> 用 Xcode Automatic 签名时它能自动代劳大部分，但 App Group 手动建更可控，推荐手动。

**命名方案**（前缀 `com.magicowl`，工程里只需把 `BASE_PACKAGE_IDENTIFIER` 设成 `com.magicowl.nest`，其余自动带出）：

| 用途 | 标识符 | 说明 |
|---|---|---|
| 主 App | `com.magicowl.nest` | 产品名 nest（巢），呼应 magicowl 品牌 |
| NE 扩展 | `com.magicowl.nest.extension` | SFI 约定 `$(BASE).extension`，最小改动 |
| App Group | `group.com.magicowl.nest` | 主 App 与扩展共享容器的钥匙 |

> ⚠️ bundle id 一旦上架 App Store 即固定。现在是 POC 可自由改；若确定产品名沿用，这套就能一直用下去。

**创建顺序**（Certificates, Identifiers & Profiles）：

1. **先建 App Group**：Identifiers → App Groups → 新建 `group.com.magicowl.nest`。
2. **建主 App ID** `com.magicowl.nest`，勾选 capabilities：
   - ☑ **App Groups**（编辑 → 关联到 `group.com.magicowl.nest`）
   - ☑ **Network Extensions**
   - （其余不勾）
3. **建扩展 App ID** `com.magicowl.nest.extension`，勾选：
   - ☑ **App Groups**（关联同一个 `group.com.magicowl.nest`）
   - ☑ **Network Extensions**
   - ☑ **Access WiFi Information**（分流按 SSID 用；SFI 扩展 entitlement 带 `wifi-info`）

**本阶段明确不启用 / 需从 SFI 里删除的**（否则注册/签名会失败）：
- ❌ **Multicast Networking**（`com.apple.developer.networking.multicast`）——这是**受限 entitlement，需单独向 Apple 申请**才能用。SFI 的 `Extension.entitlements` 带了它，**本阶段直接删掉这行**，不申请。
- ❌ **iCloud / CloudKit**（`com.apple.developer.icloud-*`、`ubiquity-*`）——SFI 主 App 带了，稳定性验证用不到，删掉对应 entitlements 与 capability，避免容器注册报错。
- ⚠️ **附属 extension**（Widget / Intents / FileProvider）——SFI 默认 embed 了它们，**它们各自的 `.entitlements` 也硬编码了旧 group / iCloud**，不改会在真机签名时报 `Application Group 'group.io.nekohasekai.sfavt' is not available` / `doesn't support the iCloud Container`。两种处理：
  - **改（本项目采用）**：把 `WidgetExtension/`、`FileProviderExtension/`、`IntentsExtension/` 三个 `.entitlements` 都改成只保留 `group.com.magicowl.nest`（Intents 额外删掉 iCloud 三项）。它们 bundle id 是 `$(BASE).widget/.fileprovider/.intents`，Automatic 签名会自动为这 3 个建 App ID 并关联 group。
  - **移除**：从 SFI target 的 Embed 与 Dependencies 里删掉它们，彻底不参与构建（更省事但要动 pbxproj/GUI）。

**net：本阶段只需在后台建 3 个标识符**（1 个 App Group + 2 个 App ID），各自 capabilities 如上表。签名时 Xcode 会据此生成 provisioning profile。

### B0.5. 初始化 git submodule（**否则 SPM 解析直接失败**）

SFI 用 submodule 管理 `Frameworks/Runestone`（内含嵌套的 TreeSitterJSON5）。若 clone 时没带 `--recurse-submodules`，`Frameworks/Runestone/Package.swift` 不存在，Xcode 会报 `Could not resolve package dependencies`。补一步：
```bash
cd /Users/user/Documents/develop/sing-box-for-apple
git submodule update --init --recursive
```

### B1. 用 Xcode 打开并让 SPM 解析
```bash
open /Users/user/Documents/develop/sing-box-for-apple/sing-box.xcodeproj
```
等待 Swift Package 依赖全部 resolve（首次较慢，Ghostty 等包体积大）。

### B2. 改标识符（3 类，务必全改）
1. **Team ID**：Xcode 里对 `SFI` 和 `Extension` 两个 target → Signing & Capabilities → Team 选自己的账号（Automatic 签名会自动改 pbxproj 里的 `DEVELOPMENT_TEAM`）。
2. **Bundle ID 前缀**：全局把 `io.nekohasekai.sfavt` 替换为 `com.magicowl.nest`。涉及：
   - `sing-box.xcodeproj/project.pbxproj`：`BASE_PACKAGE_IDENTIFIER`（2 处）→ `com.magicowl.nest`
   - `Extension/Extension.entitlements`、`SFI/SFI.entitlements`：App Group 改 `group.com.magicowl.nest`；**删除 iCloud/ubiquity 三项、删除 multicast 那一项**（见 B0）
   - `Library/Shared/AppConfiguration.swift`：集中定义处（若有硬编码）
3. **App Group**：已在 B0 后台注册 `group.com.magicowl.nest`；两个 target 的 Capabilities 里勾选同一个 group。**主 App 与 NE 必须用同一个 App Group**，否则共享容器失败、启动即崩。

### B3. Capabilities 核对
- SFI + Extension 两个 target 都要有 **Network Extensions → Packet Tunnel**（付费账号可自助勾）。
- 去掉本阶段不需要的：**iCloud/CloudKit**（entitlements 里删掉 icloud/ubiquity 三项，避免容器注册失败）、Widget/Intents/FileProvider 等附属 extension 可以从 SFI 的 embed 里先移除以减少签名面。
- 保留 `wifi-info`（分流可能用）、App Groups、network client/server。

### B4. 依赖瘦身（**仅在编译被阻塞时做**）
若 Ghostty(`GhosttyTerminal`/`GhosttyTheme`)、`CodeEditSourceEditor` 等在 iOS/Xcode26 上编译失败：它们服务于 SSH 终端 / 配置编辑器，与稳定性验证无关，可从出问题的 target 的 "Frameworks, Libraries, and Embedded Content" 或 Package Product 依赖里移除，并删掉引用它们的少量 Swift 文件（编译器会直接指出位置）。**能不动就不动**。

**完成信号**：`Product → Build`（真机 destination）成功，无签名错误。

---

## 5. 阶段 C：真机跑通 + 塞测试配置

### C1. 装到真机
- 数据线连 iPhone，Xcode 选该设备为 destination，Run。
- 首次运行需在 iPhone「设置 → 通用 → VPN 与设备管理」信任开发者证书。
- 首次连接会弹系统「允许 VPN 配置」授权（`NETunnelProviderManager.saveToPreferences` 触发）。

### C2. 准备一份测试用 sing-box JSON（不接转换层）
本阶段要真实流量才有意义，用你手上的节点，三选一拿到 sing-box JSON：
- **选项 1（推荐最快）**：把现有 Clash 订阅用在线 clash→sing-box 转换（公共 subconverter 带 `target=singbox`，或 sub-web/sub-store 类），导出 JSON。
- **选项 2**：手写单节点最简配置（验证跑通足够），结构：
  ```jsonc
  {
    "log": { "level": "info" },
    "inbounds": [{ "type": "tun", "stack": "gvisor", "auto_route": true }],
    "outbounds": [
      { "type": "<你的协议 vless/hysteria2/ss...>", /* 节点字段 */ "tag": "proxy" },
      { "type": "direct", "tag": "direct" }
    ],
    "route": { "rules": [{ "action": "sniff" }], "final": "proxy" },
    "experimental": { "clash_api": { "external_controller": "127.0.0.1:9090" } }
  }
  ```
  > 开着 `clash_api` 便于后面用 metacubexd/yacd 面板验证分流与看连接。
- **选项 3**：多节点 + 大规则集（rule-set）版本，专门用于阶段 D 的"大配置内存"场景。

在 app 里新建 profile 导入该 JSON（SFI 自带本地 profile 导入），选中它。

### C3. 冒烟验证
- 连接 → 状态变 connected → 手机能正常上网。
- 用面板或日志确认流量确实走了代理出站。

**完成信号**：真机上连上、能持续上网、断开正常。至此"跑起来"达成。

---

## 6. 阶段 D：稳定性验证方案（核心）

### D1. 观测手段
| 手段 | 看什么 | 怎么用 |
|---|---|---|
| Xcode Debug Navigator（attach 到 **Extension** 进程） | NE 进程实时内存/CPU | Debug → Attach to Process → 选 extension；或 scheme 里直接 debug extension |
| Instruments（Allocations / Leaks / VM Tracker） | 内存增长曲线、泄漏、峰值 | 针对 extension 长跑采样 |
| Console.app / `log stream` | **jetsam 杀进程事件**（`per-process-limit`） | 过滤 `jetsam` / 进程名，是 OOM 的铁证 |
| SFI 内置 `OOMReportManager` / OOM draft | 被杀后回捞 OOM 证据 | 断开后下次启动检查上报 |
| 电池 → App 用电（设置里） | 长跑功耗 | 挂机一夜后看 |

> 关键：**盯的是 NE 扩展进程，不是主 App**。主 App 内存宽裕，无参考意义。

### D2. 场景矩阵（每个场景记录：内存稳态/峰值、是否被杀、断连次数、异常）
1. **空载常驻**：连上不产生流量，挂 1–2h，看基线内存与是否漂移。
2. **日常浏览**：正常刷网页/App 30–60min，看稳态内存。
3. **大配置**：多节点 + 大 rule-set 配置（C2 选项 3），看加载与稳态内存（geo/规则是内存大头）。
4. **高吞吐尖峰**：连续测速 / 大文件下载 / 多连接并发——**这是最容易 OOM 的场景**，重点观测峰值是否顶穿 ~50MiB。
5. **WireGuard 出站**（若节点支持）：已知高内存场景，单独测。
6. **网络切换**：WiFi ↔ 蜂窝 反复切，看是否断连、能否自动恢复、内存是否泄漏。
7. **锁屏/休眠/唤醒**：锁屏挂机、隔一段唤醒，验证 `sleep()/wake()` 行为与重连。
8. **被杀恢复（on-demand）**：手动制造 OOM（跑场景 4 到被杀）或手动 kill extension，验证 on-demand 规则能否自动把隧道拉回来。
9. **长时间挂机**：开着 VPN 挂 12–24h+，看是否被 jetsam 累积杀掉、断连频率、功耗。

### D3. 验收标准（建议基线，可按结果调整）
- 稳态（场景 1/2）：NE 进程常驻内存 **稳定在 ~35–40MiB 以内**，无持续上涨（无泄漏）。
- 大配置（场景 3）：加载后稳态仍在预算内，否则需裁规则集/协议。
- 尖峰（场景 4/5）：**要么不顶穿 50MiB，要么 OOM 后 on-demand 能秒级自动恢复**且用户几乎无感。
- 长跑（场景 9）：24h 内被 jetsam 杀次数可接受（理想 0，或每次都能自动恢复），无崩溃。
- 网络切换（场景 6）：不泄漏、能恢复。

**结论产出**：一份《本内核在 iOS 50MiB 预算下的承载力报告》——能稳定支撑多大规模的节点/规则集、哪些场景是风险、要不要重编内核（裁协议/调内存参数）。这份报告决定项目是否值得继续投入产品化。

---

## 7. 排错预案（按发生阶段）

**阶段 A（内核）**
- gomobile 编译报 SDK/符号错误 → 换 sing-box stable tag 重编；或走 CI artifact 备选。
- `PATH` 找不到 gomobile → `export PATH=$PATH:$(go env GOPATH)/bin`。

**阶段 B（编译/签名）**
- 签名失败/Provisioning → 确认 Team 已选、App ID 与 App Group 已在后台注册、Automatic 能生成 profile。
- App Group 不匹配 → 主 App 和 Extension 必须勾同一个 group，且与代码里 `AppConfiguration` 一致。
- 某 SPM 包编译失败（大概率 Ghostty/编辑器）→ 移除该 product 依赖 + 删引用文件（B4）。
- iCloud 容器错误 → 删掉 entitlements 里 icloud/ubiquity 项。

**阶段 C（运行）**
- 连接后立刻断开 → 看 Console 的 extension 日志；常见是 configContent 无效 JSON、或 App Group 容器路径拿不到（FilePath 崩）。
- 起不来无日志 → 确认 extension 的 `NSExtensionPrincipalClass` 指向正确、entitlement 有 packet-tunnel-provider。
- 能连不能上网 → 检查 TUN fd 是否拿到（`ExtensionPlatformInterface.openTun0` 第 210 行那段）、route/DNS 设置、出站节点是否可用。

**阶段 D（内存）**
- 频繁被杀 → 缩小配置（少节点、rule-set 替代全量 geo）、限并发；仍不行则回阶段 A 重编内核调低内存参数/裁协议。

---

## 8. 决策点 & 可代劳部分

**需要你（在自己设备/账号上）做的**：Xcode 里选 Team、真机信任证书、系统 VPN 授权、Instruments 观测、场景跑测。

**我可以直接代劳的**（你确认后我就做）：
1. 阶段 A：clone sing-box + `make lib_install` + `make lib_apple`，把 Libbox.xcframework 编出来（会 `go install` gomobile 到你的 GOPATH，耗时约 30–60min，属环境改动，故先征得同意）。
2. 阶段 B 的标识符批量替换：把 `io.nekohasekai.sfavt` 换成你指定的前缀、删 iCloud entitlements、生成一份"改哪些行"的精确 diff。
3. 写一份阶段 D 的观测记录模板（表格）便于你逐场景填数。

**待你提供的输入**：
- 你想用的 bundle id 前缀（如 `com.randy.xxx`）。
- 测试节点/订阅来源（决定 C2 用哪个选项）。
