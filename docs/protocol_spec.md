# FM24 消息格式规格

自定义的 24 字节仿 ITCH 行情消息格式，RTL 侧定义见 [`hardware/ax7a200b/rtl/fm24_pkg.sv`](../hardware/ax7a200b/rtl/fm24_pkg.sv)，Python 侧对应模型见 [`hardware/ax7a200b/src/fm24.py`](../hardware/ax7a200b/src/fm24.py)——两边字段必须保持一致，改一边时记得同步改另一边。

## 消息布局（24 字节 / 192 bit，大端）

| 偏移 | 字段 | 位宽 | 说明 |
|---|---|---|---|
| 0x00 | msg_type | 8 bit | `0x01`=ADD, `0x02`=CANCEL, `0x03`=EXECUTE |
| 0x01 | side | 8 bit | `0x00`=BID(buyer), `0x01`=ASK(seller) |
| 0x02 | symbol_id | 16 bit | |
| 0x04 | order_id | 32 bit | |
| 0x08 | price | 32 bit | 实际价格 × `PRICE_SCALE`(=100) 后的定点整数 |
| 0x0C | qty | 32 bit | |
| 0x10 | exec_qty | 32 bit | ADD 消息必须为 0 |
| 0x14 | seq | 32 bit | 序列号，必须 ≥ 1，用于检测丢包 |

## 价格窗口

`book_update` 用 BRAM 维护一个固定价格窗口，而不是全价格范围：

- `BASE_PRICE = 14500`（×100 定点，即 145.00）
- `WINDOW_SIZE = 1024` 个价位
- 超出窗口的价格当前会被丢弃/报错（`fm24_err_t.parse_error`），这个限制以后如果要支持更宽价格范围需要重新设计

## 待补充

- [ ] 特征向量格式定稿后加到 [`board_link_spec.md`](board_link_spec.md)（这是和 CS 侧模型输入对齐的关键交付物，见 PROJECT_PLAN 阶段1）
- [ ] 多 symbol 场景下窗口/BRAM 的扩展方式
