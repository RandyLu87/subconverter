# Clash → sing-box 配置转换 PRD

> 状态:草案 · 只定义范围/映射/架构决策,不含实现
> 日期:2026-07-07
> 载体:现有 macOS app(`mac-app/SubConfigStudio`)
> 参考输入:`docs/ios-app/subconfig-clash_26_07_01.yaml`(150 节点 / 24 策略组 / 211 规则)

---

## 0. 重大前提:引擎已内置 sing-box 生成能力

C++ subconverter 引擎**已经支持 `target=singbox`**:
- `proxyToSingBox()` — `src/subconverter/src/generator/config/subexport.cpp:2283`
- `rulesetToSingBox()` — `.../ruleconvert.cpp:520`
- 已接入 `/sub` 路由 — `.../handler/interfaces.cpp:938`(`case "singbox"_hash:`)

**意义**:最难、最易错的部分——20+ 种代理协议的解析与 sing-box 序列化——引擎已经能做,**不必在 Swift 里重写**。

**但要注意**:引擎是**从它自己的配置(`custom_proxy_group` + ruleset)重建**分组与规则的,**不会原样搬运**源 Clash 文件里的 24 个策略组和 211 条规则。这直接决定了下面的核心架构抉择。

---

## 1. 目标 / 非目标

### 目标
1. 在 mac app 里新增一个**「Clash 配置 → sing-box 配置」文件级转换器**。
2. 输入一份完整 Clash YAML(proxies + proxy-groups + rules + dns),输出一份可直接被 Nest(iOS)导入运行的 sing-box JSON。
3. 尽最大努力**忠实保留**源配置的策略组结构、路由规则、DNS 行为。
4. 对 sing-box 不支持的特性给出**明确的降级 + 报告**,不静默丢弃。
5. 顺带产出**图标旁路映射**(源 proxy-group 的 `icon` URL → Nest 侧消费,呼应策略组 PRD 的图标方案 B)。

### 非目标
- 不做 sing-box → Clash 反向转换。
- 不做 Surge/QuantumultX 等其它格式(只 Clash → sing-box)。
- 不在本功能里做订阅拉取/更新(输入是"一份已有的 Clash 配置",不是订阅 URL)。
- 不追求 100% 语义等价(GFW 规则集、mrs 规则库等无法逐字节复刻,见 §5)。

---

## 2. 输入 / 输出

### 输入
- 一份 Clash / Clash.Meta YAML(本地文件导入 / 粘贴 / 复用 app 已有 source)。
- 需容忍 Clash.Meta 扩展字段(`icon`、`GEOSITE`、`mrs` rule-provider 等)。

### 输出
- **主产物**:sing-box `config.json`(tun 入站,面向 Nest 运行)。
- **副产物 1**:转换报告(跳过的节点、降级的组/规则、警告清单)。
- **副产物 2(可选)**:`icons.json` 旁路映射 `{ "OpenAI": "https://…", … }`(Nest 侧远程加载图标用)。

---

## 3. 核心架构决策:保真模型 + 实现路径

### 3.1 保真模型(必须先定)

| 模型 | 说明 | 结果 |
|---|---|---|
| **A. 文件级忠实转换(推荐)** | 保留源 Clash 文件的**原样**策略组(Claude Code/OpenAI/…)、规则、图标 | 输出 sing-box 与源 Clash 编辑意图一致 |
| B. 订阅式重建 | 只抽取节点,套用 **app 自己的 sing-box 预设**(自定义组/规则) | 源文件的编辑性分组被替换 |

> **推荐 A**。用户诉求是「把**这份** Clash 配置转成 sing-box」,其策略组和规则是精心编排的(按应用分流:Claude/OpenAI/Binance/Futu/Lark…),必须保留。B 更像"重新生成一份我自己的配置",不符合"转换"语义。

### 3.2 实现路径(在 A 之下,三选一)

