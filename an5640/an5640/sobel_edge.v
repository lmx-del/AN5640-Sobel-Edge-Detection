`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/12 18:22:08
// Design Name: 
// Module Name: sobel_edge
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


module sobel_edge #(
    parameter IMG_WIDTH  = 1280,      // 一行有效像素数
    parameter THRESHOLD  = 100        // 边缘阈值
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [23:0] pixel_in,
    input  wire        pixel_valid,
    input  wire        tlast_in,      // 外部对齐的行尾脉冲
    input  wire        vsync_neg,     // 帧同步脉冲（用于生成 tuser）

    output wire [23:0] pixel_out,
    output wire        pixel_out_valid,
    output wire        tuser_out,
    output wire        tlast_out
);

    // ==================== Line Buffer (2行) ====================
    localparam ADDR_WIDTH = 11;
    reg [23:0] line_buf_0 [0:(1<<ADDR_WIDTH)-1];
    reg [23:0] line_buf_1 [0:(1<<ADDR_WIDTH)-1];

    reg [ADDR_WIDTH-1:0] wr_addr;
    reg                  line_sel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr  <= 0;
            line_sel <= 0;
        end else if (pixel_valid) begin
            if (wr_addr == IMG_WIDTH - 1) begin
                wr_addr  <= 0;
                line_sel <= ~line_sel;
            end else begin
                wr_addr <= wr_addr + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (pixel_valid) begin
            if (line_sel == 0)
                line_buf_0[wr_addr] <= pixel_in;
            else
                line_buf_1[wr_addr] <= pixel_in;
        end
    end

    wire [ADDR_WIDTH-1:0] rd_l = (wr_addr == 0) ? (IMG_WIDTH-1) : (wr_addr - 1);
    wire [ADDR_WIDTH-1:0] rd_c = wr_addr;
    wire [ADDR_WIDTH-1:0] rd_r = (wr_addr == IMG_WIDTH-1) ? 0 : (wr_addr + 1);

    // ==================== 控制信号与窗口数据锁存 ====================
    reg [23:0] curr_p1, curr_p2, curr_p3;
    reg [23:0] prev_p1, prev_p2, prev_p3;
    reg [23:0] prev2_p1, prev2_p2, prev2_p3;

    reg        tuser_int;
    reg [5:0]  valid_sr, tuser_sr, tlast_sr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_p1 <= 0; curr_p2 <= 0; curr_p3 <= 0;
            prev_p1 <= 0; prev_p2 <= 0; prev_p3 <= 0;
            prev2_p1<= 0; prev2_p2<= 0; prev2_p3<= 0;
            valid_sr <= 0;
            tuser_sr <= 0;
            tlast_sr <= 0;
            tuser_int <= 0;
        end else begin
            // tuser 生成：vsync下降沿后第一个有效像素时拉高
            if (vsync_neg)
                tuser_int <= 1'b1;
            else if (pixel_valid && tuser_int)
                tuser_int <= 1'b0;

            // 窗口数据锁存
            if (pixel_valid) begin
                curr_p1 <= pixel_in;
                curr_p2 <= pixel_in;
                curr_p3 <= pixel_in;

                if (line_sel == 0) begin
                    prev2_p1 <= line_buf_0[rd_l];
                    prev2_p2 <= line_buf_0[rd_c];
                    prev2_p3 <= line_buf_0[rd_r];
                    prev_p1  <= line_buf_1[rd_l];
                    prev_p2  <= line_buf_1[rd_c];
                    prev_p3  <= line_buf_1[rd_r];
                end else begin
                    prev_p1  <= line_buf_0[rd_l];
                    prev_p2  <= line_buf_0[rd_c];
                    prev_p3  <= line_buf_0[rd_r];
                    prev2_p1 <= line_buf_1[rd_l];
                    prev2_p2 <= line_buf_1[rd_c];
                    prev2_p3 <= line_buf_1[rd_r];
                end
            end

            // 移位寄存器：所有信号延迟 6 拍
            valid_sr <= {valid_sr[4:0], pixel_valid};
            tuser_sr <= {tuser_sr[4:0], tuser_int};
            tlast_sr <= {tlast_sr[4:0], tlast_in};    // 使用外部 tlast 信号
        end
    end

    // ==================== 形成 3x3 窗口 ====================
    reg [23:0] w0c0, w0c1, w0c2;
    reg [23:0] w1c0, w1c1, w1c2;
    reg [23:0] w2c0, w2c1, w2c2;

    always @(posedge clk) begin
        if (valid_sr[0]) begin
            w0c0 <= prev2_p1; w0c1 <= prev2_p2; w0c2 <= prev2_p3;
            w1c0 <= prev_p1;  w1c1 <= prev_p2;  w1c2 <= prev_p3;
            w2c0 <= curr_p1;  w2c1 <= curr_p2;  w2c2 <= curr_p3;
        end
    end

    // ==================== 灰度提取与 Sobel 计算 ====================
    wire [7:0] g00 = w0c0[15:8];
    wire [7:0] g01 = w0c1[15:8];
    wire [7:0] g02 = w0c2[15:8];
    wire [7:0] g10 = w1c0[15:8];
    wire [7:0] g11 = w1c1[15:8];
    wire [7:0] g12 = w1c2[15:8];
    wire [7:0] g20 = w2c0[15:8];
    wire [7:0] g21 = w2c1[15:8];
    wire [7:0] g22 = w2c2[15:8];

    reg signed [10:0] gx_row0, gx_row2;
    reg signed [10:0] gy_col0, gy_col2;
    always @(posedge clk) begin
        gx_row0 <= $signed({1'b0,g00}) + ($signed({1'b0,g01}) << 1) + $signed({1'b0,g02});
        gx_row2 <= $signed({1'b0,g20}) + ($signed({1'b0,g21}) << 1) + $signed({1'b0,g22});
        gy_col0 <= $signed({1'b0,g00}) + ($signed({1'b0,g10}) << 1) + $signed({1'b0,g20});
        gy_col2 <= $signed({1'b0,g02}) + ($signed({1'b0,g12}) << 1) + $signed({1'b0,g22});
    end

    reg signed [11:0] gx, gy;
    always @(posedge clk) begin
        gx <= gx_row0 - gx_row2;
        gy <= gy_col0 - gy_col2;
    end

    reg [11:0] grad_mag;
    always @(posedge clk) begin
        grad_mag <= (gx[11] ? (~gx + 1) : gx) + (gy[11] ? (~gy + 1) : gy);
    end

    reg [23:0] edge_out;
    always @(posedge clk) begin
        if (grad_mag[7:0] > THRESHOLD)
            edge_out <= 24'hFFFFFF;
        else
            edge_out <= 24'h000000;
    end

    // ==================== 输出 ====================
    assign pixel_out       = edge_out;
    assign pixel_out_valid = valid_sr[5];
    assign tuser_out       = tuser_sr[5];
    assign tlast_out       = tlast_sr[5];
endmodule
