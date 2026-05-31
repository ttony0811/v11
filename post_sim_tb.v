`timescale 1ns / 1ps

module RISCV_CNN_tb;

    localparam integer ST_HOLD_CYCLES   = 1000010;
    localparam integer POST_DONE_CYCLES = 200;
    localparam integer TIMEOUT_CYCLES   = 3000000;

    reg         FPGA_clk;
    reg         rstn;
    reg  [3:0]  tc;
    reg         mode;
    reg         st;

    wire [6:0]  seven_seg;
    wire [3:0]  anode;
    wire        all_done;

    integer timeout_count;

    RISCV_CNN dut (
        .FPGA_clk (FPGA_clk),
        .rstn     (rstn),
        .tc       (tc),
        .mode     (mode),
        .st       (st),
        .seven_seg(seven_seg),
        .anode    (anode),
        .all_done (all_done)
    );

    initial begin
        FPGA_clk = 1'b0;
        forever #5 FPGA_clk = ~FPGA_clk;
    end

    initial begin
        rstn = 1'b0;
        mode = 1'b0;
        tc   = 4'h0;
        st   = 1'b0;

        // Stay in reset past the Xilinx post-implementation glbl.GSR window.
        repeat (300) @(posedge FPGA_clk);
        #2 rstn = 1'b1;

        // Set testcase and start away from the active sampling edge.
        repeat (20) @(posedge FPGA_clk);
        #2;
        mode = 1'b0;
        tc   = 4'hF;
        st   = 1'b0;

        @(posedge FPGA_clk);
        #2 st = 1'b1;

        repeat (ST_HOLD_CYCLES) @(posedge FPGA_clk);
        #2 st = 1'b0;

        // Switch to score display after Marker A, not on the same edge.
        repeat (10) @(posedge FPGA_clk);
        #2 mode = 1'b1;
    end

    initial begin
        timeout_count = 0;
        wait (rstn == 1'b1);
        while ((all_done !== 1'b1) && (timeout_count < TIMEOUT_CYCLES)) begin
            @(posedge FPGA_clk);
            timeout_count = timeout_count + 1;
        end

        if (all_done === 1'b1) begin
            $display("TB_AUTO_FINISH: all_done rose at %0t ps", $time);
            repeat (POST_DONE_CYCLES) @(posedge FPGA_clk);
            $display("TB_AUTO_FINISH: kept waveform for %0d cycles after all_done", POST_DONE_CYCLES);
        end
        else begin
            $display("TB_AUTO_FINISH: TIMEOUT at %0t ps, all_done did not rise", $time);
        end
    end

endmodule
