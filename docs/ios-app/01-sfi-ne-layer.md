# SFI（sing-box-for-apple）NE 层结构梳理与落地文档

> 目标：以 SFI 为起点，做一个 Clash 生态的 iOS 代理客户端（类 Stash）。
> 本文只聚焦 **NetworkExtension（NE）层**——即"内核如何跑进 iOS 隧道进程、如何拿到 TUN、如何和主 App 通信、如何控内存"。
> 源码位置：`/Users/user/Documents/develop/sing-box-for-apple`（GPL-3.0，commit 为 2026-07 clone 的 main）。
> 关联决策见记忆 `ios-clash-vpn-plan`：内核走 sing-box，Clash 订阅由本仓库 subconverter 转换。

---

## 0. 一句话结论

SFI 的 NE 层是**目前最权威的开源参考实现**，而且设计得高度可复用：真正与 sing-box 内核绑定的 Swift 代码只有 **`ExtensionProvider` + `ExtensionPlatformInterface` 两个文件（约 1100 行）**，其余都是 UI、数据库、远程管理等可裁剪的外围。内核本身是官方预编译的 `Libbox.xcframework`，我们不碰 Go 代码就能用。**最该吃透的就是这两个文件 + 启动时序 + TUN fd 获取 + 内存治理这四点。**

---

## 1. 三进程模型（先建立全局图）

iOS 上这类 app 天然是三个部分，进程边界决定了所有架构约束：

```
┌─────────────────────────────────────┐        ┌──────────────────────────────────────┐
│  主 App 进程 (SFI target)            │        │  NE 扩展进程 (Extension target)         │
│  - SwiftUI UI                        │        │  - 只有 4 行:                          │
│  - 订阅/配置管理 (Database/GRDB)     │  拉起   │    class PacketTunnelProvider          │
│  - ExtensionProfile (控制隧道生命周期)│──────▶ │        : ExtensionProvider {}          │
│  - CommandClient (拉状态/日志/流量)  │◀──────▶│  - ExtensionProvider (启动/停止/reload) │
│  内存宽裕，可用完整 URLSession/UI    │  IPC   │  - ExtensionPlatformInterface (TUN/网络)│
└─────────────────────────────────────┘        │  - 内嵌 Libbox → sing-box 内核          │
             │                                   │  ⚠️ 50MiB 内存硬上限，超限被 jetsam 杀 │
             │  共享                             └──────────────────────────────────────┘
             ▼                                                    ▲
      ┌──────────────────────────────┐                          │
      │  App Group 共享容器            │◀─────────────────────────┘
      │  group.<bundle-id>            │   两进程都挂载同一容器
      │  - settings.db (配置/偏好)    │
      │  - configs/ (最终 sing-box JSON)│
      │  - start_options.plist (快照) │
      └──────────────────────────────┘
```

要点：
- **主 App 随时可被系统杀掉，不影响隧道**；隧道活着的是 NE 进程。
- **两进程不共享内存，只共享 App Group 文件 + 通过 IPC 通信**。
- **Libbox 内核只存在于 NE 进程**（内存账本只算这个进程）。
- Flutter/SwiftUI 只能做主 App；**NE 进程必须原生 Swift/ObjC + xcframework**，Flutter 引擎进不去。

---

## 2. NE 层文件地图（哪些必须懂、哪些可删）

路径均相对 `sing-box-for-apple/`。⭐=核心必读，🔧=需按我们需求改，✂️=可裁剪。

