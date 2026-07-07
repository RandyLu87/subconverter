# 自研 iOS Clash 代理客户端 —— 定制学习路径

> 读者：Randy，资深 iOS / Flutter 工程师。
> 目标：从"能跑通 SFI"进阶到"能改造"，最终"能自己实现一套 Clash 生态 iOS 代理客户端"。
> 本文只讲**你还缺的部分**——Swift/SwiftUI、Xcode、签名、Flutter、app 架构这些你已经会的不再赘述。
> 每个知识点都锚定到本项目的真实代码（`sing-box-for-apple/`）和我们踩过的坑。

---

## 0. 先建立全局：一个网页请求在这套系统里的完整旅程

学任何模块前，先把这条数据流刻进脑子里——后面所有知识点都是这条链路上的某一环。

```
Safari 要打开 google.com
   │
   ① app 发出 DNS 查询 + TCP SYN，目标是"公网"
   │
   ▼ iOS 路由表把流量导向 utun 虚拟网卡（因为 VPN 的 auto_route 声明了 0.0.0.0/0）
   │
   ② NEPacketTunnelProvider 从 utun 读到**原始 IP 包**（三层，L3）
   │
   ▼ 交给内核（sing-box，跑在 NE 扩展进程里）
   │
   ③ 用户态网络栈（gVisor）把 IP 包重组成 TCP 流 / DNS 查询（L3→L4）
   │
   ④ DNS：查询被 hijack，按 dns 配置解析（fakeip / DoH / 投毒就发生在这一步）
   │
   ⑤ 路由引擎：按 route.rules 决定这条连接走哪个 outbound（proxy / direct）
   │
   ⑥ 代理协议：trojan/vless/... 把流量加密封装，经 TLS 发给你的机场服务器
   │
   ▼ 出 utun → 经真实网卡（蜂窝/WiFi）→ 机场服务器 → 真正的 google
   │
   ⑦ 回程数据原路返回，gVisor 再打包成 IP 包写回 utun，Safari 收到响应
```

**我们这一路踩的每个坑，都能定位到这条链路上的某一环：**
- "连上打不开网络" → ④ DNS 被 hijack 却没配解析（缺 dns 块）
- "只有 DNS 进隧道、TCP=0" → ② 流量没被路由进 utun（网络状态/坏配置）
- "google 解析错" → ④ 加密 DNS 没生效，走了明文被投毒
- "内核编译" → ③⑤⑥ 都在那个 Go 内核里，要 gomobile 编成 xcframework

---

## 1. 你已有的 vs 需要补的（gap 分析）

| 领域 | 你的现状（iOS/Flutter） | 需要补到 |
|---|---|---|
| Swift / SwiftUI / Xcode / 签名 | ✅ 熟练 | — |
| app 生命周期、IPC 概念 | ✅ 熟 | NE 的进程模型是特例，要专门理解 |
| HTTP / URLSession | ✅ 会用 | 但这是 L7；你缺 **L3/L4（IP 包、TCP 握手、UDP、NAT）** |
| 网络底层 | ⚠️ 大概率不深 | **重点补**：TCP/IP 栈、路由表、DNS 协议 |
| 代理协议（SS/trojan/vless/hysteria） | ❌ 基本空白 | **重点补**：原理 + 抗审查 |
| NetworkExtension / Packet Tunnel | ❌ 没做过 | **重点补**：这是 app 的心脏 |
| TUN / 用户态网络栈 | ❌ 空白 | **重点补**：数据面 |
| Go 语言 + gomobile / cgo | ❌ 空白（除非你碰过） | **必补**：内核是 Go 写的 |
| DNS 深入（fakeip/DoH/投毒） | ⚠️ 只懂基础解析 | **重点补**：抗污染是刚需 |
| 内核架构（sing-box/mihomo） | ❌ 空白 | 按目标层级补 |
| 内存/性能 profiling | ⚠️ iOS 侧会，Go 侧不会 | 补 Go GC + NE 50MB 约束 |

