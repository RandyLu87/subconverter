# subconverter

一个面向个人使用的 Clash 配置整套生成方案。基于 [tindy2013/subconverter](https://github.com/tindy2013/subconverter) 引擎，在其之上提供了：

- 一份精心维护的 Clash Meta 规则模板（GEOSITE/GEOIP 驱动，五大区域 fallback，含冷门节点分组）
- 一个 macOS GUI 应用 **clashconvert**（SwiftUI），用于本地一键合并多订阅、生成 Clash YAML
- 一个 shell 脚本工作流，适合 OpenClash / 自动化场景
- 自定义直连白名单、节点清洗关键词、emoji 命名、AnyTLS 支持等增强

不需要把订阅地址交给任何第三方在线转换服务 —— 全部在本机完成。

## 仓库结构

```
.
├── mac-app/                 # SwiftUI macOS 应用 clashconvert
│   └── SubConfigStudio/     # 应用源码（Views / Services / Models）
├── src/
│   ├── subconverter/        # subconverter C++ 引擎源码（上游 fork）
│   └── openclash/           # OpenClash / shell 脚本工作流
│       └── shell/generate.sh
└── subconverter/            # 引擎运行时目录（可执行文件 + 模板 + 规则集）
    ├── subconverter         # 编译好的引擎二进制
    ├── metaconfig.ini       # 主要的 Clash Meta 模板（方案 A）
    ├── direct-whitelist.list # 自定义直连白名单
    ├── pref.example.toml    # 引擎 preference 模板
    ├── profiles/            # 配置 profile
    ├── rules/               # ACL4SSR / DivineEngine / lhie1 / NobyDa 等规则集
    └── snippets/            # groups / emoji / rename_node 等代码片段
```

## 三种使用方式

### 1. macOS 应用：clashconvert

可视化管理多个订阅源，本地启动引擎，一键合并生成 Clash YAML。

界面分三栏：

- **Sources** —— 添加订阅 URL 或导入本地 Clash YAML，可启用 / 排序 / 删除
- **Presets** —— 选择内置模板与自定义直连规则
- **Preview** —— 实时预览生成的 YAML，含节点数统计与生成时间

应用启动时会自动管理 subconverter 引擎进程（`EngineController.start`），通过本地 HTTP `127.0.0.1:25500` 调用 `/sub`，生成完毕后做 YAML 后处理（节点国家分类、合并去重、emoji 命名）。

构建运行：

```bash
open mac-app/SubConfigStudio.xcodeproj
# 在 Xcode 中选择 SubConfigStudio scheme 运行
```

打包 DMG：

```bash
mac-app/scripts/package_dmg.sh
# 产物：mac-app/build/clashconvert.dmg
```

### 2. Shell 脚本

适合服务器、OpenClash、cron 自动化等无 GUI 场景。

```bash
cd src/openclash/shell
cp config.yaml.example config.yaml
# 编辑 config.yaml 填写订阅地址、输出路径等
./generate.sh
```

脚本会自动：

1. 检测本地 `127.0.0.1:25500` 是否已有 subconverter 服务，没有则启动
2. 读取 `config.yaml` 中的订阅地址、模板、排除关键词等
3. URL 编码后请求 `/sub` 接口
4. 保存生成的 Clash YAML 到指定路径

依赖：`yq`（`brew install yq`）、`curl`、`python3`。

`config.yaml` 字段说明：

| 字段 | 说明 |
| --- | --- |
| `serviceUrl` | 引擎接口地址，默认 `http://127.0.0.1:25500/sub` |
| `targetUrl` | 机场订阅链接（多订阅用 `\|` 分隔） |
| `config` | 模板路径或远程 URL，默认指向本仓库的 `metaconfig.ini` |
| `output` | 输出文件路径（支持相对路径） |
| `target` | 目标格式：`clash` / `clashr` / `surge` / `quanx` / ... |
| `exclude` | 节点排除正则（清洗机场广告节点） |
| `emoji` | 节点名前添加国旗 emoji |
| `udp` | 启用 UDP |
| `scv` | 跳过证书验证 |

### 3. 直接调用引擎

如果你只想用纯净的 subconverter HTTP API：

```bash
cd subconverter
./subconverter
# 默认监听 127.0.0.1:25500
```

然后访问：

```
http://127.0.0.1:25500/sub?target=clash&url=<URL编码后的订阅地址>&config=<模板路径>
```

完整参数请参考上游 [subconverter README](https://github.com/tindy2013/subconverter)。

## 模板定制：metaconfig.ini

`subconverter/metaconfig.ini` 是核心模板，决定生成的 Clash YAML 长什么样：

- **规则优先级**：私网 → 国内（GEOSITE/GEOIP cn）→ 广告拦截 → Apple/Google/Microsoft 等服务 → 各应用代理 → 漏网之鱼
- **节点分组**：HK / TW / JP / SG / US 五大区域 fallback，外加 `🧊 冷门节点`（排除以上五个地区）
- **节点清洗**：通过 `exclude=` 正则过滤"流量/到期/防失联/官网"等机场广告节点
- **直连白名单**：`direct-whitelist.list` 中可加 `DOMAIN-SUFFIX,xxx.com` 自定义直连

如需调整分组、规则、应用代理策略，直接编辑 `metaconfig.ini` 即可。

## 支持的协议

继承 subconverter 上游全部支持，并在本仓库中增补了 **AnyTLS** 订阅解析。常见的有：

Clash / Clash Meta / Surge 2/3/4 / Quantumult X / Loon / Surfboard / V2Ray / SS / SSR / Trojan / Hysteria / TUIC / AnyTLS

## 致谢

- [tindy2013/subconverter](https://github.com/tindy2013/subconverter) —— 核心转换引擎
- [ACL4SSR](https://github.com/ACL4SSR/ACL4SSR)、[DivineEngine](https://github.com/DivineEngine/Profiles)、[lhie1](https://github.com/lhie1/Rules)、[NobyDa](https://github.com/NobyDa/Script) —— 规则集

## 许可

引擎部分遵循上游 subconverter 的 GPL-3.0 协议（见 `src/subconverter/LICENSE`）。