| 文件 | 角色 | 处理建议 |
|---|---|---|
| `Extension/PacketTunnelProvider.swift` | ⭐ NE 入口，仅 4 行，继承 `ExtensionProvider` | 保留 |
| `Library/Network/ExtensionProvider.swift` | ⭐ NE 生命周期核心：`startTunnel`/`stopTunnel`/`sleep`/`wake`/`handleAppMessage`，Libbox 初始化与内存参数在此 | 精读，🔧改内存参数 |
| `Library/Network/ExtensionPlatformInterface.swift` | ⭐ Libbox 回调 Swift 的桥：配 `NEPacketTunnelNetworkSettings`、**取 TUN fd**、网络接口/WiFi 监控、系统代理、通知 | 精读，iOS 路径可删 macOS/JAILBREAK 分支 |
| `Library/Network/ExtensionProfile.swift` | ⭐ 主 App 侧隧道控制器：安装 `NETunnelProviderManager`、`start/stop/restart`、on-demand 规则、下发启动参数 | 精读，🔧 |
| `Library/Network/ExtensionStartOptions.swift` | 启动参数（含 configContent）plist 编解码，用于 IPC 与快照 | 保留 |
| `Library/Network/CommandClient.swift` | ⭐ 主 App 侧 IPC 客户端：订阅状态/日志/流量/分组/连接/Clash mode | 精读，UI 相关按需裁 |
| `Library/Network/CommandTarget.swift` | 本地 vs 远程 command 通道抽象（远程管理功能） | ✂️ 不做远程管理可删 |
| `Library/Network/OnDemandRule.swift` | on-demand 规则模型（被杀后自动复活的兜底） | 保留 |
| `Library/Network/OutboundGroup.swift` | 出站分组模型（≈ Clash 策略组，供切节点 UI） | 保留 |
| `Library/Network/ConnectionOwnerLookup.swift` | 按连接找进程（仅 macOS/越狱有用） | ✂️ |
| `Library/Network/*XPC*.swift`, `*Helper*.swift`, `SystemExtension.swift`, `RootHelper*`, `ShellHelper*`, `UserService*` | macOS System Extension / 越狱 helper / SSH server 等 | ✂️ 纯 iOS 全删 |
| `Library/Database/Database.swift` (GRDB) | 配置/偏好持久化（SQLite），建在 App Group | 保留，🔧表结构可简化 |
| `Library/Database/Profile*.swift`, `ProfileManager.swift` | 订阅/配置 profile 的增删改查、远程更新、iCloud | 保留核心，✂️ iCloud/分享可选 |
| `Library/Database/SharedPreferences.swift` | 所有开关型偏好（含 on-demand、includeAllNetworks 等） | 保留 |
| `Library/Shared/FilePath.swift` | ⭐ App Group 容器路径定义（basePath/working/cache） | 精读，决定内核工作目录 |
| `Library/Shared/AppConfiguration.swift` | bundle id / App Group id / 各种标识符集中定义 | 🔧 全部改成自己的 |
| `Library/Shared/Variant.swift` | 编译期变体开关（debug、useSystemExtension 等） | 保留 |
| `Library/Shared/OOMReport*`, `CrashReport*`, `NativeCrashReporter.swift` | OOM/崩溃上报（内存治理配套） | 保留（对调内存很有用） |
| `ApplicationLibrary/Service/*` | 订阅下载/更新任务、profile server | 保留核心 |
| `ApplicationLibrary/Views/*` | 全套 SwiftUI 界面 | ✂️ 自己重做产品 UI |
| `Frameworks/Runestone`, `TreeSitterJSON5` | 配置文本编辑器（高亮 JSON5） | ✂️ 可选 |
| `MacLibrary/`, `SFM*`, `SFT*`, `SystemExtension/`, `Jailbreak/`, `HelperService/` | macOS/tvOS/越狱专属 target | ✂️ 只做 iOS 可全删 |

**净结论**：想跑通一个 iOS MVP，NE 侧真正要读懂并改的是 5 个文件——`ExtensionProvider`、`ExtensionPlatformInterface`、`ExtensionProfile`、`FilePath`、`AppConfiguration`。

---

## 3. 启动时序（隧道是怎么起来的）

### 主 App 侧（`ExtensionProfile.swift`）
1. `ExtensionProfile.install()`：创建 `NETunnelProviderManager`，设 `providerBundleIdentifier` = NE 扩展的 bundle id，`saveToPreferences()`（首次会弹系统 VPN 授权）。
2. `start()`：
   - `prepareStartOptions()` 读取当前选中 profile 的**最终配置文本**（`configContent`，一段 sing-box JSON 字符串）打进 options 字典；同时塞入 systemProxy、includeAllNetworks、excludeDefaultRoute 等偏好。
   - 设置 on-demand / includeAllNetworks / excludeLocalNetworks 等 `protocolConfiguration`。
   - `manager.connection.startVPNTunnel(options:)` —— 把 options 传给 NE 进程。
3. 运行中改配置：`reloadService()` → `session.sendProviderMessage(data)`（走 `handleAppMessage`，热重载不断线）。
4. `stop()`：先 `LibboxNewStandaloneCommandClient().serviceClose()` 优雅停内核，再 `stopVPNTunnel()`。

