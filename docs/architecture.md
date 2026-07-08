# 架构说明

完整架构原理（为什么 AX7A200B 没有 PS、数据通路必须全程走 PL、板间链路为什么不能走板载以太网）见根目录 [PROJECT_PLAN.md](../PROJECT_PLAN.md)，本文件只做当前实现状态的快照，避免和主计划文档重复维护，也避免两处描述随时间不一致。

## 数据通路总览

```
以太网(RGMII) → MAC/PHY → 行情解析器 → 订单簿重构引擎 → 特征提取
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
| FM24 协议解析 (msg_parser) | 已实现，Pynq Z1 上 bring-up 验证过 | `hardware/ax7a200b/rtl/msg_parser.sv` |
| 订单簿重构 (book_update + priority_encoder + tob_tracker) | 已实现 | `hardware/ax7a200b/rtl/{book_update,priority_encoder,tob_tracker}.sv` |
| 延迟统计 | 已实现（周期计数） | `hardware/ax7a200b/rtl/latency_counter.sv` |
| AXI 封装（IP 打包用） | 已实现，AXI4-Stream + AXI4-Lite | `hardware/ax7a200b/rtl/feed_handler.sv` |
| 特征提取 | 未开始，等 `docs/board_link_spec.md` 定稿 | — |
| 风控核 / 订单出口编码器 | 未开始 | — |
| PCIe/XDMA 端点 | 未开始（目前控制面是 AXI-Lite，最终要迁移到 PCIe） | — |
| 板间链路 tx/rx | 未开始 | — |
| Pynq Z1 board_link_rx + FINN overlay | 未开始 | — |
| ml/ 全部内容（特征工程/baseline/QAT/FINN编译） | 未开始 | — |
| software/backtest、host_pcie_driver、market_simulator | 未开始 | — |

## 已知的架构债务

- `feed_handler.sv` 目前的控制面是 AXI4-Lite（方便在 Pynq Z1 上用 PYNQ/Python 直接调试），但最终 AX7A200B 没有 PS，控制面要换成 PCIe/XDMA 寄存器接口——迁移时数据通路（`top` 核心）本身不用动，只需要重写外层封装。
