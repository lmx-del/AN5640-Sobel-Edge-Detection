module rgb565_to_rgb888 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] data_in,
    input  wire        data_valid,
    output reg  [23:0] data_out,
    output reg         out_valid
); 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out  <= 0;
            out_valid <= 0;
        end else if (data_valid) begin
            data_out  <= {data_in[4:0],   3'b000, 
                          data_in[10:5],  2'b00, 
                          data_in[15:11], 3'b000};
            out_valid <= 1;
        end else begin
            out_valid <= 0;
        end
    end
endmodule