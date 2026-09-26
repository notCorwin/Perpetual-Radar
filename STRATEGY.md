可以把我们最近形成的思路概括成一句话：

> **先用 1h 价格结构发现真正发生突破/破位的币，再用 OI 判断有没有新增仓位进入，用 Taker 判断主动资金方向，用 VWAP/EMA200 判断位置与趋势质量，最后通过回踩、吸收和盘口确认决定这个突破值不值得追。**

它本质上不是“指标策略”，而是一个 **Structure → Positioning → Aggression → Acceptance** 的确认链。

## 1. 先明确：你的引擎应该找什么

你的目标不应该是每小时给所有币输出 `LONG/SHORT`。

更合理的是：

| 状态           | 含义                         |
| -------------- | ---------------------------- |
| `NONE`         | 没有值得关注的结构           |
| `WATCH_LONG`   | 出现向上异动，但证据不足     |
| `WATCH_SHORT`  | 出现向下异动，但证据不足     |
| `LONG_SETUP`   | 多头结构 + 衍生品资金确认    |
| `SHORT_SETUP`  | 空头结构 + 衍生品资金确认    |
| `LONG_RETEST`  | 突破后回踩确认，可重点关注   |
| `SHORT_RETEST` | 跌破后反抽确认               |
| `EXHAUSTED`    | 方向正确但已经过度延伸，不追 |
| `TRAP_RISK`    | OI/Taker/价格出现明显不协调  |
| `INVALIDATED`  | 原信号已经失效               |

这样比单纯输出“买/卖”更符合我们最近实际看盘的方式。

------

# 2. 第一层：交易池

首先获取：

```text
instType = SWAP
state = live
```

如果你主要做 USDT 永续，再限定：

```text
settleCcy = USDT
```

