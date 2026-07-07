# Nest 策略组(Policy Groups)PRD

> 状态:草案 · 只定义范围与交互,不含实现
> 日期:2026-07-06
> 依赖:已完成的 Nest POC(隧道内核 / 配置管理 / 控制中心开关)

---

## 0. 能力判定(先回答"到底支不支持")

**结论:支持,且底层能力已在 Nest 代码里,主要缺 iOS 入口与交互皮肤。**

### 0.1 sing-box 内核层

sing-box 通过**出站(outbound)类型**实现策略组,与 Clash 概念一一对应:

| Clash / Stash | sing-box outbound | 行为 |
|---|---|---|
| `select`(手动选择组) | `selector` | 用户手动指定组内某个节点 |
| `url-test`(自动测速组) | `urltest` | 内核按 URL 延迟自动选最优,用户不可手选 |
| `fallback` | `urltest`(`tolerance` 语义近似) | 主用不可用时切换 |
| 组可嵌套(组套组) | outbound 可引用其它 outbound tag | ✅ 支持 |

策略组不是一个独立的"面板功能",而是**配置里定义了 `selector`/`urltest` 出站,内核运行时就会把它们暴露为可交互的 group**。

### 0.2 交互控制通道

有两条路,Nest 选后者:

- **Clash API**(`experimental.clash_api`):`GET /proxies`、`PUT /proxies/{name}` 选择、`GET /proxies/{name}/delay` 测速。需要内核开 HTTP 端口。
- **Libbox 命令通道(Nest 采用)**:`LibboxCommandGroup` 订阅组状态流,`selectOutbound(group, tag)` 选择,`urlTest(group)` 测速,`setGroupExpand` 展开状态。跨进程直连内核,**无需额外 HTTP 端口**,契合 NE 架构。

### 0.3 Nest 现有资产(来自 SFI)

| 层 | 文件 | 状态 |
|---|---|---|
| 数据模型 | `Shared/Network/OutboundGroup.swift`(`OutboundGroup` / `OutboundGroupItem`,含 `selectable`、`urlTestDelay`、`selected`) | ✅ 可直接用 |
| 状态流 | `Shared/Network/CommandClient.swift`(`@Published groups`,`LibboxCommandGroup` 订阅) | ✅ 可直接用 |
| 交互逻辑 | `ApplicationLibrary/Views/Groups/GroupListViewModel.swift`(`selectOutbound` / `performURLTest` / `toggleExpand`,含乐观更新 `pendingSelections`) | ✅ 可直接用 |
| 视图 | `Groups/GroupListView` · `GroupView` · `GroupItemView` | ⚠️ 存在但为 SFI dashboard 内联式皮肤,需按 Stash 交互重做 |
| iOS 入口 | `NavigationPage` 的 `.groups` | ❌ 仅 `#if os(macOS)`,iOS 无入口 |
| 配置 | `nest-test-config.json` | ❌ 仅单 `proxy` 出站,无策略组,列表将为空 |

---

## 1. 目标与非目标

### 1.1 目标
1. iOS 上新增一级「策略组」入口(对齐截图:底部 tab 第二项)。
2. 交互对齐 Clash/Stash 标准:**两级下钻**——组列表 → 组内节点列表。
3. 支持手动选择(`selector`)与自动测速展示(`urltest`)。
4. 支持单组测速与延迟可视化(数值 + 颜色)。
5. 复用现有数据/命令层,不重写内核桥接。

### 1.2 非目标(本期不做)
- **在 App 内编辑/新建策略组**:组结构由配置(profile)决定,改组=改配置文件,属于配置编辑器/订阅转换范畴。
- **订阅链接 → 自动生成策略组**:这是独立里程碑(M6 subconverter 集成),本期只消费已含策略组的配置。
- 组内节点拖拽排序、组自定义排序持久化。
- 全局一键测速所有组(本期先做单组测速;可作为 G3 增量)。

---

## 2. 交互设计(对齐 Clash / Stash 标准)

### 2.1 信息架构

```
Tab Bar:  [首页/Dashboard]  [策略组]  [工具]  [设置]
                               │
                    ┌──────────┴───────────┐
                    │  L1 策略组列表         │
                    │  (每组一行,可点入)     │
                    └──────────┬───────────┘
                               │ tap 某组
                    ┌──────────┴───────────┐
                    │  L2 组内节点列表       │
                    │  (选择 / 延迟 / 测速)  │
                    └──────────────────────┘
```

