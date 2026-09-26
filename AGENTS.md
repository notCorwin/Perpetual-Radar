# Perpetual Swap Radar

## 需求

1. 平台：macOS 原生应用
2. 交易所：OKX
3. 合约种类：所有非 TradFi USDT 永续合约
4. 交易周期：1 小时
5. 交互方式：列表，实时排序潜力合约。
6. 网页语言：仅英文
7. 本地持续存储已固定的数据，并自动清理过时数据；运行时数据保留在内存。

## 技术栈

始终使用最新的稳定版本。

1. Swift
2. WebKit
3. AppKit
4. SQLite
5. shadcn/ui
6. Tailwind CSS
7. WebSocket

## UI/UX

1. 优先采用 shadcn/ui 提供的组件实现。
2. Design Token 是唯一的视觉设计规范。
3. 样式主要通过 Tailwind CSS 实现。
4. 组件本身不得形成彼此独立的视觉规范。

## 特殊需求

1. 不再使用 Python 作为后端。
2. 不再启动本地 Web Server。
3. 使用 Swift 原生能力。
4. 此项目不应该表现为传统网页或浏览器。
