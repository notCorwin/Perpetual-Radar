# 永续合约雷达

## 需求

1. 交易所：OKX
2. 合约种类：所有非 TradFi USDT 永续合约
3. 交易周期：1 小时
4. 交互方式：滚动列表，实时排序潜力合约。

## 技术栈

始终使用最新的稳定版本。

1. AppKit / WebKit（不要用 SwiftUI）
2. Python
3. WebSocket

## 筛选思路

### 多头结构

定义过去 `N` 根已经完成的 1h K 线：

$$
HH_N = \max(H_{t-N}, \ldots, H_{t-1})
$$

当

$$
\mathrm{BreakStrength}_{\mathrm{up}} = \frac{C_t - HH_N}{\mathrm{ATR}_{14}}
$$

时，多头突破。

### 空头结构

同理：
$$
LL_N = \min(L_{t-N}, \ldots, L_{t-1})
$$

当

$$
\mathrm{BreakStrength}_{\mathrm{down}} = \frac{LL_N - C_t}{\mathrm{ATR}_{14}}
$$

时，空头突破。

### OI

定义:

$$
\mathrm{OI}_{\mathrm{log}} = \ln\left(\frac{\mathrm{OI}_t}{\mathrm{OI}_{t-1}}\right)
$$

因此：

$$
\mathrm{Direction} = \mathrm{sign}(\mathrm{OI}_{\mathrm{log}})
$$

$$
\mathrm{Magnitude} = |\mathrm{OI}_{\mathrm{log}}|
$$

## Taker

定义：

$$
\mathrm{BuyVol} = \sum \mathrm{BuyNotional}
$$

$$
\mathrm{SellVol} = \sum \mathrm{SellNotional}
$$

然后：

$$
\mathrm{TakerDelta} = \frac{\mathrm{BuyVol} - \mathrm{SellVol}}{\mathrm{BuyVol} + \mathrm{SellVol}}
$$
正值为主动买方占优，负值为主动卖方占优。