> 说明:SFI 现有 `GroupView` 是"单页内所有组行内展开"的 dashboard 式;本期改为 Stash 式**两级 push 导航**,更符合截图与手机操作习惯。macOS 侧维持原样,不受影响。

### 2.2 L1 — 策略组列表

对照截图,每行元素:

| 元素 | 来源 | 说明 |
|---|---|---|
| 图标 | 组名映射(见 2.5) | Claude/OpenAI/Binance… 图标,无匹配用默认 |
| 组名 | `group.tag` | e.g. `OpenAI` |
| 当前选中节点(副标题) | `group.selected` | Stash 在行内显示当前选中,建议保留 |
| 类型徽标 | `group.displayType` | `选择` / `自动`(selector/urltest) |
| chevron `>` | — | 点击 push 进 L2 |

- 顺序:按配置中出站定义顺序(与生成侧一致,不额外排序)。
- 右上角 `···`:预留(全部测速/折叠等,本期可空)。

> **决策(已定)**:`selector` 点选后**停留在 L2 + 打勾/高亮反馈**,方便连续对比不同节点(贴近 Stash)。

### 2.3 L2 — 组内节点列表

每行:

| 元素 | 来源 |
|---|---|
| 节点名 | `item.tag` |
| 节点类型 | `item.displayType`(Shadowsocks/Trojan/…) |
| 延迟 | `item.delayString`(`123ms`),颜色 `item.delayColor` |
| 选中标记 | `item.tag == group.selected` → ✓ |

行为差异:
- **`selector` 组**(`group.selectable == true`):点击某节点 → `selectOutbound` → 乐观更新打勾 → 返回 L1 或停留(建议停留,给出切换反馈)。
- **`urltest` 组**(`selectable == false`):节点不可手选,仅展示当前自动选中项 + 各节点延迟;顶部提示"自动选择,不可手动切换"。
- 顶部/右上「测速」按钮 → `performURLTest(group.tag)` → 逐节点回填延迟。

### 2.4 状态处理

| 状态 | 表现 |
|---|---|
| 未连接(隧道未启动) | 策略组不可用,展示引导"启动后可用"(内核未运行拿不到组流) |
| 加载中 | `isLoading` → "Loading…" |
| 空组 | 配置无 selector/urltest → "当前配置没有策略组"(引导去导入含策略组的配置) |
| 选择失败 | `alert`(现有 `GroupListViewModel` 已含错误 alert) |

### 2.5 图标(含远程加载的能力边界)

**关键约束:图标地址不能放进 sing-box 配置的策略组里。**
- sing-box 的 `selector`/`urltest` 出站**没有 `icon` 字段**,配置严格校验,塞未知字段会 `unknown field` 报错、内核起不来。
- Libbox 回传的 `LibboxOutboundGroup` 也不透传图标信息(仅 tag/type/selected/selectable/items)。
- "配置里写 `icon: <url>`" 是 **Clash / Clash Meta / Stash 的 `proxy-groups` 约定**,面板远程拉图;sing-box 这条内核链路不认。

因此 Nest 的图标来源走旁路,三选:

| 方案 | 离线 | 隐私 | 说明 |
|---|---|---|---|
| **A. 本地关键词映射(打底)** | ✅ | ✅ 无对外请求 | 按 `group.tag` 大小写不敏感关键词匹配内置 asset/SF Symbol(OpenAI/Claude/Gemini/Binance/OKX/Bybit/YouTube/Apple…) |
| **B. Nest profile 旁路映射(可选增强)** | 半 | ⚠️ 拉图对外请求 | 一份 `{"OpenAI":"https://…"}` 存在 **Nest 自己的 profile 元数据**(不进 sing-box config),App `AsyncImage` 远程加载 + 本地缓存 |
| **C. 订阅转换时提取(未来)** | 半 | ⚠️ 同 B | M6 subconverter 集成时,把 Clash `proxy-group.icon` 抽出来写入 B 的映射 |

**决策(已定)**:
- **A 打底**——先全部默认/关键词映射,离线且隐私安全,交互跑通(G1/G2)。
- **B 远程加载作为可选**(G3+):必须本地缓存、失败回退默认、**并给用户开关**(远程拉图会向第三方暴露"该设备在用哪些策略组",遵循既有隐私红线)。
- 无匹配且无远程 → 默认 `rectangle.3.group` SF Symbol。

---

## 3. 数据流与技术方案

