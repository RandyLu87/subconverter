# 阶段 D：NE 扩展内存压测 —— 执行手册

> 目标：验证 sing-box 内核在 iOS Packet Tunnel 扩展的 **50MiB 内存硬上限**下稳不稳、会不会被 jetsam 杀。
> 这是整个 POC 的**核心目标**——跑通只是前提，稳定不崩才是真本事。
> 关联：`02-stability-poc-plan.md` 阶段 D（本手册是它的可操作展开）。

---

## 0. 先理解你在测什么

- iOS 给 Packet Tunnel 扩展进程的内存上限约 **50MiB**（iOS 15+），超了被 **jetsam** 直接杀掉，表现为 VPN 突然断线。
- 内存全部消耗在 **NE 扩展进程**（sing-box 内核跑在这里），**不是主 app**。所以观测对象是扩展进程。
- 两个关键指标：
  1. **稳态内存**：正常使用时常驻多少（理想 ≤ 35-40MiB，留余量）
  2. **峰值内存**：高吞吐（测速/大下载）时冲到多高，会不会撞 50MiB

---

## 1. 关键准备：怎么看到"扩展进程"的内存

这是最容易卡住的一步——Xcode 默认显示的是**主 app** 进程，你要的是**扩展**进程。

### 方法 A：Xcode Attach to Process（推荐，最简单）
1. Xcode 里正常 Run 主 app（`SFI` scheme）到真机。
2. **在手机上连接 VPN**——扩展进程只有在 VPN 连接时才存在，没连就 attach 不到。
3. Xcode 菜单 **Debug → Attach to Process**，在列表里找扩展进程。名字通常包含 **`Extension`** 或你的 bundle id 尾部（`com.magicowl.nest.extension`）。
4. attach 成功后，打开 **Debug Navigator（⌘7）**，顶部会显示该进程的 **Memory** 实时曲线和数值。
5. 盯着这条 Memory 曲线做下面的场景。

> ⚠️ **Debug build 内存偏高**：你 Run 的是 Debug 版，内存会比 Release 高一些。**趋势和相对变化是准的**（会不会持续涨、峰值多高），绝对数值以 Release 为准。想要真实数值，可以对 extension 单独出一个 Release build 再 attach。本阶段先用 Debug 看趋势即可。

### 方法 B：Instruments（看更细，可选）
Xcode → Open Developer Tool → Instruments → Allocations（或 Activity Monitor），target 选那个扩展进程。能看分配明细和泄漏。

---

## 2. 关键准备：怎么抓"被 jetsam 杀"的铁证

如果内存撞顶被杀，VPN 会突然断。要确认是不是 OOM 杀的（而不是别的原因），有三个证据源：

### 证据 A：手机本地的 JetsamEvent 报告（最权威）
手机 **设置 → 隐私与安全性 → 分析与改进 → 分析数据**，列表里找 **`JetsamEvent-<日期>.ips`** 文件。里面记录了哪个进程因为 `per-process-limit` 被杀、当时占了多少内存。**这是 OOM 被杀的铁证。**（如果找到，把内容发我，能看到确切的内存上限和你的进程占用。）

### 证据 B：Console.app 实时抓
Mac 打开 Console.app → 左侧选你的 iPhone → 搜索框输 `jetsam` 或 `memorystatus` 或 你的扩展进程名 → 开始。被杀会实时刷出来。

### 证据 C：SFI 内置的 OOM 上报
SFI 有 `OOMReportManager`（`Library/Shared/OOMReportManager.swift`），扩展被杀后下次启动会捞到 OOM 记录。app 里若有崩溃/OOM 报告入口能看到。

---

## 3. 压测场景（逐个做，填§5 的表）

每个场景：attach 到扩展进程 → 盯 Memory 曲线 → 记录基线/峰值/是否断线。

### S1. 空载基线（2-5 分钟）
连上 VPN，**什么都不干**，让手机静置。记录扩展进程的**稳态内存**。这是地板值。
- 关注：内存是否稳定，还是缓慢持续上涨（上涨=泄漏）。

