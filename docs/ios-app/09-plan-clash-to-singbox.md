# Clash → sing-box 转换:落地方案

> 基于 `08-prd-clash-to-singbox.md`(决策:A 忠实 / P3 混合 / 面向 Nest / 产 icons.json)
> 日期:2026-07-07 · 载体:`mac-app/SubConfigStudio`
> 只做方案,不实现。
> 本文档留在 subconverter 仓库(转换器代码所在地);消费方 Nest app 的文档见 `../../../Nest/docs/ios-app/`,详见 [docs/ios-app/README.md](README.md)。

---

## 1. 总体架构(P3 混合)

```
Clash YAML ──► ClashConfigParser ──► ClashConfig (Swift 模型)
                                          │
        ┌─────────────────────────────────┼───────────────────────────────┐
        │(节点走引擎)                       │(编辑性结构走 Swift)             │
        ▼                                  ▼                               ▼
 EngineNodeConverter               GroupConverter / RuleConverter     IconExtractor
 (/sub?target=singbox&list=true)   DNSAssembler / RouteAssembler       (icon URL)
        │                                  │                               │
        └──── outbounds[] (滤除 ssr) ──────┴──── groups/route/dns/inbound ──┘
                                          │
                                    SingBoxAssembler ──► config.json
                                          │
                                    StructuralValidator ──► 通过?
                                          │
                        ConversionReport (错误/警告/信息) + icons.json
```

**分工原则**:协议序列化(最难)复用引擎;分组/规则/DNS/入站(要忠实、要面向 Nest)用 Swift 完全掌控。

---

## 2. 节点转换(EngineNodeConverter)

### 2.1 调用方式
- 复用 mac app 已运行的 `EngineController`(127.0.0.1:25500)。
- 把源 Clash YAML 写入临时文件,调用:
  `GET /sub?target=singbox&list=true&url=<file://临时路径>`
- 引擎解析 `proxies:` → 返回 `{"outbounds":[ {type,tag,server,...}, ... ]}`(已核实)。
- `tag` = 节点 Remark(节点名),与 proxy-groups / rules 里引用的名字一致 → 天然对齐。

### 2.2 SSR 过滤(必做)
- 引擎对 ssr **仍输出 `type:"shadowsocksr"`**,sing-box 不认。
- 处理:遍历返回的 outbounds,**丢弃 `type == "shadowsocksr"`**(以及其它 sing-box 不支持类型的兜底黑名单)。
- 收集被丢弃的 `tag` 集合 `droppedTags`,供 §3 剔除组成员、§7 报告。

### 2.3 兜底(引擎不可用/解析失败)
- 若引擎报错或 outbounds 为空 → 明确报错(不产出半成品),提示检查源文件。

---

## 3. 策略组转换(GroupConverter)

输入:`ClashConfig.proxyGroups`;输出:sing-box selector/urltest 组数组。

| Clash | sing-box | 规则 |
|---|---|---|
| `select` | `selector` | `outbounds = proxies`(剔除 droppedTags);`default = 首个有效成员` |
| `url-test` | `urltest` | `url`;`interval`(秒)→ `"<n>s"`;`tolerance` |
| `fallback` | `urltest` | 同上 + 报告"fallback 近似为 urltest" |
| `load-balance` | `urltest` | + 报告降级 |
| `relay` | 跳过 | + 报告"relay 无法转换" |

**成员名解析**(逐个 `proxies` 成员):
- `DIRECT` → `direct`;`REJECT` → `block`(见 §6 注)。
- 命中 droppedTags(ssr)→ 剔除。
- 其它 → 保留(节点 tag 或嵌套组 tag)。
- 剔除后为空的组 → 塞入 `direct` 兜底 + 报告。

**校验**:每个组的 `default`/成员必须在最终 outbounds 全集里存在(§5 校验)。

---

## 4. 规则转换(RuleConverter)

输入:`ClashConfig.rules` + `ruleProviders`;输出:`route.rules[]` + `route.rule_set[]`。