```
内核(NE 进程,sing-box)
   │  Libbox CommandGroup 流
   ▼
CommandClient.$groups  ([LibboxOutboundGroup])
   │  onReceive
   ▼
GroupListViewModel.setGroups() → [OutboundGroup]
   │
   ├── 展示:GroupListView(L1) / GroupDetailView(L2,新增)
   │
   └── 交互:
        selectOutbound → CommandTarget.standaloneClient().selectOutbound  → 内核持久化
        performURLTest → …urlTest
        (乐观更新 pendingSelections,内核回流后对齐)
```

**要新增/改动的(实现阶段,非本 PRD 范围)**:
1. `NavigationPage`:iOS 暴露 `.groups`(移出 `#if os(macOS)` 或加 iOS 分支),放入 tab bar 第二位。
2. 新增 `GroupDetailView`(L2 节点列表,Stash 皮肤)。
3. `GroupListView` 改为可点入的行列表(L1 皮肤),复用 `GroupListViewModel`。
4. 图标映射表(可选)。

**配置依赖(关键前置)**:
- 现有测试配置无策略组,需准备一份含 `selector`/`urltest` 出站的配置用于验收。**决策(已定):本期先手写一份 `nest-test-config-groups.json`**,与策略组开发解耦,不阻塞;M6 subconverter 集成后再用真实订阅生成的配置回归。
- 示例最小结构:
  ```json
  {
    "outbounds": [
      {"type":"selector","tag":"proxy","outbounds":["auto","HK-01","JP-01"],"default":"auto"},
      {"type":"urltest","tag":"auto","outbounds":["HK-01","JP-01"],"url":"https://www.gstatic.com/generate_204","interval":"3m"},
      {"type":"trojan","tag":"HK-01", "...": "..."},
      {"type":"trojan","tag":"JP-01", "...": "..."},
      {"type":"direct","tag":"direct"}
    ],
    "route": {"final":"proxy"}
  }
  ```
  即:`route.final` 指向 `selector`,`selector` 组内含 `urltest` 与具体节点 → App 里会出现 `proxy`、`auto` 两个可交互组。

---

## 4. 里程碑拆分(实现阶段参考)

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **G1 入口 + L1** | iOS 暴露策略组 tab;L1 组列表(复用数据层);准备带策略组的测试配置 | 连上后能看到组列表,行显示组名/当前选中/类型 |
| **G2 L2 两级下钻** | `GroupDetailView` 节点列表;`selector` 点选切换生效 | 进组能选节点,内核实际切换,重进保持 |
| **G3 测速 + 皮肤** | 单组测速、延迟数值+颜色;图标映射;`urltest` 只读态提示 | 点测速回填延迟;自动组不可手选 |
| **G4 状态打磨** | 未连接/空组/加载/错误四态;整体视觉对齐截图 | 四态表现符合 2.4 |

---

## 5. 验收标准

1. 导入含策略组的配置并连接后,「策略组」tab 展示所有 `selector`/`urltest` 组。
2. 进入 `selector` 组可切换节点,切换后内核实际路由改变(可用不同节点出口 IP 验证),App 重启/重进保持选择。
3. `urltest` 组展示自动选中项与各节点延迟,不可手选。
4. 单组测速能刷新组内节点延迟并按颜色区分。
5. 未连接 / 空配置 / 加载 / 出错 四态有明确 UI,不崩不卡。
6. 不改动 macOS 侧现有 Groups 行为。

---

## 6. 风险与未决问题

**风险**
- **延迟测速需内核可出网**:测速 URL 走代理链路,节点全挂时延迟全为超时——需和"节点不可用"态区分(超时显示灰色/超时文案)。
- **乐观更新与内核回流竞态**:现有 `pendingSelections` 已处理,重做视图时需保留该逻辑,勿丢。
- **配置无组时的空态**易被误解为 bug,需明确引导文案。

**已定决策**
- ✅ `selector` 点选后**停留在 L2 + 打勾/高亮反馈**。
- ✅ 验收配置**本期手写** `nest-test-config-groups.json`,与开发解耦。
- ✅ 图标:**A 本地关键词映射打底(G1/G2)**;**B 远程加载可选(G3+),需缓存+回退+用户开关**;地址走 Nest profile 旁路,不进 sing-box config。

**仍未决(需 Randy 拍板)**
1. L1 是否在行内显示"当前选中节点"副标题?(Stash 显示,信息量大但行更高)——建议:显示。
2. 是否需要"全部组一键测速"?——建议:本期单组,后续增量。
