# 落地方案:出站模式切换(规则 / 全局 / 直连)

> 编号:11 · 对应 PRD:[10-prd-outbound-mode.md](10-prd-outbound-mode.md) · 状态:待实施
> 前置调研已完成(2026-07-07,Nest 端 + 转换器端代码级核实),本文可直接按里程碑执行。

## 0. 可行性分析(现状盘点)

### 0.1 Nest 端 —— 链路已就绪,只缺 UI

| 环节 | 现状 | 证据 |
|---|---|---|
| Libbox API | ✅ `LibboxCommandClient.setClashMode(_:) throws`(同步);handler 回调 `initializeClashMode(modeList,currentMode)` / `updateClashMode(newMode)` | Libbox.objc.h(setter 约 L502,回调约 L177/179) |
| 命令流订阅 | ✅ 全局 `CommandClient` 已带 `.clashMode` 订阅 | `Shared/Network/ExtensionEnvironments.swift:185` `CommandClient([.log,.status,.groups,.clashMode])` |
| 状态发布 | ✅ `@Published clashModeList:[String]` / `clashMode:String`,回调已落地(含 activeConnection 防串扰) | `Shared/Network/CommandClient.swift:131-132,473-486` |
| 设置调用先例 | ✅ `ClashModeCard.setClashMode`:乐观更新 + `CommandTarget.standaloneClient().setClashMode` + 失败 alert | `ApplicationLibrary/Views/Dashboard/Cards/ClashModeCard.swift:193-201` |
| 现有 UI | 仪表盘 `ClashModeCard`(可见性 `clashModeList.count > 1`,从未触发过);组页无 toolbar;仪表盘 iOS toolbar 右上角现为「远程 Others 菜单(条件显示)」 | `ClashModeCard.swift:189-191`、`GroupListView.swift`、`DashboardView.swift:33-41` |
| 运行时行为 | 模式列表仅在命令流连上后由内核推送;断开后**不清空**(留存旧值)→ UI 必须同时 gate `serviceAvailable` | `CommandClient.swift:365-376`(disconnect 不清列表) |

### 0.2 配置端 —— 关键路径,四缺一不可

`ClashToSingBoxConverter.assemble()`(`mac-app/SubConfigStudio/Services/ClashToSingBoxConverter.swift:435-485`)现产物:

| 需要 | 现状 | 后果 |
|---|---|---|
| `experimental.clash_api` | ❌ 无 `experimental` 段 | 内核不建 clash server,无模式概念 |
| `clash_mode` 路由规则 | ❌ 规则里无 | 即便有 API,切模式不改变路由 |
| `GLOBAL` 选择器 | ❌ 无(outbounds = 组+节点+direct) | 全局模式无出口可指 |
| `experimental.cache_file` | ❌ 无 | 模式与 selector 选点均不持久化 |

已核实真实产物 `nest-test-config-groups.json`:顶层仅 `dns/inbounds/log/outbounds/route`,`route.final="Other"`,16 selector + 8 urltest,无 GLOBAL。

**结论:可行,双端改动,无内核 / 无引擎(C++)改动。** 附注:引擎侧其实有 `singbox_add_clash_modes`(`RuntimeInstaller.swift:195` 已写入 pref.toml,引擎 `ruleconvert.cpp:540-541` 会产 clash_mode 规则),但 app 的转换路径只取 `list=true` 的纯节点数组、route 全部自建,所以该开关对本路径无效——模式规则必须在 Swift 模板里自己加。

### 0.3 sing-box 机制要点(实现依据)

- 模式列表 = `default_mode`(缺省 `Rule`)+ 路由/DNS 规则中出现的所有 `clash_mode` 值;`clash_mode` 匹配大小写不敏感,展示用原始串 → 统一写 **`Rule` / `Global` / `Direct`**(与引擎 C++ 产物一致)。
- `external_controller` 留空即可:clash server 仍会创建并管理模式,只是不开 HTTP 监听(不额外占端口,iOS NE 内存友好)。
- `cache_file.enabled=true` 同时持久化:clash 模式、selector 选点、fakeip 映射(`store_fakeip`)。cache.db 落在 NE 工作目录(app group),由 sing-box-for-apple 既有机制管理。

## 1. 改动 A:转换器模板(subconverter 仓库)

文件:`mac-app/SubConfigStudio/Services/ClashToSingBoxConverter.swift`,全部集中在 `assemble()` 与 `validate()`。

### A1. 合成 GLOBAL 选择器

