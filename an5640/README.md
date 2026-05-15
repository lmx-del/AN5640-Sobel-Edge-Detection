# FPGA 实时 Sobel 边缘检测系统

## 功能

-   **实时采集**：1280×720 实时摄像头采集
-   **硬件加速**：硬件 Sobel 边缘检测，参数化阈值（默认 100，可动态修改）
-   **实时切换**：按键实时切换原始彩色画面 ↔ 边缘黑白画面
-   **跨时钟域**：手写 FWFT 异步 FIFO，实现跨时钟域（PCLK → ACLK）可靠传输
-   **标准接口**：标准 AXI-Stream 输出，直接对接 AXI VDMA
-   **IP 复用**：全模块 IP 化封装，支持在 Block Design 中一键调用

## 系统框图

![block_diagram](C:\Users\李\Downloads\block_diagram.png)

**数据流**：  
`OV5640 → 采集模块 → Sobel 边缘检测 → XPM 异步 FIFO → VDMA → HDMI 显示`

**时钟域划分**：  

-   PCLK 域：采集模块、Sobel 处理
-   ACLK 域：FIFO 读侧、VDMA、HDMI 输出

## 模块清单

| 模块               | 功能                                             | 自研/官方 |
| :----------------- | :----------------------------------------------- | :-------- |
| `ov5640_capture`   | DVP 采集 + RGB888 输出（含 8→16 拼接、色彩转换） | 自研      |
| `cmos_8to16`       | 8 位 DVP 数据 → 16 位 RGB565                     | 自研      |
| `rgb565_to_rgb888` | RGB565 → RGB888 色彩空间扩展                     | 自研      |
| `sobel_edge`       | 3×3 窗口硬件加速 Sobel 边缘检测                  | 自研      |
| `async_fifo`       | FWFT 模式异步 FIFO（手写，格雷码指针）           | 自研      |
| `key_debounce`     | 按键消抖逻辑（约 20ms）                          | 自研      |
| `xpm_fifo_async`   | Xilinx 官方异步 FIFO（最终稳定版）               | 官方      |

## 资源占用 (Zynq-7000, AX7010)

| 资源            | 用量  | 比例 |
| :-------------- | :---- | :--- |
| Slice LUTs      | 8,103 | 15%  |
| Slice Registers | 9,660 | 9%   |
| Block RAM Tile  | 17    | 12%  |

## 关键设计点

1.  **异步 FIFO 的 FWFT 实现**
    -   使用格雷码指针 + 两级同步消除亚稳态。
    -   读写指针独立，满/空判断基于格雷码比较。
    -   输出数据预取一级，实现 First-Word Fall-Through 行为。

2.  **Sobel 边缘检测流水线**
    -   2 个行缓冲区（分布式 RAM）存储前两行像素。
    -   3×3 窗口提取 + 梯度计算共 6 个时钟周期延迟。
    -   阈值可参数化配置（双击 IP 修改 `THRESHOLD` 参数）。

3.  **控制信号对齐**
    -   `tuser`/`tlast` 信号与数据路径严格延迟匹配。
    -   外部行尾标志 `tlast` 确保 VDMA 行同步，解决随机卡死问题。

4.  **按键模式切换**
    -   硬件消抖，约 23 ms。
    -   按下一次切换 `sobel` ↔ `bypass` 模式，零延时。

## 开发环境

-   Vivado 2017.4
-   硬件平台：ALINX AX7010 (Zynq-7000 XC7Z010)
-   摄像头：OV5640 (DVP 接口, 1280×720)

## 如何使用

1.  在 Vivado 中打开 Block Design，添加本 IP 核。
2.  连接摄像头 DVP 引脚、系统时钟 `m_axis_aclk` 和 VDMA。
3.  配置 `sobel_edge` 的 `THRESHOLD` 参数（默认 100）。
4.  生成比特流并下载，连接 HDMI 显示器即可观察效果。

## 项目状态

-   ✅ 功能完整，稳定运行。
-   ✅ 支持按键切换模式。
-   ✅ 模块已封装为标准 IP，可复用。