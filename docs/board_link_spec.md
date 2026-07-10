# 板间链路协议规格（AX7A200B ↔ Pynq Z1）

**状态：Feature Vector v0 已定稿；物理链路、帧格式和 CDC 方案待 EEE 侧继续细化。**

这是 PROJECT_PLAN 阶段 1（协议与基线）里 EEE 和 CS 双方需要共同维护的接口文档。CS 侧模型输入、QAT/FINN 编译输入，以及 EEE 侧 `feature_extract` / `board_link_tx` 输出必须以本文档为准。

## Feature Vector v0

v0 先定义 6 个特征，目标是同时能从 ITCH/FM24 风格订单簿事件和带 TOB/depth 的 Binance 数据中生成。仅有 Binance `aggTrades` 时只能直接计算 `trade_flow_16`，不能完整计算 `spread`、TOB 失衡、OFI、EMA 偏离和动量，因为这些特征需要 `best_bid`、`best_ask`、`bid_qty`、`ask_qty`。

| Index | Name | Definition | Type v0 | 说明 |
|---:|---|---|---|---|
| 0 | `spread` | `ask - bid` | `int32 signed` | 价格类特征，单位为价格 tick |
| 1 | `tob_imbalance` | `bid_qty - ask_qty` | `int32 signed` | TOB 数量差值版失衡，不在 RTL 中做除法归一化 |
| 2 | `ofi` | `delta_bid_qty - delta_ask_qty` | `int32 signed` | `delta_*` 相对上一条已输出 feature vector 的 TOB 数量变化 |
| 3 | `ema_deviation` | `mid - ema(mid)` | `int32 signed` | `ema` 使用 `alpha = 1/16`，移位实现 |
| 4 | `momentum_8` | `mid(t) - mid(t-8)` | `int32 signed` | `t` 按已输出 feature vector 计数 |
| 5 | `trade_flow_16` | `active_buy_qty_sum - active_sell_qty_sum` | `int32 signed` | 最近 16 笔成交的主动买量减主动卖量 |

向量顺序固定为：

```text
[spread, tob_imbalance, ofi, ema_deviation, momentum_8, trade_flow_16]
```

## 采样与更新节奏 v0

- `feature_extract` 在订单簿/成交事件更新后输出一条 feature vector。
- `momentum_8` 的 `t-8` 指前 8 条已输出 feature vector，不是固定 8 秒或 8 个时钟周期。
- `trade_flow_16` 的窗口按最近 16 笔成交计数，不按固定时间长度计数。
- 若某条事件只更新 TOB 而没有成交，`trade_flow_16` 保持当前滑窗值；若某条事件包含成交，则先更新成交滑窗再输出 feature vector。
- v0 只有在 best bid 和 best ask 都有效时输出 feature vector；启动阶段单边 book 未形成时不输出有效 feature。
- 第一条有效 feature vector 用于初始化 `ema`、`momentum_8` 历史和 OFI 历史：`ema_deviation = 0`、`momentum_8 = 0`、`ofi = 0`。

## ITCH/FM24 事件语义 v0

v0 使用仓库内 [`protocol_spec.md`](protocol_spec.md) 定义的 FM24 消息作为 ITCH 风格事件输入。FM24 是 24 字节定长消息，字段包括 `msg_type`、`side`、`symbol_id`、`order_id`、`price`、`qty`、`exec_qty`、`seq`。

### 通用规则

- `side` 表示被更新的订单簿挂单侧，不表示主动方：
  - `BID` / `BUYER` / `0x00`：更新 bid book；
  - `ASK` / `SELLER` / `0x01`：更新 ask book。
- `price` 使用 FM24 整数价格格式，即实际价格乘 `PRICE_SCALE = 100` 后的整数。
- `qty` 使用订单簿内部整数数量单位。v0 不使用浮点数量。
- `seq` 必须单调加 1；v0 golden data 和训练数据默认不包含丢包序列。
- `order_id` 保留在消息中用于协议兼容，但 v0 特征提取按 `side + price` 聚合维护 price level，不依赖 order-level book。若 v1 需要真实 order-level cancel/execute，再引入 `order_id` 状态表。
- `exec_qty` 在 v0 特征链路中保留但不参与 `feature_extract`，golden data 中建议置 0。EXECUTE 的成交/扣减数量使用 `qty` 字段。

### `ADD`

```text
book[side, price] += qty
```

- `ADD` 表示在 `side/price` 上新增挂单数量。
- `exec_qty` 必须为 0。
- `ADD` 不更新 `trade_flow_16`，因为没有成交主动方向。

### `CANCEL`

```text
book[side, price] = max(book[side, price] - qty, 0)
```

- `CANCEL` 的 `qty` 表示取消数量，不是取消后的剩余数量。
- 如果取消数量大于当前 price level 数量，v0 饱和到 0，不产生负数量。
- `CANCEL` 不更新 `trade_flow_16`。

### `EXECUTE`

```text
book[side, price] = max(book[side, price] - qty, 0)
```