```swift
// groups/nodes 组装完成后:
let groupTags = groups.compactMap { $0["tag"] as? String }
let nodeTags  = nodes.compactMap { $0["tag"] as? String }
let globalTag = "GLOBAL"   // 若源配置已占用该名(见 A5),跳过合成并复用
let globalSelector: [String: Any] = [
    "type": "selector", "tag": globalTag,
    "outbounds": groupTags + nodeTags,        // Clash GLOBAL 语义:所有分组+所有节点
    "default": finalOutbound                   // 初始出口 = 规则模式的 final,行为最不突兀
]
outbounds.insert(globalSelector, at: 0)        // 排组列表首位,组页里置顶
```

### A2. 路由规则插入 clash_mode(顺序敏感)

```swift
var routeRuleList: [[String: Any]] = [
    ["action": "sniff"],
    ["protocol": "dns", "action": "hijack-dns"],
    ["ip_is_private": true, "outbound": "direct"],          // 保持在 clash_mode 之前:任何模式下局域网都直连
    ["clash_mode": "Direct", "outbound": "direct"],
    ["clash_mode": "Global", "outbound": globalTag]
]
routeRuleList.append(contentsOf: routeRules)
```

> `ip_is_private` 放 clash_mode 之前是刻意决策(PRD §4.5):全局模式下打印机/路由器等内网访问不被劫走。

### A3. DNS 规则插入 clash_mode

```swift
"rules": [
    ["clash_mode": "Direct", "server": "dns-direct"],                                   // 直连:全部真实 IP,避免 fakeip 参与
    ["clash_mode": "Global", "query_type": ["A","AAAA"], "server": "fake", "rewrite_ttl": 1], // 全局:CN 域名也走 fakeip→代理
    ["rule_set": ["geosite-geolocation-cn"], "server": "dns-direct"],
    ["query_type": ["A","AAAA"], "server": "fake", "rewrite_ttl": 1]
]
```

> 直连模式强制 dns-direct 是**必做**而非优化:虽然 sing-box 对「fakeip 目标 + direct 出站」会经域名映射回源,但停留 fakeip 路径徒增回源解析且行为难验证;直接绕开 fakeip 最稳。

### A4. experimental 段

```swift
"experimental": [
    "clash_api": ["default_mode": "Rule"],                    // external_controller 留空
    "cache_file": ["enabled": true, "store_fakeip": true]
]
```

### A5. validate() 扩展 + 冲突处理

- 若源配置存在名为 `GLOBAL` 的组:不合成新组,直接把 clash_mode Global 规则指向它,并输出 warning 消息(转换报告里可见);
- 校验 clash_mode 规则的 outbound 引用存在;
- GLOBAL 成员引用校验复用现有循环(A1 的成员本来就取自已生成 tags,天然通过)。

### A6. icons.json / 内置图标(可选,5 分钟)

Nest `App/GroupIcons.json` 增加 `"global"` 关键词映射(GLOBAL 组在组页显示图标);无映射时回退 SF Symbol,不阻塞。

**A 里程碑验收(离线,不需真机)**:重新转换样例 → 产物 JSON 断言:
1. `experimental.clash_api.default_mode == "Rule"`、`cache_file.enabled == true`;
2. route.rules 前 5 条顺序如 A2;dns.rules 前 2 条为 clash_mode 规则;
3. 存在 `GLOBAL` selector,成员数 = 组数+节点数,default 在成员内;
4. `sing-box check -c 产物`(若本机有 sing-box CLI;没有则靠 Nest 导入时内核校验)。

## 2. 改动 B:Nest 右上角模式入口(Nest 仓库)

### B1. 新组件 `ClashModeMenu`

新文件 `ApplicationLibrary/Views/Dashboard/ClashModeMenu.swift`(iOS 优先,macOS/tvOS 本期不挂):

```swift
public struct ClashModeMenu: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @ObservedObject var commandClient: CommandClient   // 传 environments.commandClient
    @State private var optimisticMode: String? = nil   // 乐观值,updateClashMode 回推后清空
    @State private var alert: AlertState?

    // 可见性:服务在跑 && 模式数 > 1(断流后列表是旧值,必须双重 gate)
    private var visible: Bool {
        environments.serviceAvailable && commandClient.clashModeList.count > 1
    }
    private var currentMode: String { optimisticMode ?? commandClient.clashMode }

    public var body: some View {
        if visible {
            Menu {
                ForEach(commandClient.clashModeList, id: \.self) { mode in
                    Button {
                        optimisticMode = mode
                        Task { await setMode(mode) }
                    } label: {
                        if mode.lowercased() == currentMode.lowercased() {
                            Label(displayName(mode), systemImage: "checkmark")
                        } else {
                            Text(displayName(mode))
                        }
                    }
                }
            } label: {
                Label(displayName(currentMode), systemImage: icon(currentMode))
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
            }
            .onChangeCompat(of: commandClient.clashMode) { _ in optimisticMode = nil }
            .alert($alert)
        }
    }
}
```