**一句话**：你缺的是"网络栈底层 + 代理/抗审查 + NetworkExtension + Go 内核"这四大块。SwiftUI 那层你反而是优势。

---

## 2. 分层学习路径（每层：为什么 / 学什么 / 深度 / 项目锚点 / 资源 / 自测）

深度用三档：🟢了解（能看懂、会配）/ 🟡熟悉（能改、能调试）/ 🔴精通（能自研、能实现）。

---

### 模块 A：网络底层（TCP/IP 栈）—— 一切的地基

**为什么**：这套系统本质是在"搬运和改写 IP 包"。不懂 L3/L4，NE、TUN、网络栈全都看不懂。

**学什么**
- IP 包结构（IPv4/IPv6 头、地址、协议字段）、分片、MTU
- TCP：三次握手、四次挥手、序列号、滑动窗口、状态机
- UDP 与 QUIC（为什么 QUIC 难处理）
- 路由表、默认路由、NAT（尤其 full-cone，代理要模拟它）
- 抓包分析：Wireshark / tcpdump

**深度**：🟡熟悉（能看懂包、能推理"流量为什么没到"）。不用会手写 TCP 栈。

**项目锚点**
- `ExtensionPlatformInterface.openTun0()` 里那段把路由/地址翻译成 `NEIPv4Route`/`NEIPv6Route` —— 就是在操作路由表。
- 我们排查"TCP 没进隧道"，本质是在判断 IP 包有没有被路由进 utun。

**资源**：《TCP/IP 详解 卷1》(选读握手/状态机章节)、Wireshark 官方教程、`beej's guide to network programming`(socket 编程)。

**自测**：能用 Wireshark 抓一次 TCP 握手并解释每个包；能说清 MTU 设太大/太小分别会怎样。

---

### 模块 B：iOS NetworkExtension / Packet Tunnel —— app 的心脏

**为什么**：这是整个 app 唯一"特殊"的地方，也是 iOS 代理客户端的立身之本。你 iOS 底子好，这块能学得快，但概念要重建。

**学什么**
- `NEPacketTunnelProvider` 生命周期：`startTunnel` / `stopTunnel` / `sleep` / `wake`
- `NEPacketTunnelNetworkSettings`：地址、路由(included/excluded)、DNS、MTU、proxy settings
- `NEPacketTunnelFlow`：`readPackets` / `writePackets`（消息式，不是 fd）
- **拿 TUN fd 的私有 hack**（`packetFlow.value(forKeyPath:"socket.fileDescriptor")`）——为什么要这么干
- 主 app ↔ 扩展 IPC：`NETunnelProviderManager` / `sendProviderMessage` / App Group
- **50MiB 内存硬限制**（jetsam）、entitlement、`includeAllNetworks` 的坑、on-demand
- 为什么模拟器跑不了 NE

**深度**：🔴精通（这是你的核心竞争力，必须能从零写一个 provider）。

**项目锚点**（全在 `sing-box-for-apple/`）
- `Extension/PacketTunnelProvider.swift`（4 行入口）
- `Library/Network/ExtensionProvider.swift`（生命周期 + 内核初始化）
- `Library/Network/ExtensionPlatformInterface.swift`（TUN/网络设置/取 fd）
- `Library/Network/ExtensionProfile.swift`（主 app 侧控制）
- 我们改的那堆 entitlements、App Group、Team ID —— 就是这块的工程配置。
- 详见本目录 `01-sfi-ne-layer.md`（已把这层拆解过）。

**资源**：Apple 官方 `NetworkExtension` 文档、WWDC "NetworkExtension" 相关 session、Apple 开发者论坛 Quinn 的帖子（内存限制那篇，`developer.apple.com/forums/thread/73148`）、raywenderlich 的 Personal VPN 教程。

**自测（动手里程碑，见 §4-M2）**：不依赖 sing-box，自己写一个最小 PacketTunnelProvider，`readPackets` 后打印每个 IP 包的源/目的地址。能做到就说明你真懂这层了。

---

### 模块 C：TUN 与用户态网络栈 —— 数据面