- `EXECUTE` 的 `qty` 表示成交数量，并同时作为订单簿扣减数量。
- `EXECUTE` 会更新 `trade_flow_16`：
  - `side = ASK` / `SELLER` 表示 resting ask 被打掉，主动方为买方，计入 `active_buy_qty`；
  - `side = BID` / `BUYER` 表示 resting bid 被打掉，主动方为卖方，计入 `active_sell_qty`。
- `EXECUTE` 后先更新 book 和成交滑窗，再基于更新后的 TOB 输出 feature vector。

## 数值格式 v0

- v0 板间导出的 6 个特征统一使用 `int32 signed`，便于先完成 CS/EEE 对齐和 Python/RTL golden comparison。
- 价格类特征使用整数 tick，不使用浮点。FM24 当前价格字段为实际价格乘 `PRICE_SCALE = 100` 后的整数，因此 `spread`、`ema_deviation`、`momentum_8` 默认沿用该整数价格单位。
- 数量类特征使用订单簿引擎内部的整数数量单位。CS 侧训练数据必须记录对应的数量 scale，并在模型输入归一化或 QNN 输入层量化 scale 中吸收。
- 导出到板间链路前使用 saturating arithmetic；发生溢出时饱和到 `int32` 最大/最小值，不 wrap。
- v0 不在 RTL 特征层做均值方差归一化、除法归一化或 z-score；CS 侧通过训练数据统计量、Brevitas/QAT scale 或 FINN 输入量化处理。

## 特征计算细节 v0

### `mid`

```text
mid = (bid + ask) >> 1
```

`bid` 和 `ask` 均为整数 tick。若 `(bid + ask)` 为奇数，v0 使用右移截断。

### `ofi`

```text
delta_bid_qty = bid_qty(t) - bid_qty(t-1)
delta_ask_qty = ask_qty(t) - ask_qty(t-1)
ofi = delta_bid_qty - delta_ask_qty
```

v0 的 `t-1` 指上一条已输出 feature vector。若 best bid/ask 价格变化，仍按新旧 TOB 数量直接做差；这一规则简单、RTL 成本低，后续如需经典 OFI 价格跳变规则再升到 v1。

### `ema_deviation`

```text
ema_0 = first_mid
ema_t = ema_{t-1} + ((mid_t - ema_{t-1}) >> 4)
ema_deviation = mid_t - ema_t
```

右移使用 arithmetic shift。`alpha = 1/16`，不使用乘法器。

### `momentum_8`

```text
momentum_8 = mid_t - mid_{t-8}
```

启动阶段未满 8 条 feature vector 时，`mid_{t-8}` 使用当前可用的最早 `mid`。

### `trade_flow_16`

```text
trade_flow_16 = sum(active_buy_qty, latest 16 trades)
              - sum(active_sell_qty, latest 16 trades)
```

ITCH/FM24 映射：

- `EXECUTE` 且 `side = ASK` / `SELLER` 表示主动买；
- `EXECUTE` 且 `side = BID` / `BUYER` 表示主动卖。

Binance `aggTrades` 仅用于辅助 EDA 或临时 trade-flow 实验时，映射为：

- `is_buyer_maker = False` 表示主动买；
- `is_buyer_maker = True` 表示主动卖。

## 模型输出 v0

CS 侧初代 baseline 和 QNN 先按三分类决策：

```text
-1 = sell / short bias
 0 = hold / no action
+1 = buy / long bias
```

FINN 输出可以是 3 类 score/logit，经 argmax 后编码为 `2 bit decision` 返回 AX7A200B：

| Decision code | Meaning |
|---:|---|
| `0b00` | hold |
| `0b01` | buy |
| `0b10` | sell |
| `0b11` | reserved |

最终是否返回 score 还是只返回 decision，由 Pynq Z1 FINN overlay 与 AX7A200B 风控/订单模块联调时定稿。

## 后续仍需定稿

- [ ] 物理接口：优先用 Pynq Z1 的 PMOD/Arduino 排针 + 自定义并行/串行协议，**不走板载以太网**（否则会经过 Linux 网络栈，延迟数字失去说服力，详见 PROJECT_PLAN）
- [ ] 帧格式：起始/结束标记、握手信号、每周期传输的 bit 数、feature vector 打包顺序
- [ ] 时钟域穿越（CDC）方案：两板时钟不同源，跨时钟域信号必须做同步处理
- [ ] v1 是否需要逐字段收窄位宽，例如 `spread` 用 `uint16`、数量差分用 `int24`
- [ ] 是否需要把模型 score 一并返回给 AX7A200B，还是只返回 argmax decision

## 对应 RTL 占位

- `hardware/ax7a200b/rtl/feature_extract/`（特征提取，AX7A200B 侧，未开始）
- `hardware/ax7a200b/rtl/board_link_tx/`（发送端，AX7A200B 侧，未开始）
- `hardware/pynq_z1/rtl/board_link_rx/`（接收端，Pynq Z1 侧，未开始，接入 FINN 输入前的 glue logic）