- `displayName`:小写匹配 rule/global/direct → `String(localized:)` 的 `Rule`/`Global`/`Direct`,其余原样;
- `icon`:rule `arrow.triangle.branch` / global `globe` / direct `arrow.right.circle` / 其它 `circle.grid.2x2`;
- `setMode`(在 `ClashModeCard.setClashMode` 基础上增加断连步骤,保证立即生效):

  ```swift
  private nonisolated func setMode(_ newMode: String) async {
      do {
          let client = try CommandTarget.standaloneClient()
          try client.setClashMode(newMode)
          // 硬性需求:切换立刻生效。setClashMode 只影响新连接,存量长连接
          // (视频流/下载)仍在旧路径;主动断开全部连接迫使按新模式重建。
          // 断连失败不算切换失败(模式已切成功),只记日志。
          do { try client.closeConnections() } catch {
              NSLog("[ClashMode] closeConnections 失败(已忽略): \(error.localizedDescription)")
          }
      } catch {
          await MainActor.run {
              optimisticMode = nil          // 回滚乐观值,以内核状态为准
              alert = AlertState(action: "set clash mode", error: error)
          }
      }
  }
  ```

  依据:`LibboxCommandClient.closeConnections()` 已存在(Libbox.objc.h L489,`closeConnection(id)` 的全量版,macOS 连接页「Close All」同款)。

- **无配置态**:可见性 gate 的 `environments.serviceAvailable` 在 profile 列表为空时必为 false(无配置 → VPN 无法启动 → 无命令流),PRD「无任何配置不支持切换」天然满足,无需额外代码;验收时显式覆盖该场景即可。

### B2. 挂载两处 toolbar

- `GroupListView.swift`(组页,现无 toolbar):
  ```swift
  .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
          ClashModeMenu(commandClient: environments.commandClient)
      }
  }
  ```
- `DashboardView.swift:33-41`(与现有条件 othersMenu 并列):
  ```swift
  ToolbarItemGroup(placement: .topBarTrailing) {
      ClashModeMenu(commandClient: environments.commandClient)
      if !remoteServers.isEmpty { othersMenu }
  }
  ```

组页/仪表盘的 `onAppear` 均已调 `environments.connect()`,模式列表连上即到,无需新增连接逻辑。

### B3. 本地化

`Localizable.xcstrings` 增补(若键不存在):`Rule`=规则/規則、`Global`=全局/全域、`Direct`=直连/直連。`ClashModeCard` 显示原始串,不动。

### B4. 明确不做

- 不改 `ClashModeCard`(自动开始生效,用户可用 Dashboard Items 关);
- 不清理 `CommandClient` 断流不清列表的行为(靠 gate 掩蔽,与上游一致,减少 diff);
- macOS/tvOS 入口本期不加(组件放 ApplicationLibrary,后续挂载成本≈0)。

## 2.5 改动 C:Nest 运行时配置自愈(2026-07-07 需求升级后新增,已实施)

> 背景:Nest 的最终用户不一定有 mac 转换器,模式能力必须由 App 自身保证。

- **`Shared/Network/ClashModePatcher.swift`**(Library target,App/NE 共用):纯 Foundation 的 JSON 变换。
  在 NE 加载配置的唯一咽喉点 **`ExtensionProvider.startService()`** 调用,内核启动前补全,不回写 profile。
- 补全逻辑与转换器模板同构:direct 出站兜底 → GLOBAL 合成(成员=非 direct/block/dns 类型的全部出站,default=route.final)→ clash_mode 路由规则插在"保护性前缀"(action 规则 / ip_is_private / 旧式 protocol:dns 劫持)之后 → DNS 规则保守注入(仅在可靠识别 fakeip / 真实解析器时;识别不出只跳过 DNS,模式仍生效)→ experimental 合并(不覆盖已有字段)。
- **放行条件**(原样运行,不补全):已含任何 clash_mode 规则 / JSON 解析失败 / "direct"或"GLOBAL" tag 被反常占用 / 无可用成员。
- 离线断言 22 项全过(旧转换产物补全、新产物放行、极简手写、GLOBAL 冲突、旧式 dns-out 兼容)。
- 补全动作经 `writeMessage` 写入内核日志(`clash-mode autopatch: ...`),真机可在日志页确认。