### S2. 日常浏览（5-10 分钟）
正常刷网页、切几个 app、看看图文。记录浏览时的**波动范围**。
- 关注：回到空闲后内存能不能降回去（降不回=泄漏）。

### S3. 高吞吐尖峰（重点！最容易 OOM）
这是最可能撞 50MiB 的场景：
- 用手机浏览器跑一次测速：`https://fast.com` 或 `https://speedtest.net`
- 或下载一个大文件（几百 MB）
- **紧盯 Memory 曲线的峰值**——大量并发连接 + 缓冲区会让内存瞬间飙高。
- 关注：峰值冲到多少？有没有撞 50MiB 附近被杀（VPN 突然断）？

### S4. 网络切换（3-5 分钟）
连着 VPN，WiFi ↔ 4G 来回切几次（关开 WiFi）。
- 关注：切换后内存有没有异常累积；连接能不能自动恢复。

### S5. 长时间挂机（几小时~一夜）
连着 VPN 正常用手机、然后放着过夜。
- 关注：第二天还连着吗？中途断过几次？看 §2 的 JetsamEvent 有没有累积。

---

## 4. 判读标准与应对

| 结果 | 判读 | 应对 |
|---|---|---|
| 稳态 ≤ 40MiB，峰值不撞 50MiB，长挂不断 | ✅ 通过，内核在 iOS 约束下够稳 | 进入产品化 |
| 稳态 OK 但**测速峰值撞顶被杀** | ⚠️ 高吞吐残余风险（已预判） | 限并发/限缓冲；或重编内核调低内存参数 |
| 稳态就逼近 50MiB | ⚠️ 内核底噪偏高 | 裁协议、rule-set 替代 geo 库、调 GOGC |
| 内存持续上涨不回落 | ❌ 泄漏 | 用 Instruments 定位；查连接未释放 |
| 长挂频繁被杀 | ❌ 稳定性不达标 | 上面手段组合 + on-demand 自动重连兜底 |

**记住**：sing-box 的 libbox 已内置内存治理（`oomKillerEnabled=true`、`with_low_memory` 编译 tag）。如果还撞顶，说明需要进一步调（重编 xcframework 改内存参数），这属于自研深水区（对应学习文档模块 D+H）。

---

## 5. 观测记录表（填这个，回填后发我判读）

> Debug build，attach 扩展进程读 Memory。单位 MiB。

| 场景 | 基线内存 | 峰值内存 | 是否断线/被杀 | 备注（曲线趋势、恢复情况） |
|---|---|---|---|---|
| S1 空载基线 | | | | |
| S2 日常浏览 | | | | |
| S3 高吞吐测速 | | — | | 峰值是关键 |
| S4 网络切换 | | | | |
| S5 长时间挂机 | — | | | 断了几次/JetsamEvent |

**额外记录**：
- 测速时的下载速度（判断吞吐水平）：______ Mbps
- 是否找到 JetsamEvent 报告：______（找到的话把 per-process-limit 那几行发我）
- iOS 版本 / 机型：______

---

## 6. 本阶段的范围说明（别过度）

- **当前用单节点 fakeip 配置测足够**——核心风险（吞吐尖峰、稳态基线、泄漏）单节点就能压出来。
- **"几百节点 + 大 geosite/geoip 规则集"的稳态内存**，是真实产品的场景，内存压力更大。这个等你接入订阅转换（subconverter）后再专门压一轮——那时才需要把大规则集加载进来看稳态。
- 所以：**现在先跑 S1-S3（尤其 S3 测速），就能对"这内核在 iOS 上稳不稳"有八成把握**。S4/S5 是加分项。

---

*配套：`01-sfi-ne-layer.md`（内存治理在 `ExtensionProvider.startTunnel` 的 `oomKillerEnabled`）、`03-learning-path.md` 模块 H（内存与性能）。*