| 路径 | 做法 | 优 | 劣 |
|---|---|---|---|
| **P1 纯 Swift 转换器** | Swift 解析 YAML → 直接产 sing-box JSON,自己实现协议映射 | 完全可控、无引擎依赖、离线 | 要重写 20+ 协议映射(易错);本项目当前只需 ss/trojan,但未来协议扩展成本高 |
| **P2 引擎驱动** | 把源的 groups/rules 翻译成引擎的 `custom_proxy_group`+ruleset,喂给引擎 `target=singbox` | 复用引擎成熟的协议序列化 | 引擎会"重建",要把 24 组+211 规则映射进引擎配置格式,`icon`/逐条 domain 规则难塞进引擎模型;耦合本地 HTTP 引擎 |
| **P3 混合(推荐)** | **节点**走引擎 `target=singbox&list=true` 拿到 sing-box 化的 outbound 数组(复用引擎协议解析);**分组/规则/DNS/入站**在 Swift 里按源文件忠实拼装 | 协议解析用引擎(稳),编辑性结构用 Swift(忠实) | 需要引擎支持"只输出节点数组"的 sing-box list 模式(待核实) |

> **推荐 P3**,前提是核实引擎能否输出「纯 sing-box outbound 列表」(类似现有 Clash 的 `list=true`)。若不能,退化为 **P1**(对当前只有 ss/trojan/ssr 的输入,P1 工作量可控)。

> **待核实项(实现方案阶段必做)**:`target=singbox` 是否支持 `list=true` 只吐 outbounds?若否,是否可用一个"仅节点"的 base 模板让引擎产出后由 Swift 抽取 `outbounds`。

---

## 4. 转换映射表

### 4.1 proxies → outbounds

| Clash type | sing-box type | 字段映射 / 备注 |
|---|---|---|
| `ss` | `shadowsocks` | `cipher`→`method`;`plugin: obfs`→`plugin:"obfs-local"`,`plugin_opts:"obfs=<mode>;obfs-host=<host>"`;`plugin: v2ray-plugin`→`plugin:"v2ray-plugin"` |
| `trojan` | `trojan` | `sni`→`tls.server_name`;`skip-cert-verify`→`tls.insecure`;`alpn`→`tls.alpn` |
| `vmess` | `vmess` | `uuid`/`alterId`/`cipher`;`network: ws/grpc/h2`→`transport` |
| `vless` | `vless` | `uuid`/`flow`;`reality-opts`→`tls.reality`;`transport` |
| `hysteria2` | `hysteria2` | `password`/`obfs`/`up`/`down` |
| `tuic` | `tuic` | `uuid`/`password`/`congestion-control` |
| `wireguard` | `wireguard` | key/peer/address |
| `http`/`socks5` | `http`/`socks` | |
| `anytls` | `anytls` | 本 fork 已支持 anytls 解析 |
| **`ssr`** | ❌ **不支持** | sing-box 无 shadowsocksr → **跳过 + 计数报告**(本样例 92 个) |
| `snell` | ❌ 不支持 | 跳过 + 报告 |

内置特殊出站:`{type:direct,tag:direct}`,(REJECT 见 §5)。

### 4.2 proxy-groups → outbound groups

| Clash type | sing-box type | 字段映射 |
|---|---|---|
| `select` | `selector` | `proxies`→`outbounds`;`default` 取首个可用成员 |
| `url-test` | `urltest` | `url`→`url`;`interval`(Clash 秒)→sing-box `"3m"` 时长串;`tolerance` |
| `fallback` | `urltest` | 近似(sing-box 无独立 fallback;urltest 按延迟优先) |
| `load-balance` | `urltest` + 警告 | sing-box 无负载均衡 → 降级为 urltest + 报告 |
| `relay` | ❌ + 警告 | sing-box 出站组无链式 relay → 跳过 + 报告(或后续用 dialer 链) |

**成员名解析**:`DIRECT`→`direct`;`REJECT`→见 §5;其它名 = 节点 tag 或嵌套组 tag(需保持引用完整,跳过的 ssr 节点要从各组成员里剔除)。
**图标**:`icon` URL 抽出到副产物 `icons.json`(sing-box 配置内不放,见策略组 PRD)。

### 4.3 rules → route.rules

