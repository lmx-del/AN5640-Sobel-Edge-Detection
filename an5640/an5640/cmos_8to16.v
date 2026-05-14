module cmos_8to16 (
    input  wire        pclk,
    input  wire        rst_n,
    input  wire        href,
    input  wire [7:0]  data_in,
    output reg  [15:0] data_out,
    output reg         data_valid
);
    reg [7:0] data_prev;
    reg toggle;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            data_prev  <= 0;
            data_out   <= 0;
            data_valid <= 0;
            toggle     <= 0;
        end else if (href) begin
            if (!toggle) begin
                data_prev  <= data_in;
                toggle     <= 1;
                data_valid <= 0;
            end else begin
                data_out   <= {data_prev,data_in};
                toggle     <= 0;
                data_valid <= 1;
            end
        end else begin
            toggle     <= 0;
            data_valid <= 0;
        end
    end
endmodule