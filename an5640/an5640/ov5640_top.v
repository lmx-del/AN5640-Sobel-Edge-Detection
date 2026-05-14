`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/12 18:20:35
// Design Name: 
// Module Name: ov5640_top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ov5640_top ( 
    input  wire        cmos_pclk,
    input  wire        cmos_vsync,
    input  wire        cmos_href,
    input  wire [7:0]  cmos_data,

    input  wire        key,           // 新增按键输入（按下为低，假设有上拉）

    input  wire        m_axis_aclk,
    input  wire        m_axis_aresetn,
    output wire [23:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tuser,
    output wire        m_axis_tlast,
    output wire [2:0]  m_axis_tkeep 
);

    // ==================== 中间信号 ====================
    wire [15:0] rgb565_data;
    wire        rgb565_valid;
    wire [23:0] rgb888_data;
    wire        rgb888_valid;

    // ==================== 本地复位 ====================
    reg [31:0] reset_cnt;
    reg        cmos_aresetn;
    always @(posedge cmos_pclk) begin
        if (reset_cnt < 32'd200_000_000) begin
            reset_cnt <= reset_cnt + 32'd1;
            cmos_aresetn <= 1'b0;
        end else begin
            cmos_aresetn <= 1'b1;
        end
    end

    // ==================== 例化子模块 ====================
    cmos_8to16 u_cmos_8to16 (
        .pclk      (cmos_pclk),
        .rst_n     (cmos_aresetn),
        .href      (cmos_href),
        .data_in   (cmos_data),
        .data_out  (rgb565_data),
        .data_valid(rgb565_valid)
    );

    rgb565_to_rgb888 u_rgb565_to_888 (
        .clk       (cmos_pclk),
        .rst_n     (cmos_aresetn),
        .data_in   (rgb565_data),
        .data_valid(rgb565_valid),
        .data_out  (rgb888_data),
        .out_valid (rgb888_valid)
    );

    // ==================== 控制信号生成 ====================
    reg hblank;
    always @(posedge cmos_pclk) begin
        if (!cmos_aresetn)
            hblank <= 1'b0;
        else
            hblank <= cmos_href;
    end

    reg vsync_d0, vsync_d1;
    always @(posedge cmos_pclk) begin
        if (!cmos_aresetn) begin
            vsync_d0 <= 0;
            vsync_d1 <= 0;
        end else begin
            vsync_d0 <= cmos_vsync;
            vsync_d1 <= vsync_d0;
        end
    end
    wire vsync_neg = vsync_d1 && !vsync_d0;   // 帧同步脉冲

    // 行开始检测（hblank 上升沿）
    reg hblank_d;
    always @(posedge cmos_pclk) begin
        if (!cmos_aresetn)
            hblank_d <= 0;
        else
            hblank_d <= hblank;
    end
    wire row_start = hblank && !hblank_d;     // 行有效开始

    // ==================== 按键消抖 + 模式切换 ====================
    // key 为低时按下，松手为高。每按一次翻转模式
    reg [20:0] key_cnt;        // 消抖计数器，约 20ms（100MHz 时 2,000,000 次，此处按 100MHz，实际 pclk 可能不同，可适当调整）
    reg        key_state;      // 模式标志：0 = Sobel 边缘，1 = 原始视频
    reg        key_last;       // 用于边沿检测
    always @(posedge cmos_pclk or negedge cmos_aresetn) begin
        if (!cmos_aresetn) begin
            key_cnt <= 0;
            key_state <= 1'b0;   // 默认 Sobel 模式
            key_last <= 1'b1;    // 未按下时为高
        end else begin
            key_last <= key;
            if (key != key_last) begin
                key_cnt <= 0;               // 按键状态变化，复位计数器
            end else if (key_cnt < 2000000) begin // 消抖时间约 20ms，pclk 84MHz 下约 1,680,000 周期，设为 200 万
                key_cnt <= key_cnt + 1;
            end else if (key == 1'b0 && key_last == 1'b0 && key_cnt == 2000000) begin
                // 按键稳定在低电平且达到消抖时间，触发一次模式翻转
                key_state <= ~key_state;
                key_cnt <= key_cnt + 1;    // 防止重复触发
            end
        end
    end
    wire mode_bypass = key_state;   // 1：原始视频，0：Sobel

    // ==================== 生成外部对齐的 tlast 信号（给 Sobel） ====================
    wire tlast_for_sobel = (hblank_d && !hblank) & rgb888_valid;

    // ==================== 行计数器（用于前两行填充） ====================
    reg [9:0] row_cnt;  // 0~719
    always @(posedge cmos_pclk) begin
        if (!cmos_aresetn)
            row_cnt <= 0;
        else if (vsync_neg)
            row_cnt <= 0;
        else if (row_start)
            row_cnt <= row_cnt + 1;
    end

    // ==================== 前两行填充逻辑 ====================
    reg [10:0] fill_pix_cnt;
    reg        fill_valid;
    reg        fill_tuser;
    reg        fill_tlast;

    always @(posedge cmos_pclk) begin
        if (!cmos_aresetn) begin
            fill_pix_cnt <= 0;
            fill_valid   <= 0;
            fill_tuser   <= 0;
            fill_tlast   <= 0;
        end else begin
            if (hblank) begin
                if (row_cnt < 2) begin
                    fill_valid <= 1'b1;
                    if (fill_pix_cnt == 1280-1) begin
                        fill_pix_cnt <= 0;
                        fill_tlast   <= 1'b1;
                    end else begin
                        fill_pix_cnt <= fill_pix_cnt + 1;
                        fill_tlast   <= 1'b0;
                    end
                    if (row_cnt == 0 && fill_pix_cnt == 0)
                        fill_tuser <= 1'b1;
                    else
                        fill_tuser <= 1'b0;
                end else begin
                    fill_valid <= 1'b0;
                    fill_tuser <= 1'b0;
                    fill_tlast <= 1'b0;
                    fill_pix_cnt <= 0;
                end
            end else begin
                fill_valid <= 1'b0;
                fill_tuser <= 1'b0;
                fill_tlast <= 1'b0;
                if (row_cnt < 2 && fill_pix_cnt != 0)
                    fill_pix_cnt <= 0;
            end
        end
    end

    wire [23:0] fill_data = 24'h000000;   // 黑像素

    // ==================== 插入 Sobel 边缘检测 ====================
    wire [23:0] sobel_data;
    wire        sobel_valid;
    wire        sobel_tuser;
    wire        sobel_tlast;

    sobel_edge #(
        .IMG_WIDTH  (1280),
        .THRESHOLD  (100)
    ) u_sobel (
        .clk           (cmos_pclk),
        .rst_n         (cmos_aresetn),
        .pixel_in      (rgb888_data),
        .pixel_valid   (rgb888_valid),
        .tlast_in      (tlast_for_sobel),
        .vsync_neg     (vsync_neg),
        .pixel_out     (sobel_data),
        .pixel_out_valid(sobel_valid),
        .tuser_out     (sobel_tuser),
        .tlast_out     (sobel_tlast)
    );

    // ==================== 合并填充行与 Sobel 行（Sobel 路径） ====================
    wire [23:0] sobel_mux_data;
    wire        sobel_mux_valid;
    wire        sobel_mux_tuser;
    wire        sobel_mux_tlast;

    assign sobel_mux_data  = (row_cnt < 2) ? fill_data  : sobel_data;
    assign sobel_mux_valid = (row_cnt < 2) ? fill_valid : sobel_valid;
    assign sobel_mux_tuser = (row_cnt < 2) ? fill_tuser : sobel_tuser;
    assign sobel_mux_tlast = (row_cnt < 2) ? fill_tlast : sobel_tlast;

    // ==================== 原始视频延迟对齐（与 Sobel 延迟 6 拍对齐） ====================
    // 采集部分输出已经过两级流水线 (valid_d2, data_d2)，但未延迟 6 拍。
    // 我们直接取 rgb888_valid 和 rgb888_data 开始打 6 拍，同时取 tuser/tlast 对齐
    // 注意：之前有一个 s_axis_tuser_reg 和 s_axis_tlast_reg，它们是在 rgb888_valid 前生成，需要也打 6 拍
    reg [5:0] raw_valid_sr, raw_tuser_sr, raw_tlast_sr;
    reg [23:0] raw_data_d1, raw_data_d2, raw_data_d3, raw_data_d4, raw_data_d5, raw_data_d6;
    // 原始控制信号取自 s_axis_tuser_reg 和 s_axis_tlast_reg（已在同模块中生成，这里重新生成一份）
    // 我们使用已有的 s_axis_tuser_reg 和 s_axis_tlast_reg（在下面模块中），但不重复生成，直接引用前文定义的 s_axis_tuser_reg 和 s_axis_tlast_reg
    // 注意：在顶层之前没有 s_axis_tuser_reg 和 s_axis_tlast_reg，只有 tuser_for_sobel 等。我们需要重新生成一份干净的控制信号给原始视频用。
    // 简单起见，我们用采集部分的 valid_d2 作为参考，但要保证 tuser/tlast 对齐。实际上，我们只需要直接取 rgb888_valid 时刻的 tuser/tlast 即可。
    // 我们先制造一个在 rgb888_valid 有效时才会出现的 tuser 和 tlast 脉冲，避免孤立脉冲。
    wire raw_tlast_pre = (hblank_d && !hblank);     // 原始的行尾脉冲
    wire raw_tuser_pre;
    reg  raw_tuser_int;
    always @(posedge cmos_pclk or negedge cmos_aresetn) begin
        if (!cmos_aresetn)
            raw_tuser_int <= 1'b0;
        else if (vsync_neg)
            raw_tuser_int <= 1'b1;
        else if (rgb888_valid && raw_tuser_int)
            raw_tuser_int <= 1'b0;
    end
    assign raw_tuser_pre = raw_tuser_int;

    // 将原始数据和控制信号延迟 6 拍（对齐 Sobel 流水线延迟）
    always @(posedge cmos_pclk) begin
        if (!cmos_aresetn) begin
            raw_valid_sr <= 0;
            raw_tuser_sr <= 0;
            raw_tlast_sr <= 0;
            raw_data_d1 <= 0; raw_data_d2 <= 0; raw_data_d3 <= 0;
            raw_data_d4 <= 0; raw_data_d5 <= 0; raw_data_d6 <= 0;
        end else begin
            raw_valid_sr <= {raw_valid_sr[4:0], rgb888_valid};
            raw_tuser_sr <= {raw_tuser_sr[4:0], raw_tuser_pre};
            raw_tlast_sr <= {raw_tlast_sr[4:0], raw_tlast_pre};
            // 数据延迟
            raw_data_d1 <= rgb888_data;
            raw_data_d2 <= raw_data_d1;
            raw_data_d3 <= raw_data_d2;
            raw_data_d4 <= raw_data_d3;
            raw_data_d5 <= raw_data_d4;
            raw_data_d6 <= raw_data_d5;
        end
    end
    wire [23:0] raw_data_aligned = raw_data_d6;
    wire        raw_valid_aligned = raw_valid_sr[5];
    wire        raw_tuser_aligned = raw_tuser_sr[5];
    wire        raw_tlast_aligned = raw_tlast_sr[5];

    // ==================== 最终 MUX：按键选择输出 Sobel 或原始 ====================
    wire [23:0] final_data;
    wire        final_valid;
    wire        final_tuser;
    wire        final_tlast;

    assign final_data  = mode_bypass ? raw_data_aligned   : sobel_mux_data;
    assign final_valid = mode_bypass ? raw_valid_aligned  : sobel_mux_valid;
    assign final_tuser = mode_bypass ? raw_tuser_aligned  : sobel_mux_tuser;
    assign final_tlast = mode_bypass ? raw_tlast_aligned  : sobel_mux_tlast;

    // ==================== 打包写入 XPM FIFO ====================
    wire [25:0] fifo_din   = {final_tuser, final_tlast, final_data};
    wire        fifo_wr_en = final_valid | final_tlast;

    wire [25:0] fifo_dout;
    wire        fifo_empty;
    wire        fifo_rd_en = m_axis_tready && !fifo_empty;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE      ("auto"),
        .ECC_MODE              ("no_ecc"),
        .RELATED_CLOCKS        (0),
        .FIFO_WRITE_DEPTH      (4096),
        .WRITE_DATA_WIDTH      (26),
        .WR_DATA_COUNT_WIDTH   (12),
        .PROG_FULL_THRESH      (10),
        .FULL_RESET_VALUE      (0),
        .USE_ADV_FEATURES      ("0707"),
        .READ_MODE             ("fwft"),
        .FIFO_READ_LATENCY     (0),
        .READ_DATA_WIDTH       (26),
        .RD_DATA_COUNT_WIDTH   (12),
        .PROG_EMPTY_THRESH     (10),
        .DOUT_RESET_VALUE      ("0"),
        .CDC_SYNC_STAGES       (2),
        .WAKEUP_TIME           (0)
    ) u_fifo (
        .rst           (~cmos_aresetn),
        .wr_clk        (cmos_pclk),
        .wr_en         (fifo_wr_en),
        .din           (fifo_din),
        .full          (),
        .rd_clk        (m_axis_aclk),
        .rd_en         (fifo_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0)
    );

    // ==================== AXI-Stream 输出 ====================
    assign m_axis_tdata  = fifo_dout[23:0];
    assign m_axis_tlast  = fifo_dout[24];
    assign m_axis_tuser  = fifo_dout[25];
    assign m_axis_tvalid = !fifo_empty;
    assign m_axis_tkeep  = 3'b111;
 
endmodule