**为什么**：NE 给你的是原始 IP 包，你得把它变成"能发给代理服务器的 TCP/UDP 流"。这就是 tun2socks / 用户态栈干的事。

**学什么**
- TUN 设备原理（L3 虚拟网卡）
- **tun2socks** 的概念：把 tun 的 IP 包转成 socks 连接
- **用户态 TCP/IP 栈**：为什么需要（iOS 不给你内核栈）
  - gVisor netstack（sing-box 的 `stack: gvisor`）
  - system stack（sing-box 自实现的轻量栈）
  - 各自权衡（正确性 vs 性能 vs 内存）
- **fakeip** 原理（我们最后没搞完的那个）：为什么它能绕过 DNS 投毒——不做真实解析、靠 sniff 从 SNI 恢复域名
- sniff（协议嗅探）：从 TLS ClientHello 取 SNI、从 HTTP 取 Host

**深度**：🟡熟悉（能配、能调、能读懂 gVisor 集成）；若要自研内核则 🔴。

**项目锚点**
- 配置里的 `"stack": "gvisor"`、`route.rules` 里的 `{"action":"sniff"}`
- 我们最后写的 fakeip 配置（`nest-test-config.json`）
- `ExtensionPlatformInterface.openTun0` 结尾拿 fd 后交给 libbox 的 gVisor 栈

**资源**：`xjasonlyu/tun2socks`（读它 README + 架构，最好的入门）、gVisor netstack 文档、`eycorsican/leaf`（Rust 版 tun2socks，代码清晰）、sing-box 的 tun inbound 文档。

**自测（里程碑 M3）**：能解释清楚"为什么 fakeip 能打开 google 而普通 DNS 被投毒"，并能画出 fakeip 下一个连接的完整时序。

---

### 模块 D：Go 语言 + gomobile / cgo —— 跨语言内核桥

**为什么**：mihomo、sing-box 内核都是 **Go** 写的。你要改内核、调内存、加协议，绕不开 Go。而且它通过 gomobile 编成 `xcframework` 才能被 Swift 调用——这个跨语言边界是关键工程点。

**学什么**
- Go 基础：语法、`goroutine` / `channel`（内核大量并发）、`interface`、错误处理
- Go 内存模型与 **GC 调优**：`GOGC`、`debug.SetGCPercent`、`debug.SetMemoryLimit`、`FreeOSMemory`（这些正是 NE 50MB 生存的关键）
- **gomobile / gobind**：Go 如何暴露给 Swift/ObjC，类型如何映射（我们跑的 `make lib_apple` 就是这个）
- cgo 基础（内核里有 C 交互）
- build tags（我们编译带的 `with_gvisor`/`with_quic`/`with_low_memory` 等）—— 如何裁剪功能/省内存

**深度**：🟡熟悉（能改内核、调 GC、加删 build tag、重编 xcframework）；自研内核则 🔴。

**项目锚点**
- 我们编 `Libbox.xcframework` 的整个过程（`sing-box` 主仓库 `make lib_install` + `make lib_apple`）
- `cmd/internal/build_libbox/main.go` 里的 build tags
- sing-box `experimental/libbox/` 里的内存治理代码（`SetMemoryLimit`/`GCPercent`/conntrack killer）

**资源**：官方 `A Tour of Go`（快速过语法）、`Effective Go`、gomobile wiki、sing-box 的 `experimental/libbox` 源码（最好的实战教材）、Dave Cheney 的 Go GC 博客。

**自测（里程碑 M4）**：用 gomobile 把一个你自己写的 Go 函数（比如 `func Add(a,b int) int`）编成 xcframework，在 Swift 里调用成功。跨过这个边界，你就掌握了内核集成的钥匙。

---

### 模块 E：代理协议与抗审查 —— 领域核心知识

**为什么**：这是"代理软件"区别于普通 VPN 的灵魂。不懂协议，你只是在搬运别人的内核。

