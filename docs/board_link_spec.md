# 板间链路协议规格（AX7A200B → Pynq Z1）

**状态：发送帧格式已冻结；物理 PMOD 接口、CDC 和 Pynq Z1 接收端待实现。**

本文只规定 `board_link_tx` 的逻辑字节流。特征定义和数值语义以
[`handler_contract.md`](handler_contract.md) 为准。

对应实现：

```text
hardware/ax7a200b/rtl/ITCH50_parser/board_link-tx.sv
hardware/ax7a200b/tb/tb_board_link_tx.sv
hardware/ax7a200b/src/uart_feed.py
```

## 1. 帧格式

每条 feature vector 打包为 15 字节：

| Byte | Field | Format |
|---:|---|---|
| 0 | `SYNC` | 固定 `0xA5` |
| 1 | `SEQ` | 8 bit 滚动帧序号，模 256 自增 |
| 2–3 | `spr` | signed int16, big-endian |
| 4–5 | `tobi` | signed int16, big-endian |
| 6–7 | `ofi` | signed int16, big-endian |
| 8–9 | `emadev` | signed int16, big-endian |
| 10–11 | `mom` | signed int16, big-endian |
| 12–13 | `tflow` | signed int16, big-endian |
| 14 | `CHK` | bytes 0–13 的逐字节 XOR |

字节序固定为大端，特征顺序不得调整。

## 2. 字节流握手

逻辑接口使用 ready/valid：

```text
tx_valid = 1 且 tx_ready = 1
```

时，一个字节完成传输。`tx_ready = 0` 时，发送端必须保持当前 `tx_data`
和 `tx_valid`，恢复后从同一字节继续。

该接口是 PMOD serializer 或其他物理层之前的逻辑接口，不代表最终引脚数量、
电气标准或跨时钟域实现。

## 3. 排队与诊断

发送端不维护多帧 FIFO，只保留一个 pending feature：

- 空闲时接收的 feature 成为下一帧；
- 发送期间到达的新 feature 覆盖 pending feature，保留最新市场状态；
- `drop_count` 的当前 RTL 行为是在 `feat_valid` 到达且发送器正在发送，
  或已经存在 pending feature 时加 1；
- 接收端使用 `SEQ` 跳变检测未收到的帧。

ML 回放和系统延迟报告必须同时记录 `drop_count`，不能把发生丢帧的运行解释为
逐事件完整推理。

## 4. 接收端要求

Pynq Z1 `board_link_rx` 至少需要：

1. 搜索 `0xA5` 完成帧同步；
2. 接收固定 15 字节；
3. 验证 XOR；
4. 检查 `SEQ` 连续性；
5. 将六个大端字段恢复为 `signed int16`；
6. 仅对校验通过的完整帧产生一次 FINN 输入 valid；
7. 统计 checksum error、sequence gap 和有效帧数。

## 5. 尚未冻结

- PMOD/Arduino 排针分配；
- 串行或并行 PHY；
- AX7A200B 与 Pynq Z1 异步时钟域之间的 CDC；
- 目标链路时钟和实际吞吐率；
- Pynq Z1 → AX7A200B 的 decision 返回帧。

这些项目后续可以扩展，但不得改变本文件第 1 节的特征字节顺序，除非按
[`handler_contract.md`](handler_contract.md) 的变更规则同步升级接口版本。
