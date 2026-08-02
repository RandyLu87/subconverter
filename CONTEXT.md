# Subconverter + clashconvert

订阅转换：把一或多个机场订阅合并成一份可直接使用的 Clash / sing-box 配置。C++ 引擎只负责把各种协议解析成统一的节点列表；策略组与规则的组织方式由 macOS app 决定。

本词汇表只收录本项目特有的概念。协议名（AnyTLS、Hysteria2…）与 Clash 自身的配置字段（`proxy-groups`、`url-test`…）属于外部既有概念，不在此列。

## Language

**Node**:
一个可用的代理出口，来自某个订阅来源。产物中以唯一名称标识。
_Avoid_: Proxy, server, 线路

**Source**:
一份用户添加的订阅，合并时按 `order` 保序。
_Avoid_: Subscription, provider, 机场

**Self-built node**（自建节点）:
名称包含「自建」二字的 Node。判定依据只有名称，与来自哪个 Source 无关；名称不含该关键词的自建机器不被视为 Self-built node。
_Avoid_: Self-hosted node, 私有节点, 家宽

**Self-built group**（自建组）:
汇集全部 Self-built node 的手选组，组名即「自建」。无 Self-built node 时整组不生成。

**Country auto group**（地区分组）:
按节点名称正则分桶得到的自动测速组（`🇭🇰 Hong Kong Auto` … `🌍 Other Countries Auto`）。**不含** Self-built node —— 后者只经由 Self-built group 出现。某地区的候选节点全部为 Self-built node 时，该组不生成。
_Avoid_: Region group, 国家组；注意本词**不指**策略组末尾的 Flat node list

**Policy group**（策略组）:
按用途划分的手选组（OpenAI、Netflix、Apple…），是规则命中后的落点。候选项依次为 `Default`、`DIRECT`、Country auto group、Self-built group、Flat node list。
_Avoid_: Rule group, 分流组

**Default group**:
兜底 Policy group，不引用其他 Policy group，供其余各组选中以共享同一出口。

**Flat node list**（平铺列表）:
每个手选组候选项末尾的全量 Node 清单，含 Self-built node。它的存在是为了能在不同 Policy group 里分别指定不同的具体节点。