OKX 当前公共产品接口可以直接获得 SWAP 产品及 `groupId` 等信息；现行文档中 SWAP 的 RWA 分组包括 `groupId=6/7`。因此可以先据此排除 TradFi/RWA，不过 `groupId` 本质上是手续费分组字段，我不会把它作为永久可靠的资产分类接口，最好再保留一个 `is_tradfi` 分类层。([OKX](https://www.okx.com/docs-v5/zh/?utm_source=chatgpt.com))

OKX 现在确实已经存在股票永续，例如 AAPL、TSLA、NVDA 等，所以不能再简单认为 `SWAP == Crypto`。([OKX](https://www.okx.com/zh-hans/help/stock-perpetuals?utm_source=chatgpt.com))

因此：

```text
Universe
= Live SWAP
- TradFi
- RWA
- 盘前合约（可选）
- 流动性过低合约
```

------

# 3. 第二层：价格结构 —— 信号的起点

这是整个引擎最重要的一层。

**OI、Taker、RSI、ROC 都不应该自己产生方向。**

首先必须发生一个价格事件。

### 多头结构

定义过去 `N` 根已经完成的 1h K 线：

HHN=max⁡(Ht−N,...,Ht−1)

当前：

Ct>HHN

才叫：

```text
breakout_up = true
```

空头对称：

LLN=min⁡(Lt−N,...,Lt−1)Ct<LLN

得到：

```text
breakdown = true
```

这里一定要**排除当前 K 线本身**，否则逻辑会污染。

OKX 1H K线接口直接支持 `bar=1H`，而且返回 `confirm`，其中 `confirm=1` 表示这根 K 线已经完成。正式 1h 信号最好只使用完成 K 线；当前正在形成的 K 线可以产生 `WATCH`，但不要产生最终确认。([OKX](https://app.okx.com/docs-v5/zh/?utm_source=chatgpt.com))

------

# 4. 不要只看“突破了没有”，还要看突破质量

例如：

```text
0.100 → 0.1001
```

技术上也是新高，但毫无意义。

所以应该算：

BreakStrength=C−HHNATR14

向下则：

BreakStrength=LLN−CATR14

这样不同波动率的币可以比较。

比固定：

```text
突破 > 0.5%
```

合理得多。

因为 BTC 的 0.5% 和某个小山寨的 0.5% 完全不是同一种行情。

------

# 5. 第三层：OI —— 判断是谁推动价格

这是我们最近策略里最重要的衍生品变量。

OI 不是：

> 多头数量。

而是：

> 未平仓合约规模。

OKX 公共接口能够直接获得 `oi`、`oiCcy` 和 `oiUsd`，SWAP 也支持；WebSocket 的 open-interest 频道当前大约每 3 秒更新。([OKX](https://app.okx.com/docs-v5/zh/?utm_source=chatgpt.com))

引擎最好统一使用：

```text
oiUsd
```

然后聚合成 1h：

ΔOI=OIt−OIt−1OIt−1

### 我们最近一直在用的四象限

| Price | OI   | 更可能代表         | 信号意义                 |
| ----- | ---- | ------------------ | ------------------------ |
| ↑     | ↑    | 新仓进入上涨       | **高质量多头候选**       |
| ↑     | ↓    | 空头平仓 / squeeze | 上涨真实，但不宜机械追   |
| ↓     | ↑    | 新仓进入下跌       | **高质量空头候选**       |
| ↓     | ↓    | 多头平仓/清算      | 下跌真实，但容易进入衰竭 |

这解决了一个非常重要的问题：

> **价格涨 ≠ 新多正在进入。**

例如价格猛烈上涨，同时 OI 大幅下降，很可能主要是空头被迫退出。

这种行情当然可以继续涨，但它和：

```text
价格↑
OI↑
主动买盘↑
```

不是同一类突破。

后者才是我们更喜欢的 **participation-confirmed breakout**。

------

# 6. 第四层：Taker —— 谁在主动进攻

这是第二个核心。

OKX 公共成交数据明确返回：

```text
side = buy
side = sell
```

这个 `side` 是**吃单方向**，因此可以直接构建 Taker Buy / Sell。WebSocket `trades` 有成交就推送，因此实时引擎应该用 WS 聚合，而不是每小时靠 REST 拉最后 500 笔成交；高成交量品种的最后 500 笔显然不能代表整个小时。([OKX](https://app.okx.com/docs-v5/zh/?utm_source=chatgpt.com))

计算美元名义成交：

BuyVol=∑BuyNotionalSellVol=∑SellNotional

然后：

TakerDelta=BuyVol−SellVolBuyVol+SellVol

范围：

```text
-1 ~ +1
```

正值＝主动买占优。

负值＝主动卖占优。

------

# 7. 真正有价值的是 Price × OI × Taker

这是整个策略最核心的矩阵。

### 最干净的多头

```text
Price ↑
OI ↑
Taker Buy ↑
```

解释：

> 价格上涨，同时新增仓位进入，而且主动买家愿意扫卖单。

这是我们想找的典型趋势扩张。

### 最干净的空头

```text
Price ↓
OI ↑
Taker Sell ↑
```

表示：

> 新仓增加 + 主动卖出推动价格下行。

------

但还有几种特别重要的异常状态。

### Price ↑ + Buy Taker ↑ + OI 不涨

上涨可能主要来自：

```text
空头平仓
现有流动性被扫掉
```

不是最理想的追多。

### Price ↑ + OI ↑ + Buy Taker 很强，但价格越来越涨不动

这个比普通背离更重要：

> **主动买盘正在被 Maker Sell 吸收。**

也就是我们最近经常讨论的：

```text
有人疯狂买
但是价格不涨
```

此时绝对不能因为 Buy Taker 强就继续加多。

应该标记：

```text
BUY_ABSORPTION
```

### Sell Taker 很强，但价格就是跌不下去

反过来：

```text
大量主动卖
价格不创新低
```

意味着买方限价单正在吸收。

但我们最近已经明确：

> **“出现吸收”不能直接等于“马上做多”。**

应该等：

```text
Sell Taker 衰减
+
价格重新站回关键位置
+
Buy Taker 接管
```

才能升级成真正的反转信号。

这是非常重要的一条。

------

# 8. 第五层：VWAP —— Acceptance，而不是“必反弹线”

VWAP 最近对我们的作用已经比较明确。

不要把它写成：

```text
price < VWAP → long
price > VWAP → short
```

这会非常危险。

VWAP应该用于判断市场**是否接受当前价格区域**。

例如上涨趋势：

```text
突破新高
↓
回踩
↓
VWAP附近停止下跌
↓
重新站上VWAP
```

这个信号很漂亮。

可以定义：

VWAPDist=C−VWAPATR

这样可以识别两种东西：

### Healthy

```text
Price > VWAP
距离适中
VWAP上升
```

### Extended

```text
Price >> VWAP
```

虽然方向极强，但：

```text
chase_risk ↑
```

也就是：

> **强 ≠ 现在适合买。**

这是我们最近处理“追高吗？”问题时反复出现的核心。

------

# 9. EMA200 —— Regime，不是入场信号

EMA200适合回答：

> 当前大结构是顺风还是逆风？

而不是：

> 现在买不买？

例如：

```text
Price > EMA200
EMA200 slope > 0
```

多头信号加分。

反之：

```text
Price < EMA200
EMA200 slope < 0
```

空头加分。

但：

```text
价格突破 EMA200
```

本身不要产生交易信号。

更重要的是：

EMA200Slope=EMA200t−EMA200t−kATR

这样才能区分：

```text
真正上升趋势
```

与：

```text
价格恰好在一根横着的EMA200上面
```

------

# 10. ROC / MAROC 应该放在哪里

你昨天提出：

sign(ROC)=sign(MAROC)

且：

∣ROC∣>∣MAROC∣>Threshold

这个条件很适合作为 **Momentum Expansion Filter**。

例如多头：

```text
ROC > MAROC > threshold
```

空头：

```text
ROC < MAROC < -threshold
```

等价于你说的：

```text
同号
且
|ROC| > |MAROC| > threshold
```

含义大致是：

> 当前价格动量不仅方向明确，而且当前 ROC 比其平滑值更极端，即动量仍在扩张。

我不会把它放成一级触发器。

更适合：

```text
Breakout
+
OI confirmation
+
Taker confirmation
+
ROC expansion
```

中的最后一个加分项。

否则会出现：

```text
价格已经暴涨
ROC超级强
```

然后你的引擎恰好在最高点发出最强信号。

------

# 11. 我们为什么已经不喜欢“第一段直接追”

最近几次图里的共同问题都是：

```text
突然拉升
↓
突破
↓
指标全部变漂亮
↓
信号出现
↓
你追进去
↓
Maker Sell / 获利盘 / 新空
↓
价格被砸回来
```

所以应该明确区分：

### Breakout Signal

发现机会：

```text
WATCH_LONG
```

和：

### Entry-quality Signal

突破之后：

```text
没有迅速跌回突破位
+
OI没有异常塌陷
+
Taker结构仍健康
+
VWAP/突破位得到支撑
```

才变成：

```text
LONG_SETUP
```

而你现在的偏好显然更接近第二种。

也就是：

> **宁愿错过第一段，也不在加速末端无脑追。**

------

# 12. 回踩确认应该成为一等公民

建议直接在信号引擎里加入状态机。

假设：

```text
Resistance = 最近 N 小时最高价
```

突破：

```text
Price > Resistance
```

产生：

```text
BREAKOUT_PENDING
```

然后等待：

```text
Price 回到 Resistance 附近
```

如果：

```text
Low <= Resistance + tolerance
Close > Resistance
```

同时：

```text
OI 没有明显恶化
Sell Taker 没有持续压制
```

则：

```text
RETEST_CONFIRMED
```

这个状态对你应该比：

```text
BREAKOUT_NOW
```

重要得多。

------

# 13. 还必须识别“突破失败”

否则引擎会疯狂追假突破。

例如：

Ht>HHN

但：

Ct<HHN

就是典型：

```text
Failed Breakout
```

如果同时：

```text
OI↑
Buy Taker↑
```

反而更加危险。

因为这意味着：

> 有大量新仓和主动买盘进入，却无法维持突破。

可以标记：

```text
LONG_TRAP_RISK
```

如果随后出现：

```text
Lower High
+
跌破局部低点
+
Buy Taker衰减
```

才开始进入我们之前讨论的：

> **不是“因为涨很多所以做空”，而是“上涨失败以后做空”。**

空头完全对称。

------

# 14. 盘口大单应该降级成确认层

最近你几次看到：

```text
巨大卖单
把价格打回来
```

或者：

```text
巨大买墙
```

这类信息有用，但**不要作为 1h 一级信号**。

因为挂单可以撤。

真正值得关注的是：

```text
大墙存在
+
市场不断主动成交
+
墙没有立即撤走
+
价格确实无法穿透
```

也就是：

> persistence + executed volume + price response

而不是单纯：

```text
orderbook_size > X
```

因此架构最好是：

```text
1h Engine
    ↓
发现候选币
    ↓
开启该币的微观监控
    ↓
Trades + Orderbook
```

而不是全天给几百个币保存完整 orderbook。

------

# 15. OI/Taker 都不动的时候怎么办

这个也是我们最近遇到过的典型情况。

如果：

```text
Price明显变化
OI ≈ flat
TakerDelta ≈ neutral
```

你不能硬解释成：

```text
多头强
```

或者：

```text
空头强
```

更合理的状态是：

```text
LOW_DERIVATIVES_CONFIRMATION
```

价格可能主要受到：

```text
Maker liquidity
存量仓位
薄盘口
跨市场价格传导
```

影响。

这种行情直接降低信号等级。

------

# 16. 最好使用 Gate + Score，而不是一大串 AND

不要写成：

```text
breakout
AND OI > x
AND taker > y
AND price > VWAP
AND price > EMA200
AND ROC > MAROC
...
```

最终会变成一个几乎永远不触发的系统。

比较合理的是两层。

### Hard Gate

必须满足：

```text
非TradFi
+
足够流动性
+
真实价格结构事件
+
数据完整
```

不满足直接：

```text
NONE
```

然后才评分。

------

# 17. 我会这样设计第一版权重

| 模块            | 权重    | 判断                     |
| --------------- | ------- | ------------------------ |
| Price Structure | 30      | 突破、突破幅度、收盘位置 |
| OI              | 20      | OI变化是否确认方向       |
| Taker           | 15      | 主动成交是否确认         |
| VWAP / EMA200   | 15      | 位置和 regime            |
| Momentum        | 10      | ROC/MAROC、成交量扩张    |
| Microstructure  | 10      | 吸收、墙、回踩           |
| **总计**        | **100** |                          |

例如多头：

```text
85+     STRONG_LONG_SETUP
70–84   LONG_SETUP
55–69   WATCH_LONG
<55     NONE
```

但评分必须允许**惩罚项**。

例如：

```text
极度偏离VWAP       -15
OI暴增但价格不涨    -20
Buy Taker暴增但停滞 -20
假突破             -30
流动性过低          直接拒绝
```

这个比只加分好很多。

------

# 18. 一个比较接近我们现在逻辑的 LONG

```text
① 结构
Close > Previous_N_Hour_High

② 突破不是噪声
BreakStrength > MinBreakStrength

③ 新资金确认
OIChange > MinOIChange

④ 主动资金确认
TakerDelta > MinTakerDelta

⑤ Regime
Close > VWAP
EMA200Slope >= MinTrend

⑥ 动量可选
ROC 与 MAROC 同号
|ROC| > |MAROC| > MomentumThreshold

⑦ 不允许明显过热
VWAPDistance < MaxVWAPDistance

⑧ 无明显吸收异常
NOT (
    BuyTaker very strong
    AND PriceEfficiency very low
)

=> WATCH_LONG / LONG_SETUP
```

SHORT 全部镜像即可。

------

# 19. 我建议额外增加一个非常重要的指标：Price Efficiency

它可以系统化我们最近一直靠肉眼判断的：

> “Taker这么强，怎么价格就是不动？”

定义：

Efficiencybuy=PriceChangeBuyTakerNotional

实际实现不要直接用这个绝对值，而是对同一个币做滚动标准化。

例如：

```text
Buy Taker = +3σ
Price Return = +0.1σ
```

这显然不正常。

说明大量主动买盘没有获得对应的价格推进。

标记：

```text
SELL_SIDE_ABSORPTION
```

反过来：

```text
Sell Taker = +3σ
价格却跌不下去
```

就是：

```text
BUY_SIDE_ABSORPTION
```

我认为这个特征会比单纯 RSI 超买/超卖有价值得多。

------

# 20. 同样建议标准化 OI

不要写：

```text
OI上涨1% = 强
```

不同币完全不能这样比较。

可以同时计算：

```text
oi_change_1h
oi_change_3h
oi_zscore
```

例如：

OIz=ΔOI−μΔOIσΔOI

于是：

```text
OI +0.8%
```

在 BTC 可能已经明显异常；

在某些小币可能只是正常噪声。

------

# 21. 成交量也一样

推荐：

```text
volume_ratio =
1h_volume / MA(volume, N)
```

或者直接：

```text
volume_zscore
```

这样才能找到：

> **当前这一小时真的发生了异常参与。**

否则一个成交额本来就很大的币永远排在前面。

------

# 22. 最终我认为你的 signal object 应该长这样

```json
{
  "symbol": "XXX-USDT-SWAP",
  "timeframe": "1H",

  "direction": "LONG",
  "state": "RETEST_CONFIRMED",

  "structure": {
    "breakout": true,
    "lookback": 24,
    "break_strength_atr": 0.42
  },

  "oi": {
    "change_1h": 0.018,
    "zscore": 2.1,
    "confirmation": true
  },

  "taker": {
    "delta": 0.31,
    "zscore": 1.8,
    "confirmation": true
  },

  "trend": {
    "above_vwap": true,
    "vwap_distance_atr": 0.62,
    "above_ema200": true,
    "ema200_slope": 0.14
  },

  "momentum": {
    "roc": 4.2,
    "maroc": 2.1,
    "expanding": true
  },

  "flags": {
    "overextended": false,
    "absorption": false,
    "oi_divergence": false,
    "failed_breakout": false
  },

  "score": 82
}
```

我尤其建议**保存每个子条件，而不只是保存最终 score**。

以后回测时你才能回答：

> 是 OI 过滤有效？

还是：

> VWAP 有效？

还是：

> ROC/MAROC 根本没有增益？

------

# 23. 数据层我会这样分

```text
OKX Instruments
      ↓
Universe Manager
      ↓
1H Candles ────────── Structure
      │
      ├─ EMA200
      ├─ VWAP
      ├─ ATR
      ├─ ROC/MAROC
      └─ Volume
             ↓
Open Interest WS ─── Positioning
             ↓
Trades WS ────────── Taker Flow
             ↓
Signal Engine
             ↓
Candidate
             ↓
Orderbook / Microstructure
             ↓
Final Signal
```

OKX 的 WS 成交频道可以实时取得 taker 方向；OI 也有公共 WS，因此这套架构并不需要通过网页数据反爬，可以直接建立在原生 API 上。([OKX](https://app.okx.com/docs-v5/zh/?utm_source=chatgpt.com))

------

# 24. 最后，把最近策略压缩成几个原则

1. **价格结构先于指标。**
2. **突破必须问：OI 有没有新增资金？**
3. **OI 增加还不够，要问 Taker 谁在主动进攻。**
4. **主动买很多但涨不动，不是多头强，是潜在吸收。**
5. **主动卖很多但跌不动，也不能立即抄底；等卖压衰减和买方重新接管。**
6. **VWAP 是位置和接受度，不是“跌破必反弹”。**
7. **EMA200 是 regime filter，不是买卖按钮。**
8. **ROC/MAROC 更适合确认动量扩张，而不是产生信号。**
9. **不追第一段加速；突破→回踩→确认是我们更偏好的结构。**
10. **价格 + OI + Taker 不一致时，优先认为信号质量下降，而不是强行解释。**
11. **订单簿大墙只有在持续存在并真正吸收成交时才有价值。**
12. **信号强度和仓位/杠杆必须解耦。**

所以如果让我给这个 1h 引擎定一个真正的核心公式，它不是 RSI、ROC 或 VWAP，而是：

Signal=Structure×Participation×Aggression×Acceptance−Exhaustion−Divergence

其中：

```text
Structure      = 突破 / 破位 / 回踩
Participation  = OI
Aggression     = Taker
Acceptance     = VWAP + 价格能否站住
Exhaustion     = 过度延伸
Divergence     = OI/Taker/Price 不协调
```

这基本就是我们最近几天看图时逐渐收敛出来的交易逻辑。对你的 **1h 全市场非 TradFi 永续扫描器** 来说，我认为最重要的改变是：**不要让引擎寻找“指标最强的币”，而是寻找“价格正在发生结构变化，而且衍生品资金能够解释这个变化的币”。**