## 2.6 改动 D:真机验收后的体验修订(2026-07-08,已实施)

1. **GLOBAL 成员=纯节点平铺**(不含分组):转换器 A1 与 patcher 同步修改,全局模式下直接选节点。default 取 final(若为节点)否则首节点。
2. **组页按模式过滤**:`GroupListView` 订阅 `commandClient.$clashMode`;`GroupModeFilter.visibleTags` — 全局=仅 GLOBAL(无则回退全部)/直连=空(`DirectModeEmptyView`)/其它=隐藏 GLOBAL。过滤在 ForEach 内做保留 Binding;全局模式自动 `ensureExpanded("GLOBAL")`(ViewModel 新增幂等方法)。
3. **入口常驻可操作**:
   - `SharedPreferences.preferredClashMode`(空串=从未切换,不强制对齐);
   - `CommandClient.initializeClashMode` → 本机连接时若 preferred 与内核不一致且在列表内,`setClashMode` 对齐(以 App 期望覆盖 cache_file 恢复值);
   - `CommandClient.updateClashMode` → 本机连接时回写 preferred(菜单/卡片/对齐任何来源);
   - `ClashModeMenu` 去掉可见性 gate:运行态显示内核模式,停机态显示/写偏好(列表退回固定 Rule/Global/Direct),远程控制时不写本机偏好。
4. **Clash Mode 卡片默认第一位**:`DashboardCard.defaultOrder` 置顶;排序/隐藏沿用 Dashboard Items 现有能力(已保存排序的设备需 Reset 生效)。

## 3. 里程碑与验收

| 里程碑 | 内容 | 验收 |
|---|---|---|
| M1 转换器 | A1–A5(+A6) | §1 离线断言全过;转换报告无新增 error |
| M2 Nest UI | B1–B3 | 编译过;真机连上后组页/仪表盘右上角显示「规则」入口 |
| M3 真机端到端 | 全链路 | PRD §7 验收 1–9 逐条打勾 |

**M3 操作脚本**(改动 C 落地后**无需重转配置**,现有 profile 直接启动即触发自愈):启动 VPN →
① 右上角显示「规则」;② 切「全局」查 ip.sb(出口=GLOBAL 选点,改 GLOBAL 选点后 IP 跟随;百度也走代理);③ 切「直连」查 ip.sb(=本机运营商 IP,局域网可达);④ **立即生效验证**:播放一段在线视频/开启持续 ping,切换模式,观察闪断后立刻按新路径恢复(全局↔直连切换时出口 IP 即刻变化,无需重启 VPN);⑤ 切回「规则」行为复原;⑥ 停 VPN(入口消失)→ 重启(模式保持);⑦ 杀 App 重开(模式保持);⑧ 顺带确认 selector 选点也持久化了(cache_file 副产收益);⑨ **无配置验证**:删除全部 profile,确认组页/仪表盘均无模式入口。

## 4. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 切换后断开全部连接对用户有感(下载/播放闪断) | 低 | 属 PRD 硬性要求的代价(立即生效),与 Clash Verge 行为一致;闪断后自动重连。若后续反馈强烈,可加「切换时不断开连接」设置项(本期不做) |
| fakeip + 直连模式回源异常(域名映射失效) | 中 | A3 已把 Direct 模式 DNS 整体切到真实 IP,绕开 fakeip;M3-③ 显式验证 |
| 模式列表顺序/大小写与预期不符(sing-box 版本差异) | 低 | UI 遍历 `clashModeList` 原样渲染 + 小写匹配映射,不硬编码顺序 |
| 源配置已有 `GLOBAL` 组名 | 低 | A5:复用 + warning,不重复合成 |
| cache_file 引入后行为变化(选点跨重启保留) | 低 | 属正收益;PRD §6 已声明,验收 ⑦ 覆盖;异常时可指导用户删 profile 重装重置 cache |
| 旧配置无模式 → 用户找不到入口 | 低 | PRD §6:优雅降级,重新转换即可;不做运行时提示 |
| GLOBAL 组成员过多(数百节点)组页展开卡顿 | 低 | 组页已是手风琴按需展开;如实测卡顿,GLOBAL 成员降级为「仅分组」再评估 |

## 5. 工作量预估

- M1 转换器:0.5 天(含离线断言脚本);
- M2 Nest UI:0.5 天(组件 + 两处挂载 + 本地化);
- M3 真机验证:0.5 天。
合计 ~1.5 人天,无阻塞依赖,M1/M2 可并行。