**学什么**
- 代理协议家族与演进逻辑（**理解"为什么会有下一代"比记参数重要**）：
  - Shadowsocks / SSR（对称加密，最早）
  - VMess（v2ray，带时间戳认证）
  - **Trojan**（伪装成正常 HTTPS，我们测试用的就是它）
  - **VLESS + XTLS/Vision**（去掉多余加密，性能好）
  - **REALITY**（不需要自己的证书，偷用真实网站证书，当前抗封锁主力）
  - Hysteria2 / TUIC（基于 QUIC/UDP，抗丢包）
  - AnyTLS（你们 subconverter 仓库还专门加了解析）
- 传输层伪装：TLS、WebSocket、gRPC、HTTP/2
- **抗审查（GFW 对抗）**——这是理解一切设计的钥匙：
  - DNS 投毒（我们亲眼见了 google 被投毒）
  - SNI 阻断、TLS 指纹识别 → **uTLS**（模拟浏览器指纹）
  - 主动探测（active probing）→ 为什么 trojan/REALITY 要"看起来像真网站"
  - 流量特征分析

**深度**：🟡熟悉（能说清每个协议解决什么问题、怎么选）；实现协议则 🔴。

**项目锚点**
- 测试节点是 trojan（`nest-test-config.json` 的 outbound）
- `subconfig-clash_26_07_01.yaml` 里的 ss/ssr/trojan 各种节点
- 你们 subconverter 支持的协议解析

**资源**：v2ray/xray 官方文档（协议演进讲得好）、sing-box 各 outbound 文档、`net4people/bbs`（GitHub，抗审查研究的第一现场）、REALITY 的设计说明。

**自测**：能对着一个机场订阅，说出每种节点用什么协议、为什么这么设计、在什么网络环境下更抗封。

---

### 模块 F：DNS 深入 —— 我们栽跟头的地方

**为什么**：代理软件里 DNS 是重灾区（我们花了好几轮在这）。分流准不准、会不会被投毒、能不能打开 google，全看 DNS。

**学什么**
- DNS 协议：A/AAAA/CNAME/HTTPS record、递归 vs 权威、TTL
- 加密 DNS：DoT（853）、DoH（443）、DoQ —— 以及**为什么它们能防投毒**
- **fakeip**（重点，我们最后的方案）：原理、优劣、sniff 依赖
- DNS 分流：国内域名走国内 DNS、国外走加密 DNS（我们配的 `.cn → dns-direct`）
- DNS 泄漏、DNS 与路由的先后关系
- 投毒识别（我们对比 Mac 出口 DoH=正确 IP vs iOS=投毒 IP 的诊断方法）

**深度**：🟡熟悉（能设计一套不泄漏、不被投毒、分流正确的 DNS 配置并调试）。

**项目锚点**
- `nest-test-config.json` 的整个 `dns` 段演进（无 dns → DoT → fakeip）
- 我们用 `curl -x socks5h ... https://1.1.1.1/dns-query` 验证出口解析的诊断手法
- 遗留问题：为什么 iOS 端 DoT-via-proxy 没生效（值得你深挖，是很好的学习题）

**资源**：sing-box DNS 文档（新版 DNS 引擎，务必看你编的版本对应的文档）、Cloudflare 的 DoH/DoT 科普、mihomo 的 fakeip 文档。

**自测**：能解释我们整个 DNS 排查链路的每一步；能独立配出一套 fakeip + 国内外分流的 DNS 并验证 google 能开、国内网站不绕路。

---

### 模块 G：路由 / 规则引擎

**为什么**：Clash 生态的核心卖点就是"规则分流"（哪些走代理、哪些直连、哪些拦截）。

**学什么**
- 规则类型：domain / domain-suffix / domain-keyword / ip-cidr / geoip / geosite / process
- rule-set（二进制规则集，`.srs`）—— 为什么比全量 geo 库省内存（NE 场景关键）
- 策略组（proxy-group）：select / url-test / fallback / load-balance
- 规则匹配顺序、final 兜底
- sing-box route rule 的 action 模型（sniff / hijack-dns / route）

**深度**：🟢了解→🟡熟悉（能设计分流策略）。你们 subconverter 就是干配置转换的，这块和你现有项目最近。