| Clash 规则 | sing-box route rule |
|---|---|
| `DOMAIN,x,POLICY` | `{domain:["x"], outbound:POLICY}` |
| `DOMAIN-SUFFIX,x,POLICY` | `{domain_suffix:["x"], …}` |
| `DOMAIN-KEYWORD,x,POLICY` | `{domain_keyword:["x"], …}` |
| `IP-CIDR/IP-CIDR6,x,POLICY[,no-resolve]` | `{ip_cidr:["x"], …}` |
| `GEOIP,cn,POLICY[,no-resolve]` | `geoip` rule_set(远程 srs `geoip-cn`);`GEOIP,private`→`ip_is_private:true` |
| `GEOSITE,x,POLICY` | `rule_set` 远程 srs(`geosite-x`);`GEOSITE,private`→私有域处理 |
| `RULE-SET,name,POLICY` | 依赖 §4.4 provider 映射 |
| `MATCH,POLICY` | `route.final = POLICY` |
| `PROCESS-NAME` 等 | iOS 下多不适用 → 保留可转的,其余报告 |

**优化(可选)**:同一 POLICY 的多条 `domain_suffix` 合并进一条规则的数组,减小体积(211 条可压缩很多)。
**POLICY 映射**:组名/节点名 → outbound tag;`DIRECT`→`direct`;`REJECT`→§5。

### 4.4 rule-providers → route.rule_set

| Clash provider | sing-box |
|---|---|
| `behavior: domain/ipcidr`,`format: mrs/yaml/text` | sing-box 用 `.srs` 二进制 rule-set,**格式不通用** |

处理策略(按优先级):
1. **知名 provider 映射表**:`cn-domain`(MetaCubeX geosite/cn.mrs)→ sing-box `geosite-geolocation-cn.srs`(SagerNet)。维护一张常见 provider → sing-box srs 的对照表。
2. 未知 provider:**报告 + 跳过该 RULE-SET 规则**(或让用户手填等价 srs URL)。
3. 远程 rule-set 统一加 `http_client:{detour:<PROXY组>}`(参考已验证的 Nest 配置)。

### 4.5 dns(Clash → sing-box)

| Clash | sing-box |
|---|---|
| `enhanced-mode: fake-ip` | `dns.servers[{type:fakeip, inet4_range:<fake-ip-range>}]` |
| `fake-ip-range: 198.18.0.1/16` | fakeip `inet4_range`(注意 sing-box 用 `198.18.0.0/15` 家族,做等价换算) |
| `fake-ip-filter: [...]` | fakeip 排除 → dns rule 指向真实解析 |
| `nameserver: [doh...]` | `dns.servers[{type:https,...}]` |
| `default-nameserver` | bootstrap / `dns-direct` |
| `proxy-server-nameserver` | dns rule:节点服务器域名用指定 server 解析 |

> 落地时**优先采用已验证的 Nest DNS 模板**(fakeip + `geosite-cn`→`dns-direct` 国内直连分流 + `default_domain_resolver`),把源 dns 的 nameserver 填进去即可,而非逐字段硬翻——更稳、已在真机验证。

### 4.6 sniffer / inbound / 顶层

| Clash | sing-box |
|---|---|
| `sniffer.{HTTP,TLS,QUIC}` | route rule `{action:"sniff"}` + `{protocol:"dns",action:"hijack-dns"}` |
| `port/socks-port/allow-lan` | **忽略**(Nest 用 `tun` 入站);产出固定 tun inbound 模板 |
| `mode: Rule` | 规则生效(默认) |
| — | 补 `route.default_domain_resolver`、`route.auto_detect_interface`、`route.final` |

---

## 5. 不支持特性 & 降级处理(必须显式报告,不静默)