### NE 进程侧（`ExtensionProvider.startTunnel`）
1. `resolveStartOptions()`：优先用主 App 传来的 options；缺失时回退读 App Group 里的 `start_options.plist` 快照（**on-demand 被系统自动拉起时主 App 没参与，就靠这个快照**）。
2. 组 `LibboxSetupOptions`：`basePath/workingPath/tempPath` 全部指向 App Group 容器；`logMaxLines=3000`；**`oomKillerEnabled = true`（iOS 恒为 true）**。
3. `LibboxSetup()` 初始化内核运行时 → `LibboxPromoteOOMDraft()`（OOM 上报草稿转正）。
4. `LibboxNewCommandServer(platformInterface, platformInterface)` 创建并 `start()` —— **IPC 服务端在 NE 进程内起来**。
5. `startService()` → `commandServer.startOrReloadService(configContent, options)` —— 把 JSON 配置喂给内核，内核开始工作，此时会回调 `platformInterface.openTun(...)`。
6. 打印 `"(packet-tunnel): Here I stand"` 表示成功。

**这条链路是整个 app 的心跳，fork 后第一件事就是让它在真机上跑通。**

---

## 4. 关键机制一：TUN fd 是怎么拿到的（最容易踩坑处）

iOS **不提供官方 API 拿 utun 文件描述符**，但 sing-box 内核（Go）需要一个 fd 去读写三层包。SFI 的做法在 `ExtensionPlatformInterface.openTun0()` 结尾（约 210–222 行）：

```swift
networkSettings = settings
try await tunnel.setTunnelNetworkSettings(settings)   // 必须先应用网络设置，utun 才建立

// 首选：从 packetFlow 的私有 KVC 路径掏 fd（社区通用 hack，非公开 API）
if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
    ret0_.pointee = tunFd
    return
}
// 兜底：libbox 自己遍历进程 fd 找 utun control socket
let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
if tunFdFromLoop != -1 { ret0_.pointee = tunFdFromLoop }
else { throw ...Missing file descriptor }
```

要点与风险：
- `packetFlow.value(forKeyPath: "socket.fileDescriptor")` 是**私有 KVC**，Apple 未文档化，历史上不同 iOS 版本可能失效——所以有 `LibboxGetTunnelFileDescriptor()` 兜底。**审核层面这是灰色地带，但 SFI/WireGuard 等长期这么用。**
- 拿到 fd 后，读写三层包、TCP/UDP 重组全在 **Go 内核里的用户态网络栈（gVisor）** 做，Swift 侧不碰数据面。这也是 `build_libbox` 带 `with_gvisor` tag 的原因（见第 8 节）。
- `openTun0` 前半段（40–207 行）是把 sing-box 给出的 TUN 参数（MTU、IPv4/6 地址与路由、DNS、HTTP 代理、include/exclude 路由）翻译成 `NEPacketTunnelNetworkSettings`。**这段是路由/分流在系统层生效的地方**，includeAllNetworks/excludeDefaultRoute 等高级特性都在这里落地。

---

## 5. 关键机制二：内存治理（第一工程约束）

iOS 给 Packet Tunnel 扩展 **50MiB 硬上限**（iOS 15+；iOS 14 及前是 15MiB），超限 jetsam 直接杀进程。SFI 的应对分两层：

**A. NE 进程强制开 OOM killer**（`ExtensionProvider.startTunnel`）：
```swift
#else  // 非 macOS，即 iOS/tvOS
    options.oomKillerEnabled = true   // 恒开
#endif
```
真正的内存预算与 GC 策略在 **Libbox 内核（Go）里**，即前期调研确认的 sing-box `libbox` 方案：总预算 ~45MiB、`debug.SetMemoryLimit` 把 Go 堆软限压到 ~30MiB、`SetGCPercent(10)`、conntrack 到阈值就"杀连接保进程"。**我们用官方 xcframework 就自动获得这套，不需自己写 Go。**

**B. iOS 专用低内存编译**（见第 8 节 build tag `with_low_memory`，只对非 macOS 生效）：内核内部用更省内存的数据结构/缓冲策略。

**C. 配套上报**：`OOMReportManager` / `LibboxPromoteOOMDraft()` / 断开时 `schedulePromoteOOMDraft()`——被 jetsam 杀后下次启动能捞到 OOM 证据。调优时非常有用。

**残余风险（必须实测）**：高吞吐尖峰（测速、WireGuard 出站的并发 buffer）仍可能顶穿 50MiB。这是我们 POC 阶段要压测的头号指标。

---

## 6. 关键机制三：跨进程 IPC（状态/日志/流量怎么回到 UI）