**项目锚点**
- `subconfig-clash_26_07_01.yaml` 的 `proxy-groups` 和 `rules` 段（一个真实机场配置的完整分流）
- `nest-test-config.json` 的 `route.rules`
- 你们 subconverter 的规则处理逻辑（`src/subconverter/`）

**资源**：Clash / mihomo 配置文档、sing-box route 文档、你自己仓库的 subconverter 代码。

---

### 模块 H：内存与性能（NE 50MB 约束）—— 决定成败的工程

**为什么**：这是我们最初可行性评估里认定的**头号技术挑战**，也是 Stash 自研内核的原因。跑通不难，稳定不崩才是真本事。

**学什么**
- iOS jetsam 机制、Packet Tunnel 的 50MiB 限制、如何观测（Xcode Memory Gauge attach 扩展、Instruments、Console 抓 jetsam）
- Go 侧内存治理：`SetMemoryLimit` / `GOGC` / conntrack OOM killer（sing-box 现成方案）
- 高吞吐尖峰问题（测速、大文件、WireGuard 出站）—— 残余风险
- rule-set 替代全量 geo 库省内存
- mmap 大文件不计脏内存（Quinn 的建议）

**深度**：🔴精通（这是自研的核心壁垒）。

**项目锚点**
- 这就是本项目 `02-stability-poc-plan.md` 阶段 D 要做的事
- `ExtensionProvider.startTunnel` 里 `oomKillerEnabled = true`
- sing-box `experimental/libbox/memory.go`（照抄的对象）

**资源**：Quinn 的内存帖、sing-box libbox 内存源码、Instruments 文档。

---

### 模块 I：TLS / 加密（横向支撑）

**为什么**：现代代理协议全部基于 TLS 伪装，抗审查靠 TLS 指纹。

**学什么**：TLS 1.3 握手、SNI、ECH、证书验证（我们配的 `insecure: true` / `skip-cert-verify` 是什么含义、有什么风险）、uTLS 指纹模拟、REALITY 的证书借用原理。

**深度**：🟢了解→🟡熟悉。

**项目锚点**：测试节点的 `tls: { server_name, insecure }`；模块 E 的 REALITY/uTLS。

---

## 3. 按目标分级的学习顺序（别一次全学）

你的目标是渐进的，学习也应该分三级，每级有明确产出。

### L1 —— "会用 + 会配 + 会改 UI"（1–2 周）
够你把 SFI 变成一个自己能维护、能改界面的 app。
- 必学：**B(NE 基础)** + **E(协议概念)** + **F(DNS 基础+fakeip)** + **G(规则)**
- 可跳过：Go、网络栈底层、内存深水区
- 产出：能改 SFI 的 SwiftUI 界面、能手写/调试任意 sing-box 配置、能讲清一个请求的完整链路。

### L2 —— "会改造内核集成 + 接订阅转换 + 控内存"（1–2 月）
够你做出一个差异化的产品（比如深度整合你们 subconverter）。
- 必学：**A(网络栈)** + **C(TUN/网络栈)** + **D(Go+gomobile)** + **H(内存)**
- 产出：能重编 xcframework 裁剪功能、能加 build tag、能调 GC 扛住内存压测、能把 Clash 订阅转 sing-box 集成进 app。

### L3 —— "能自研内核 / 完整实现"（3–6 月+）
够你摆脱对 sing-box 的依赖，甚至走 Stash 那种自研路线。
- 必学：全部模块的 🔴 深度，尤其 **E(实现协议)** + **C(自研网络栈)** + **A(精通)**
- 产出：能从零实现一个最小可用的代理内核（tun → 栈 → 一个协议出站 → DNS），哪怕只支持 trojan 一个协议。

---

## 4. 动手里程碑（学以致用，验证你真的掌握了）

**光看不做等于没学。** 每个里程碑都是一个能独立完成的小项目，从易到难，对应上面的模块。