### 4.1 逐条映射
| Clash | sing-box route rule |
|---|---|
| `DOMAIN,x,P` | `{domain:[x], outbound:P}` |
| `DOMAIN-SUFFIX,x,P` | `{domain_suffix:[x], outbound:P}` |
| `DOMAIN-KEYWORD,x,P` | `{domain_keyword:[x], outbound:P}` |
| `IP-CIDR(6),x,P[,no-resolve]` | `{ip_cidr:[x], outbound:P}` |
| `GEOIP,cn,P` | rule_set `geoip-cn`(远程 srs);`GEOIP,private,P`→`{ip_is_private:true,outbound:P}` |
| `GEOSITE,x,P` | rule_set `geosite-x`;`GEOSITE,private`→私有域直连 |
| `RULE-SET,name,P` | 依 §4.3 provider 对照 |
| `MATCH,P` | `route.final = P` |
| 其它(PROCESS 等) | 报告,不转 |

`P`(policy)→ outbound tag:`DIRECT`→`direct`,`REJECT`→§6,其余=组/节点名。

### 4.2 合并优化
- 同一 `(outbound, 字段类型)` 的多条合并进一条规则的数组(211 条 → 少量规则),显著减小体积。
- 顺序:保持源 rules 相对顺序(合并不跨越顺序语义——同 outbound 的可合并,不同 outbound 保序)。

### 4.3 rule-provider 对照(RuleProviderMapper)
- 维护对照表:`{ "cn-domain": {tag:"geosite-cn", url:"https://.../geosite-geolocation-cn.srs", format:"binary"} }`。
- 每个远程 rule_set 加 `http_client:{detour:<主代理组>}`(参考已验证 Nest 配置)。
- 命不中对照表的 provider → 报告 + 跳过引用它的 RULE-SET 规则(不静默)。

---

## 5. DNS / 入站 / 路由组装(面向 Nest,SingBoxAssembler)

**采用已在真机验证的 Nest 模板**,把源信息填进去,而非逐字段硬翻:

```jsonc
{
  "dns": {
    "servers": [
      {"tag":"fake","type":"fakeip","inet4_range":"198.18.0.0/15"},   // 源 fake-ip-range 198.18.0.1/16 归一到此族
      {"tag":"dns-direct","type":"udp","server":"223.5.5.5"}          // 源 default-nameserver 首个国内 DNS
    ],
    "rules":[
      {"rule_set":"geosite-cn","server":"dns-direct"},
      {"query_type":["A","AAAA"],"server":"fake","rewrite_ttl":1}
    ],
    "final":"dns-direct","strategy":"ipv4_only"
  },
  "inbounds":[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30"],
               "auto_route":true,"strict_route":true,"stack":"system"}],
  "outbounds":[ <引擎节点> , <§3 组> , {"type":"direct","tag":"direct"} ],
  "route":{
    "rule_set":[ <§4.3 远程 srs, 带 http_client.detour> ],
    "rules":[
      {"action":"sniff"},                          // 源 sniffer → sniff
      {"protocol":"dns","action":"hijack-dns"},
      {"ip_is_private":true,"outbound":"direct"},
      <§4 转换出的规则...>
    ],
    "final": <MATCH 的 policy>,
    "auto_detect_interface":true,
    "default_domain_resolver":{"server":"dns-direct"}   // 修 1.12 弃用 + 节点域名解析
  }
}
```

- `fake-ip-filter` → 追加 dns 规则让这些域走真实解析(可选,先记报告)。
- 源 `nameserver`(doh)可作为增强:加一个 doh server 供代理侧解析(可选,先用国内 udp 稳)。

---

## 6. REJECT / 特殊出站处理

- sing-box 1.11+ 移除 `block` 出站,改用 route `action:"reject"`。
- **作为规则 policy 的 REJECT** → route rule 用 `{...,"action":"reject"}`(不指 outbound)。
- **作为组成员的 REJECT** → sing-box 组成员无法表达 reject;策略:剔除该成员 + 报告。
- `DIRECT` 统一 → `direct` 出站(§5 已含)。

---

## 7. 转换报告(ConversionReport)

分级收集,UI 展示:
- **error**:引擎失败、JSON 非法、校验不通过(阻断导出)。
- **warning**:ssr/snell 跳过计数、load-balance/relay 降级、未知 provider 跳过、REJECT 成员剔除、空组兜底。
- **info**:转换统计(节点 X 个→Y 个、组 24 个、规则 211→Z 条合并)。

每条尽量带源定位(第几个 group / 第几条 rule / 哪个字段)。

---

## 8. 图标旁路(IconExtractor → icons.json)