- **服务端**：NE 进程内 `LibboxNewCommandServer(...)`（`ExtensionProvider` 持有）。这是 libbox 自带的本地 socket 协议服务，跑在 App Group 容器里的 `command.sock`。
- **客户端**：主 App 的 `CommandClient.swift`，按需订阅 6 类连接：`status / groups / log / clashMode / connections / outbounds`。流量/日志有批处理（100ms 窗口）避免 SwiftUI 抖动。
- **一次性命令**：`LibboxNewStandaloneCommandClient()`（如 `serviceClose()`），无需常连。
- **配置热重载**：主 App `sendProviderMessage` → NE `handleAppMessage` → `reloadService()`，`reasserting=true` 期间不断流。
- **Clash 面板兼容**：libbox 编译带 `with_clash_api`，NE 进程内直接暴露 Clash 兼容的 external-controller，metacubexd/yacd 面板可直连（内存计入 NE 账本）。

**这正是"流量统计/日志跨进程"的成熟范式，我们照抄即可，不用自己设计 IPC。**

---

## 7. Entitlements / App Group / Bundle ID 结构（fork 必改）

从 `Extension/Extension.entitlements` 与 `project.pbxproj` 摸出的结构：

- NE 扩展关键 entitlement：
  ```xml
  <key>com.apple.developer.networking.networkextension</key>
  <array><string>packet-tunnel-provider</string></array>
  <key>com.apple.security.application-groups</key>
  <array><string>group.<你的bundle-id></string></array>
  <key>com.apple.developer.networking.wifi-info</key>   <!-- 读 WiFi SSID 分流用 -->
  ```
- Bundle id 约定：主 App = `<base>`，NE 扩展 = `<base>.extension`（`Info.plist` 里 `NSExtensionPointIdentifier = com.apple.networkextension.packet-tunnel`，`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).PacketTunnelProvider`）。
- App Group = `group.<base>`，两个 target 都要加，是共享容器的钥匙。
- `AppConfiguration.swift` 集中了所有这些标识符 —— **fork 后把 `io.nekohasekai.sfavt` 全局替换成自己的 bundle id 前缀**，并在 Apple Developer 后台建好 App ID + App Group + NetworkExtension capability。

**账号提醒**：付费个人开发者账号可自助勾选 NetworkExtension capability，真机自签/TestFlight 都能跑；但**正式上架 App Store 必须组织账号**（Guideline 5.4），这点在分发阶段再处理。

---

## 8. Libbox.xcframework 从哪来（内核构建）

SFI 仓库里直接放了预编译的 `Libbox.xcframework`（`project.pbxproj` 引用），但它由 **sing-box 主仓库**构建并拷贝过来。关键命令（sing-box 主仓库 Makefile）：

```makefile
lib_install:            # 装 sagernet fork 的 gomobile
	go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.13
	go install github.com/sagernet/gomobile/cmd/gobind@v0.1.13
lib_apple:              # 生成 Libbox.xcframework 并自动拷到 ../sing-box-for-apple/
	go run ./cmd/internal/build_libbox -target apple
```

编译 tag（`cmd/internal/build_libbox/main.go`）——决定内核能力与内存：
- 共享：`with_gvisor with_quic with_wireguard with_utls with_naive_outbound with_clash_api ...`（gVisor 用户态栈、QUIC、Clash API 都在这）
- **iOS/非 macOS 专属：`with_low_memory`**（第 5 节 B 项，省内存关键）
- darwin：`with_dhcp grpcnotrace`

含义：**要自己控制内核能力（比如裁剪协议省内存、或加协议），就 fork sing-box 主仓库改这里重编 xcframework**；只想用现成的，直接用 SFI 里带的即可。我们前期用现成的，POC 通过后再考虑自编。

---

## 9. 与本仓库 subconverter 的衔接点（我们的独特优势）

SFI 的世界观是"内核只吃一份完整的 sing-box JSON"（`configContent`）。而用户手里是 **Clash 订阅（YAML）**。这中间的转换正是 subconverter 的主场：

```
机场 Clash 订阅 (YAML)
    │
    ▼  subconverter： target=singbox 的输出（本仓库需新增/复用的转换目标）
sing-box JSON
    │
    ▼  写入 App Group: configs/config_xxx.json （对应 SFI 的 Profile.path）
主 App 选中该 profile → ExtensionProfile.start() 读成 configContent → 喂给内核
```

落地选项（后续单独文档细化）：
- **A. 客户端内嵌转换**：把 subconverter 的转换能力编进 app（C++ 引擎交叉编译，或用其现有 HTTP engine 思路）。参考本仓库 mac-app 已有的"engine 拉取 → 本地组装"经验。
- **B. 服务端转换**：复用现成 subconverter HTTP 服务，app 只发订阅 URL 拿回 sing-box JSON。最快但依赖服务端。
- sing-box 官方支持 clash 订阅需转换，社区已有大量 clash→sing-box 转换实现可对照正确性。

---

## 10. 可执行落地清单（POC → MVP）

