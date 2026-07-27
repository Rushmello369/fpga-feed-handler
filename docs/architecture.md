# 架构说明

完整架构原理（为什么 AX7A200B 没有 PS、数据通路必须全程走 PL、板间链路为什么不能走板载以太网）见根目录
[PROJECT_PLAN.md](../PROJECT_PLAN.md)。当前 handler 的协议、特征和板间输出定义见
[`handler_contract.md`](handler_contract.md)，本文件只维护实现状态。

## 数据通路总览

```
ITCH字节流（当前UART bring-up，目标XDMA/MAC）→ ITCH50解析器 → 订单簿重构 → 特征提取
                                                              │
                                                     板间链路(PMOD直连)
                                                              ▼
                                              Pynq Z1 PL: board_link_rx → FINN 加速器 → 决策
                                                              │
                                                     板间链路(PMOD直连)
                                                              ▼
                        风控核 ← 决策 ←──────────────────────────
                          │
                          ▼
                     订单出口编码器 → 网络出口

（旁路，不在延迟关键路径）：AX7A200B PCIe/XDMA ←→ 外部主机（配置下发/监控/离线分析）
                          Pynq Z1 PS（ARM+Linux+Python）：overlay加载/参数配置/非逐样本日志
```

## 当前实现状态

| 子系统 | 状态 | 位置 |
|---|---|---|
| ITCH 5.0 协议解析 | 已实现 | `hardware/ax7a200b/rtl/ITCH50_parser/Itch_parser.sv` |
| 事件分发与 order lookup | 已实现 | `hardware/ax7a200b/rtl/ITCH50_parser/{Event_dispatcher,order_lookup}.sv` |
| 订单簿重构与 TOB | 已实现 | `hardware/ax7a200b/rtl/ITCH50_parser/{book_update,tob_tracker}.sv` |
| 流水优先编码器 | 已实现 | `hardware/ax7a200b/rtl/ITCH50_parser/priority_encoder_v2/` |
| 六维特征提取 | 已实现，6 × signed int16 | `hardware/ax7a200b/rtl/ITCH50_parser/feature_engine.sv` |
| 板间链路 TX | 逻辑字节流已实现，物理 PMOD/CDC 待定 | `hardware/ax7a200b/rtl/ITCH50_parser/board_link-tx.sv` |
| Python golden model | 已实现，可标定/过滤/导出 bit-exact 特征 | `hardware/ax7a200b/src/itch_tools.py` |
| UART 板级 bring-up | 顶层、约束、Tcl 和主机脚本已实现 | `hardware/ax7a200b/rtl/ITCH50_parser/io/` |
| FM24 原型流水线 | Legacy，仅保留回归 | `hardware/ax7a200b/rtl/fm24_parser/` |
| 风控核 / 订单出口编码器 | 未开始 | — |
| PCIe/XDMA 端点 | 未开始 | — |
| 板间链路 RX | 未开始 | `hardware/pynq_z1/rtl/board_link_rx/` |
| Pynq Z1 board_link_rx + FINN overlay | 未开始 | — |
| ML 数据集/baseline/QAT/FINN | 仅有早期 EDA，正式 ITCH50 流程未开始 | `ml/` |
| software/backtest、host_pcie_driver、market_simulator | 未开始 | — |

## 已知的架构债务

- 当前 `top_board` 使用 USB-UART 做最小化 bring-up，不是最终低延迟输入或板间物理层。
- `board_link_tx` 已冻结逻辑帧，但 PMOD 引脚、电气接口、CDC 和 Pynq RX 尚未完成。
- `QTY_SHIFT` 仍为待数据分布标定参数，修改时必须同步硬件、golden 数据和模型配置。
- 旧 FM24 reference 与当前 ITCH50 handler 的位宽、初始化和中间价尺度不同，不能混合使用。