| 特性 | 处理 |
|---|---|
| `ssr` 节点 | 跳过,报告 `跳过 N 个 SSR 节点(sing-box 不支持)`,并从各组成员剔除 |
| `snell` / 其它 sing-box 无对应协议 | 同上 |
| `REJECT` / `REJECT-DROP` 策略 | 映射为 route rule `{action:"reject"}`;作为组成员出现时无法直接表达 → 报告 |
| `load-balance` / `relay` 组 | 降级为 urltest / 跳过 + 报告 |
| `.mrs`/未知 rule-provider | 走对照表;命不中则报告 + 跳过对应规则 |
| Clash 独有 rule 类型(PROCESS 等) | iOS 不适用的报告 |
| 空组 / 循环引用 | 校验器拦截并报告(见 §7) |

**报告 UI**:转换后展示分级清单(错误 / 警告 / 信息),让用户知道"哪些没转过来、为什么"。

---

## 6. mac app UI 集成

现状:`ContentView` = SourcesPanel(订阅源)+ PresetPanel + PreviewPanel(Generate/Export)。现有流程产 Clash YAML。

方案(最小侵入):
- 顶部加一个**模式切换**:`生成(订阅→Clash)` / `转换(Clash→sing-box)`。
- 「转换」模式下:
  - 输入区:导入/粘贴 Clash YAML(或选一个已有 source)。
  - 「转换」按钮 → 右侧 PreviewPanel 显示 sing-box JSON。
  - 下方/侧栏:**转换报告**(§5 的分级清单)。
  - 导出:`config.json` + 可选 `icons.json`。
- 复用现有 `CodePreviewTextView` 展示 JSON;复用 `EngineController`(若走 P3)。

新增服务(实现阶段):`ClashToSingBoxConverter`(解析+映射+校验+报告),与现有 `ClashConfigBuilder` 平级。

---

## 7. 校验策略

1. **结构自检**(必做,已有脚本经验):tag 无重复、组成员引用存在、`route.final`/`detour` 有效、无自引用、rule_set 引用存在。
2. **JSON 合法性**:能被 `JSONSerialization`/sing-box 解析。
3. **语义校验(尽力)**:若 mac 上能装 `sing-box check`(CLI)则跑一遍;否则靠 §1 + Nest 真机导入验证(导入不报错即合法)。
4. 转换器对每一步不可转的输入都要能定位到**源行/字段**,便于报告。

---

## 8. 里程碑(实现方案阶段细化)

| 里程碑 | 内容 |
|---|---|
| **C1 核实 + 骨架** | 核实引擎 `target=singbox` 是否支持 list;定 P3/P1;搭 `ClashToSingBoxConverter` 骨架 + 模式切换 UI |
| **C2 节点转换** | proxies→outbounds(先覆盖样例的 ss(obfs)/trojan;ssr 跳过报告) |
| **C3 组 + 规则** | proxy-groups→selector/urltest;rules→route.rules(含合并优化);provider 对照表 |
| **C4 DNS + 入站 + 组装** | 套用已验证 DNS 模板;tun 入站;`default_domain_resolver`;整体组装 + 结构自检 |
| **C5 报告 + 导出 + 图标** | 分级报告 UI;导出 config.json + icons.json;真机导入验证 |

---

## 9. 决策(已定)

1. ✅ **保真模型 = A(文件级忠实转换)** —— 原样保留源 Clash 的策略组与规则。
2. ✅ **实现路径 = P3(混合)** —— 已核实引擎 `target=singbox&list=true` 输出 `{"outbounds":[纯节点]}`,协议映射齐全;mac app 本就在跑引擎,无新依赖。节点走引擎,组/规则/DNS/入站用 Swift 忠实拼装。
3. ✅ **图标 = 本期产出 `icons.json`** 旁路映射(衔接策略组图标方案 B)。
4. ✅ **输出定位 = 专门面向 Nest** —— 固定 tun 入站 + 已验证的 fakeip + 国内直连 DNS 模板。
5. rule-provider 对照表:先支持样例的 `cn-domain`(→geosite-cn),预留可扩展的对照表结构。

**已知必处理坑**:引擎对 ssr 节点仍输出 `type: shadowsocksr`(sing-box 不支持)→ 转换器必须显式过滤 ssr(节点 + 各组成员)。

> 落地方案见 `09-plan-clash-to-singbox.md`。