### 阶段 0：环境与跑通（最高优先，验证最大风险）
- [ ] 用付费个人开发者账号，在 Apple Developer 建：App ID `<base>`、`<base>.extension`、App Group `group.<base>`，两者都开 NetworkExtension capability。
- [ ] fork SFI，全局替换 bundle id 前缀（`io.nekohasekai.sfavt` → 自己的），改 `AppConfiguration.swift`。
- [ ] 删除 macOS/tvOS/越狱/SystemExtension/XPC/RootHelper/ShellHelper 相关 target 与文件（第 2 节 ✂️ 项），只留 iOS。
- [ ] 用 SFI 自带的 `Libbox.xcframework` 直接编译 SFI target，**真机**跑通（模拟器不支持 NE）。
- [ ] 手动塞一份典型 sing-box JSON（几百节点 + 常用规则集）作为 profile，连上，能上网。

### 阶段 1：内存压测（决定项目成败）
- [ ] Xcode Memory Gauge + Instruments 观测 NE 进程内存：空载 / 稳态浏览 / 大规则集加载 / 测速尖峰 / WireGuard 出站。
- [ ] 复现 OOM，验证 `OOMReportManager` 能捞到证据；确认 `with_low_memory` + oomKiller 生效。
- [ ] 若尖峰顶穿 50MiB：限并发/限 buffer/裁协议（回到第 8 节重编 xcframework）。
- [ ] 结论文档化：本内核在本预算下能稳定承载多大规模的节点/规则。

### 阶段 2：接入 subconverter 转换层
- [ ] 决定 A（内嵌）还是 B（服务端）转换（另开文档评估）。
- [ ] 打通"Clash 订阅 URL → sing-box JSON → 写入 App Group profile → 启动"。
- [ ] 用本仓库现有 mac-app 的策略组/规则组装经验，校验转换正确性（分流是否符合预期）。

### 阶段 3：产品化
- [ ] 用 SwiftUI 重做 Stash 风格 UI（复用本仓库 mac-app SwiftUI 经验），保留 SFI 的 `CommandClient`/`ExtensionProfile`/`OutboundGroup` 数据层。
- [ ] on-demand 兜底、订阅自动更新、节点测速与切换、Clash 面板集成。
- [ ] 分发决策：TestFlight（个人账号灰区可行）/ 组织账号上架 / 自用自签。

---

## 11. 已确认的坑与注意事项（避免重复踩）

- **模拟器不能跑 NE**，只能真机；调试麻烦，早买真机。
- **TUN fd 靠私有 KVC**，换 iOS 大版本要回归测试第 4 节那段。
- **`includeAllNetworks` 是深坑**（Mullvad 有专文）：开启后 NE 进程发流量异常、App Store 更新时全断网、与 HotspotHelper 冲突。做"防泄漏"前要充分评估，默认别开。
- **GPL-3.0 传染**：SFI 是 GPL-3.0，fork 出的整个 app 需同以 GPL 开源（Hiddify/Karing 模式）。想闭源商业化需换 MPL 内核（Xray），但那就不是 sing-box/Clash 生态了。
- **上架需组织账号**，个人账号只能自签/TestFlight——这是分发而非技术阻塞，POC 阶段不受影响。
- ⚠️ **中国大陆开发者的法律风险**（已在可行性阶段记录）：制作/分发翻墙工具有刑事判例，收费+规模化显著加重。建议按"自用+开源"定位推进。

---

## 附：本文引用的源码位置速查

| 关注点 | 文件:大致行 |
|---|---|
| NE 入口 | `Extension/PacketTunnelProvider.swift:1` |
| 启动/停止/内存参数 | `Library/Network/ExtensionProvider.swift:101`(startTunnel) `:170`(oomKiller) |
| 取 TUN fd | `Library/Network/ExtensionPlatformInterface.swift:210` |
| 网络设置/路由翻译 | `Library/Network/ExtensionPlatformInterface.swift:42-207` |
| 主 App 控隧道 | `Library/Network/ExtensionProfile.swift:158`(start) `:324`(install) |
| 启动参数打包 | `Library/Network/ExtensionProfile.swift:227`(prepareStartOptions) |
| IPC 客户端 | `Library/Network/CommandClient.swift` |
| App Group 路径 | `Library/Shared/FilePath.swift` |
| 标识符集中定义 | `Library/Shared/AppConfiguration.swift` |
| entitlements | `Extension/Extension.entitlements`, `SFI/SFI.entitlements` |
| 内核构建 | sing-box 主仓库 `Makefile: lib_apple` / `cmd/internal/build_libbox/main.go` |
