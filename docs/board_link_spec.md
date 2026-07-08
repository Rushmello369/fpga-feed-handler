# 板间链路协议规格（AX7A200B ↔ Pynq Z1）

**状态：未定稿。** 这是 PROJECT_PLAN 阶段1 (协议与基线) 里 EEE 和 CS 双方需要共同敲定的交付物——特征向量的字段、位宽、量化范围必须和 CS 侧 `ml/models/quantized_nn` 的模型输入对齐，任何一边先动工都可能返工。

## 需要在此定稿的内容

- [ ] 特征向量的字段列表（如价差、失衡度等）及各字段位宽/定点格式
- [ ] 量化范围（和 CS 侧 QAT 的 scale/zero-point 对齐）
- [ ] 物理接口：优先用 Pynq Z1 的 PMOD/Arduino 排针 + 自定义并行/串行协议，**不走板载以太网**（否则会经过 Linux 网络栈，延迟数字失去说服力，详见 PROJECT_PLAN）
- [ ] 帧格式：起始/结束标记、握手信号、每周期传输的 bit 数
- [ ] 时钟域穿越（CDC）方案：两板时钟不同源，跨时钟域信号必须做同步处理

## 对应 RTL 占位

- `hardware/ax7a200b/rtl/board_link_tx/`（发送端，AX7A200B 侧，未开始）
- `hardware/pynq_z1/rtl/board_link_rx/`（接收端，Pynq Z1 侧，未开始，接入 FINN 输入前的 glue logic）