- **M1（对应 F/G）**：手写一份复杂 sing-box 配置——多出站 + 国内外分流 + fakeip + rule-set，用 `sing-box check` 校验并在真机跑通。→ 证明你懂配置/DNS/路由。
- **M2（对应 B）**：从零写一个最小 `NEPacketTunnelProvider`，不集成任何内核，`readPackets` 后打印每个 IP 包的源/目的 IP 和协议号。→ 证明你懂 NE 数据面。**这是分水岭，做出来就入门了。**
- **M3（对应 C）**：在 M2 基础上，接一个现成的 gVisor tun2socks 库，把 tun 流量转发到一个本地 socks5（比如你 Mac 上跑的 sing-box socks 口）。→ 证明你懂用户态栈。
- **M4（对应 D）**：用 gomobile 把一个自己写的 Go 函数编成 xcframework 并在 Swift 调用成功；再进一步，改 sing-box 的 build tag 重编、裁掉一个协议。→ 证明你掌握了内核集成的钥匙。
- **M5（对应 D/H）**：给你的 provider 加上 sing-box libbox，跑内存压测（阶段 D），复现并解决一次 OOM。→ 证明你能做产品级的稳定性。
- **M6（对应 E，L3 级）**：读懂 sing-box 的 trojan outbound 实现，然后自己用 Go 从零实现一个最小 trojan 客户端（TCP + TLS + trojan 协议头）。→ 证明你能碰内核最核心的部分。

做完 M1–M4，你就能独立驾驭这套系统；做完 M5–M6，你就具备自研能力。

---

## 5. 资源清单（精选，别贪多）

**代码（最好的老师）**
- `sing-box-for-apple/`（本机已 clone）—— NE 层 + Swift 集成的范本，配合 `01-sfi-ne-layer.md` 读
- `sing-box`（本机已 clone）—— 内核，重点看 `experimental/libbox/`（内存/IPC）、`protocol/`（协议实现）
- `xjasonlyu/tun2socks`、`eycorsican/leaf`（Rust，代码清晰）—— 网络栈入门
- `MetaCubeX/mihomo`、`MetaCubeX/ClashMetaForAndroid`—— Clash 内核与 Android 集成对照

**文档**
- Apple `NetworkExtension` 官方文档 + Quinn 在开发者论坛的帖子（内存/TUN fd）
- sing-box 官方文档（**认准你编译的版本**，新版 DNS/route 变化大）
- v2ray/xray 文档（协议演进）、REALITY 设计说明
- `net4people/bbs`（抗审查研究第一现场）

**书/教程**
- 《TCP/IP 详解 卷1》（选读）
- `A Tour of Go` + `Effective Go`
- Wireshark 官方教程

**社区**
- sing-box / mihomo 的 GitHub Discussions 和 Telegram
- `net4people/bbs`

---

## 6. 给你的最短路径建议

以你的背景，我建议这个顺序，能最快形成战斗力：

1. **先用你已会的 SwiftUI 改 SFI 界面**（把它变成"你的" app）——建立掌控感，顺便熟悉 B 的 IPC 部分（`CommandClient`）。
2. **主攻模块 B（NE）+ 做 M2**——这是你和普通 app 开发者拉开差距的地方，也最吃你的 iOS 底子。
3. **补模块 A/C（网络栈）**——M2 做完你自然就想懂包是怎么流动的。
4. **啃模块 D（Go + gomobile）+ M4**——跨过语言边界，你就能碰内核了。
5. **协议/DNS/抗审查（E/F）穿插着学**——这些是"领域知识"，边用边补，配合你们 subconverter 项目最省力。
6. **内存（H）留到最后攻坚**——等你能自如集成内核了再啃这块硬骨头。

Flutter 那边：如果将来想做跨平台 UI（像 Hiddify/FlClash 那样 Flutter 壳 + 原生 NE），你的 Flutter 优势能发挥——但**记住 NE 扩展永远是原生的，Flutter 只能做主 app UI**。这条边界不会变。

---

*本文是活文档，随着你深入可以往里补自己的笔记。配套阅读：`01-sfi-ne-layer.md`（NE 层拆解）、`02-stability-poc-plan.md`（稳定性验证计划）。*
