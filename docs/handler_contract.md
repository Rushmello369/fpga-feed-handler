# Handler 数据与特征合同

**状态：已冻结。**

本文档固定 `feature/feed_handler` 分支形成的 ITCH 5.0 行情处理、订单簿、特征提取和板间输出语义。后续 ML 数据生成、模型训练、QAT、FINN 输入以及 Pynq Z1 接收逻辑均以本文档为准。

冻结基线：

- Git commit：`f908f8493a58e634c47f98a84063bd059866d8bd`
- RTL 顶层：`hardware/ax7a200b/rtl/ITCH50_parser/top_v2.sv`
- 特征 RTL：`hardware/ax7a200b/rtl/ITCH50_parser/feature_engine.sv`
- 板间发送：`hardware/ax7a200b/rtl/ITCH50_parser/board_link-tx.sv`
- 软件 golden model：`hardware/ax7a200b/src/itch_tools.py`

若文档、RTL 和软件模型出现差异，不允许任选一份继续开发。必须在同一个变更中同步修改本文档、RTL、golden model 和相应 testbench。

## 1. 输入协议

关键路径输入采用 NASDAQ TotalView-ITCH 5.0，而不是旧版自定义 FM24。

历史文件采用以下 framing：

```text
[2-byte big-endian body length][ITCH message body]
```

当前订单簿链路处理：

- `A`：Add Order
- `F`：Add Order with MPID
- `E`：Order Executed
- `C`：Order Executed with Price
- `X`：Order Cancel
- `D`：Order Delete
- `U`：Order Replace

`S`、`R` 等管理类消息可以被解析或用于标定，但不更新订单簿。未知消息计数后跳过。

当前实现按单一 `stock_locate` 过滤。`stock_locate` 是逐日分配值，不得跨交易日硬编码复用。

## 2. 价格、数量与订单簿

- ITCH `Price(4)`：实际美元价格乘 `10000` 的无符号整数。
- 股票最小价格 tick：`TICK_SIZE = 100`，即 0.01 美元。
- 价格窗口地址：

```text
level = (price - BASE_PRICE) / TICK_SIZE
```

- `BASE_PRICE`、`WINDOW_SIZE` 和 `FILTER_LOCATE` 必须针对交易日与股票重新标定。
- 超出价格窗口的更新被丢弃，并增加 `oow_count`。
- 数量使用原始 shares。进入数量类特征前执行算术右移 `QTY_SHIFT`。
- `QTY_SHIFT` 必须同时记录在 bitstream 配置、golden 数据和模型实验元数据中。

订单状态由 `order_lookup` 的直接映射表维护。索引使用 `order_id` 低 `TABLE_BITS` 位；发生索引冲突时新订单覆盖旧订单。软件 golden model必须复现该行为，不能用无限容量字典替代。

## 3. 特征采样

每次订单簿成功更新后产生一次候选 TOB 快照。只有 bid 和 ask 同时有效时才输出 `feat_valid`。

Replace 事件拆成“删除旧订单”和“插入新订单”两个订单簿更新，因此可能输出两条特征。

六维向量顺序固定为：

```text
[spr, tobi, ofi, emadev, mom, tflow]
```

全部输出为 `signed int16`。中间计算使用 32 bit，有符号结果通过以下规则饱和：

```text
x >  32767 ->  32767
x < -32768 -> -32768
otherwise  -> x
```

## 4. 特征定义

设：

```text
bidq = signed(bid_qty) >>> QTY_SHIFT
askq = signed(ask_qty) >>> QTY_SHIFT
mid2 = bid_idx + ask_idx
```

`mid2` 保留半 tick 精度，没有 `>> 1`。因此 `emadev` 和 `mom` 的 1 个整数单位表示半个价格 tick。

### 4.1 SPR

```text
spr = sat16(ask_idx - bid_idx)
```

单位为价格 tick。

### 4.2 TOBI

```text
tobi = sat16(bidq - askq)
```

使用数量差，不做比例除法。

### 4.3 OFI

```text
ofi = sat16((bidq - prev_bidq) - (askq - prev_askq))
```

复位后 `prev_bidq = 0`、`prev_askq = 0`，所以第一条有效特征的 `ofi` 等于第一条 `tobi`，不是 0。

### 4.4 EMADEV

EMA 状态保留 4 个小数位：

```text
first sample:
    ema_frac = mid2 << 4
    emadev = 0

later samples:
    ema_int = ema_frac >>> 4
    emadev = sat16(mid2 - ema_int)
    ema_frac = ema_frac + (((mid2 << 4) - ema_frac) >>> 4)
```

右移均为算术右移。

### 4.5 MOM

```text
mom = sat16(mid2(t) - mid_history[7])
```

历史深度为 8，复位时 8 个历史槽均为 0。每次输出后将当前 `mid2` 移入历史。因此启动后的前 8 条特征会与 0 比较；从第 9 条开始才是严格的 `t` 与 `t-8` 差值。

### 4.6 TFLOW

只在 `E` 和 `C` 成交事件上更新最近 16 笔成交的环形窗口：

```text
resting sell 被成交 -> aggressive buy  -> +qty
resting buy  被成交 -> aggressive sell -> -qty

tflow = sat16(tflow_acc >>> QTY_SHIFT)
```

Cancel、Delete 和 Replace 本身不计为成交。

## 5. 板间输出

特征通过 15 字节大端帧输出。完整帧格式、握手和丢帧诊断定义见 [`board_link_spec.md`](board_link_spec.md)。

Pynq Z1 接收端必须在进入 FINN 前还原为顺序一致的六个 `signed int16`。

## 6. 软件 golden model

`hardware/ax7a200b/src/itch_tools.py` 是当前唯一有效的软件参考实现。

标准工作流：

```text
python hardware/ax7a200b/src/itch_tools.py calibrate <itch-file> --ticker AAPL
python hardware/ax7a200b/src/itch_tools.py filter <itch-file> --locate <N> --out stream.bin
python hardware/ax7a200b/src/itch_tools.py golden <itch-file> --locate <N> \
  --base <BASE_PRICE> --window <WINDOW_SIZE> --qty-shift <QTY_SHIFT> \
  --table-bits 14 --out frames.csv
python hardware/ax7a200b/src/itch_tools.py selftest
```

训练数据不得使用 `ml/features/reference_features.py` 生成。该文件只保留用于旧 FM24 原型的历史测试。

`golden --out` 导出的每条 feature frame 必须保留原始 ITCH 事件的 6 字节
timestamp，CSV 字段名为 `timestamp_ns`，含义为当日午夜以来的纳秒数。Replace
事件产生的两条 feature frame 使用同一个事件时间戳。

正式训练特征数据通过 `ml/data/build_itch_dataset.py` 生成。该脚本必须直接复用
本节定义的 Golden model，并为每个 CSV 同时保存包含 handler commit、窗口参数、
`QTY_SHIFT`、`TABLE_BITS`、消息计数、越界计数和 lookup miss 的 metadata JSON。
构建器不得复制或重新实现特征公式。

## 7. 变更规则

以下任一内容发生变化时，必须视为接口变更：

- 特征顺序、定义、位宽、单位或初始化；
- `QTY_SHIFT`、`TABLE_BITS` 或窗口标定方式；
- 输出采样时机；
- 板间帧布局、字节序、校验或丢帧策略；
- golden model 的订单冲突和事件处理语义。

接口变更至少需要同步更新：

1. 本文档；
2. RTL；
3. `itch_tools.py`；
4. feature 与 board-link testbench；
5. ML 数据版本和训练配置。