- 遍历 `proxyGroups`,收集含 `icon` 的:`{ "<组名>": "<icon URL>" }`。
- 输出 `icons.json`(与 config.json 同目录导出)。
- 呼应策略组图标方案 B:Nest 侧读此映射,`AsyncImage` 远程加载 + 缓存 + 用户开关。
- 本期只产出映射文件;Nest 消费在策略组 G3。

---

## 9. 校验(StructuralValidator)

复用已有自检经验,导出前强制跑:
1. outbounds tag 无重复。
2. 所有组成员 / `default` / 规则 `outbound` / `route.final` / `rule_set` 引用都存在。
3. 无组自引用、无明显环。
4. JSON 能被 `JSONSerialization` 解析。
5. (可选)mac 上若有 `sing-box check` CLI 则跑;否则以 Nest 真机导入为最终验证。

任一硬校验失败 → 归为 error,阻断导出并在报告里定位。

---

## 10. mac app UI 集成

- `ContentView` 顶部加**模式切换**:`生成(订阅→Clash)` / `转换(Clash→sing-box)`。
- 转换模式:
  - 左:输入区(导入/粘贴 Clash YAML,或选已有 source)。
  - 右:`CodePreviewTextView` 显示 sing-box JSON(复用)。
  - 下:转换报告(分级列表)。
  - 操作:`转换` 按钮;`导出` → `config.json` (+ `icons.json`)。
- `AppModel` 增状态:`conversionInput / conversionOutput / conversionReport / conversionIcons`。

---

## 11. 新增文件清单(实现阶段)

| 文件 | 职责 |
|---|---|
| `Services/Conversion/ClashConfig.swift` | 源模型(proxies/proxyGroups/rules/ruleProviders/dns) |
| `Services/Conversion/ClashConfigParser.swift` | YAML → ClashConfig |
| `Services/Conversion/EngineNodeConverter.swift` | 调引擎 list=true 取 outbounds + 滤 ssr |
| `Services/Conversion/GroupConverter.swift` | §3 |
| `Services/Conversion/RuleConverter.swift` + `RuleProviderMapper.swift` | §4 |
| `Services/Conversion/SingBoxAssembler.swift` | §5 组装(Nest 模板) |
| `Services/Conversion/IconExtractor.swift` | §8 |
| `Services/Conversion/StructuralValidator.swift` | §9 |
| `Services/Conversion/ConversionReport.swift` | §7 模型 |
| `Services/Conversion/ClashToSingBoxConverter.swift` | 编排以上 |
| `Views/ConversionView.swift`(或扩展 ContentView) | §10 UI |

---

## 12. 里程碑 + 验收

| 里程碑 | 交付 | 验收标准 |
|---|---|---|
| **C1 解析 + 引擎节点** | ClashConfigParser + EngineNodeConverter(滤 ssr) | 样例解析出 150 节点,引擎返回 58 个有效 outbounds,报告"跳过 92 ssr" |
| **C2 组转换** | GroupConverter | 24 组转成 selector/urltest,成员引用完整,ssr 成员被剔除 |
| **C3 规则转换** | RuleConverter + ProviderMapper | 211 条规则转换/合并,`cn-domain`→geosite-cn,MATCH→final,未知项进报告 |
| **C4 组装 + 校验** | SingBoxAssembler + Validator | 产出完整 config.json,结构自检全过 |
| **C5 UI + 报告 + 图标 + 真机** | ConversionView + Report + icons.json | mac app 里导入样例→导出→**Nest 真机导入运行成功**,策略组/规则生效;icons.json 含各组图标 URL |

---

## 13. 风险

- **引擎 list 模式的字段完整度**:某些协议(vless reality、hy2 等)引擎 sing-box 输出字段是否齐全,需按实际输入抽测(样例只有 ss/trojan,风险低)。
- **规则集 srs 可用性**:远程 srs URL 失效则 Nest 启动时下载失败;对照表用 SagerNet 官方源较稳。
- **fake-ip-range 归一**:源 `198.18.0.1/16` 与模板 `198.18.0.0/15` 的等价性,以模板为准(已验证)。
- **临时文件含节点凭据**:引擎读的临时 Clash 文件含真实密码,用后即删,勿放共享/可联网目录(遵循既有隐私红线)。
