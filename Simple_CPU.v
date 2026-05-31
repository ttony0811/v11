`timescale 1ns / 1ps

module Simple_CPU(
    input         CLK,
    input         RSTN,
    output reg        dmem_en,
    output reg        dmem_we,
    output reg [9:0]  dmem_addr,
    output reg [31:0] dmem_wdata,
    input      [31:0] dmem_rdata
);

localparam [6:0] OP_LOAD   = 7'b0000011;
localparam [6:0] OP_STORE  = 7'b0100011;
localparam [6:0] OP_IMM    = 7'b0010011;
localparam [6:0] OP_REG    = 7'b0110011;
localparam [6:0] OP_BRANCH = 7'b1100011;

reg [9:0]  pc_word;
reg [9:0]  fetch_pc_word_q;
reg        imem_valid_q;
reg        fetch_buf_valid;
reg [9:0]  fetch_buf_pc_word;
reg [31:0] fetch_buf_instr;

wire [31:0] instr;
wire [31:0] instr_mem_dout;

reg        if_id_valid;
reg [9:0]  if_id_pc_word;
reg [31:0] if_id_instr;

reg        id_ex_valid;
reg [9:0]  id_ex_pc_word;
reg [31:0] id_ex_rs1_val;
reg [31:0] id_ex_rs2_val;
reg [31:0] id_ex_imm;
reg [4:0]  id_ex_rs1;
reg [4:0]  id_ex_rs2;
reg [4:0]  id_ex_rd;
reg [2:0]  id_ex_funct3;
reg [6:0]  id_ex_funct7;
reg        id_ex_reg_write;
reg        id_ex_mem_read;
reg        id_ex_mem_write;
reg        id_ex_mem_to_reg;
reg        id_ex_alu_src_imm;
reg        id_ex_branch;
reg        id_ex_sub;

reg        ex_mem_valid;
reg        ex_mem_reg_write;
reg        ex_mem_mem_to_reg;
reg [4:0]  ex_mem_rd;
reg [31:0] ex_mem_alu_result;

reg        mem_wb_valid;
reg        mem_wb_reg_write;
reg        mem_wb_mem_to_reg;
reg [4:0]  mem_wb_rd;
reg [31:0] mem_wb_alu_result;
reg [31:0] mem_wb_load_data;

/*reg [31:0] rf_x1,  rf_x2,  rf_x3,  rf_x4;
reg [31:0] rf_x5,  rf_x6,  rf_x7,  rf_x8;
reg [31:0] rf_x9,  rf_x10, rf_x11, rf_x12;
reg [31:0] rf_x13, rf_x14, rf_x15, rf_x16;
reg [31:0] rf_x17, rf_x18, rf_x19, rf_x20;
reg [31:0] rf_x21, rf_x22, rf_x23, rf_x24;
reg [31:0] rf_x25, rf_x26, rf_x27, rf_x28;
reg [31:0] rf_x29, rf_x30, rf_x31;*/

/*(* ram_style = "distributed" *) reg [31:0] regs [0:31];
integer rf_i;*/
reg [31:0] rf_a [0:31];
reg [31:0] rf_b [0:31];

reg        rf_clear_active;
reg [5:0]  rf_clear_idx;

wire [6:0] id_opcode = if_id_instr[6:0];
wire [4:0] id_rd     = if_id_instr[11:7];
wire [2:0] id_funct3 = if_id_instr[14:12];
wire [4:0] id_rs1    = if_id_instr[19:15];
wire [4:0] id_rs2    = if_id_instr[24:20];
wire [6:0] id_funct7 = if_id_instr[31:25];

wire [31:0] id_imm_i = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
wire [31:0] id_imm_s = {{20{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
wire [31:0] id_imm_b = {{19{if_id_instr[31]}}, if_id_instr[31], if_id_instr[7],
                         if_id_instr[30:25], if_id_instr[11:8], 1'b0};

wire id_is_load   = if_id_valid && (id_opcode == OP_LOAD)   && (id_funct3 == 3'b010);
wire id_is_store  = if_id_valid && (id_opcode == OP_STORE)  && (id_funct3 == 3'b010);
wire id_is_addi   = if_id_valid && (id_opcode == OP_IMM)    && (id_funct3 == 3'b000);
wire id_is_addsub = if_id_valid && (id_opcode == OP_REG)    && (id_funct3 == 3'b000) &&
                    ((id_funct7 == 7'b0000000) || (id_funct7 == 7'b0100000));
wire id_is_branch = if_id_valid && (id_opcode == OP_BRANCH) &&
                    ((id_funct3 == 3'b000) || (id_funct3 == 3'b100));

wire id_uses_rs1 = id_is_load || id_is_store || id_is_addi || id_is_addsub || id_is_branch;
wire id_uses_rs2 = id_is_store || id_is_addsub || id_is_branch;

wire [31:0] wb_wdata = mem_wb_mem_to_reg ? mem_wb_load_data : mem_wb_alu_result;
reg [31:0] id_rs1_raw;
reg [31:0] id_rs2_raw;
wire [31:0] id_rs1_value = (mem_wb_valid && mem_wb_reg_write &&
                            (mem_wb_rd != 5'd0) && (mem_wb_rd == id_rs1)) ?
                           wb_wdata : id_rs1_raw;
wire [31:0] id_rs2_value = (mem_wb_valid && mem_wb_reg_write &&
                            (mem_wb_rd != 5'd0) && (mem_wb_rd == id_rs2)) ?
                           wb_wdata : id_rs2_raw;

wire load_use_stall = id_ex_valid && id_ex_mem_read && (id_ex_rd != 5'd0) &&
                      ((id_uses_rs1 && (id_ex_rd == id_rs1)) ||
                       (id_uses_rs2 && (id_ex_rd == id_rs2)));

wire mem_ex_dep_stall = if_id_valid && (id_is_load || id_is_store) &&
                        id_ex_valid && id_ex_reg_write && (id_ex_rd != 5'd0) &&
                        (((id_is_load || id_is_store) && (id_ex_rd == id_rs1)) ||
                         (id_is_store && (id_ex_rd == id_rs2)));
wire decode_stall = load_use_stall || mem_ex_dep_stall;

reg [31:0] ex_rs1_fwd;
reg [31:0] ex_rs2_fwd;

always @(*) begin
    ex_rs1_fwd = id_ex_rs1_val;
    if (ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_to_reg &&
        (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1)) begin
        ex_rs1_fwd = ex_mem_alu_result;
    end
    else if (mem_wb_valid && mem_wb_reg_write &&
             (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) begin
        ex_rs1_fwd = wb_wdata;
    end
end

always @(*) begin
    ex_rs2_fwd = id_ex_rs2_val;
    if (ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_to_reg &&
        (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2)) begin
        ex_rs2_fwd = ex_mem_alu_result;
    end
    else if (mem_wb_valid && mem_wb_reg_write &&
             (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) begin
        ex_rs2_fwd = wb_wdata;
    end
end

wire [31:0] ex_alu_b = id_ex_alu_src_imm ? id_ex_imm : ex_rs2_fwd;
wire [31:0] ex_alu_result = id_ex_sub ? (ex_rs1_fwd - ex_alu_b) :
                                        (ex_rs1_fwd + ex_alu_b);
wire ex_beq_taken = (id_ex_funct3 == 3'b000) && (ex_rs1_fwd == ex_rs2_fwd);
wire ex_blt_taken = (id_ex_funct3 == 3'b100) && ($signed(ex_rs1_fwd) < $signed(ex_rs2_fwd));
wire branch_taken = id_ex_valid && id_ex_branch && (ex_beq_taken || ex_blt_taken);
wire signed [10:0] branch_base_word_s = {1'b0, id_ex_pc_word};
wire signed [10:0] branch_offset_word_s = id_ex_imm[12:2];
wire signed [10:0] branch_target_word_s = branch_base_word_s + branch_offset_word_s;
wire [9:0] branch_target_word = branch_target_word_s[9:0];

wire [31:0] mem_rs1_fwd = (mem_wb_valid && mem_wb_reg_write &&
                          (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) ?
                          wb_wdata : id_ex_rs1_val;
wire [31:0] mem_rs2_fwd = (mem_wb_valid && mem_wb_reg_write &&
                          (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) ?
                          wb_wdata : id_ex_rs2_val;
wire [31:0] mem_addr_result = mem_rs1_fwd + id_ex_imm;

always @(posedge CLK or negedge RSTN) begin
    if (!RSTN) begin
        rf_clear_active <= 1'b1;
        rf_clear_idx    <= 6'd0;
    end
    else begin
        if (rf_clear_active) begin
            if (rf_clear_idx == 6'd31) begin
                rf_clear_active <= 1'b0;
            end
            else begin
                rf_clear_idx <= rf_clear_idx + 6'd1;
            end
        end
    end
end

wire [31:0] id_rs1_raw =
    (id_rs1 == 5'd0) ? 32'd0 : rf_a[id_rs1];

wire [31:0] id_rs2_raw =
    (id_rs2 == 5'd0) ? 32'd0 : rf_b[id_rs2];

/*initial begin
    rf_x1  = 32'd0; rf_x2  = 32'd0; rf_x3  = 32'd0; rf_x4  = 32'd0;
    rf_x5  = 32'd0; rf_x6  = 32'd0; rf_x7  = 32'd0; rf_x8  = 32'd0;
    rf_x9  = 32'd0; rf_x10 = 32'd0; rf_x11 = 32'd0; rf_x12 = 32'd0;
    rf_x13 = 32'd0; rf_x14 = 32'd0; rf_x15 = 32'd0; rf_x16 = 32'd0;
    rf_x17 = 32'd0; rf_x18 = 32'd0; rf_x19 = 32'd0; rf_x20 = 32'd0;
    rf_x21 = 32'd0; rf_x22 = 32'd0; rf_x23 = 32'd0; rf_x24 = 32'd0;
    rf_x25 = 32'd0; rf_x26 = 32'd0; rf_x27 = 32'd0; rf_x28 = 32'd0;
    rf_x29 = 32'd0; rf_x30 = 32'd0; rf_x31 = 32'd0;
end*/

/*always @(*) begin
    case (id_rs1)
        5'd1:  id_rs1_raw = rf_x1;
        5'd2:  id_rs1_raw = rf_x2;
        5'd3:  id_rs1_raw = rf_x3;
        5'd4:  id_rs1_raw = rf_x4;
        5'd5:  id_rs1_raw = rf_x5;
        5'd6:  id_rs1_raw = rf_x6;
        5'd7:  id_rs1_raw = rf_x7;
        5'd8:  id_rs1_raw = rf_x8;
        5'd9:  id_rs1_raw = rf_x9;
        5'd10: id_rs1_raw = rf_x10;
        5'd11: id_rs1_raw = rf_x11;
        5'd12: id_rs1_raw = rf_x12;
        5'd13: id_rs1_raw = rf_x13;
        5'd14: id_rs1_raw = rf_x14;
        5'd15: id_rs1_raw = rf_x15;
        5'd16: id_rs1_raw = rf_x16;
        5'd17: id_rs1_raw = rf_x17;
        5'd18: id_rs1_raw = rf_x18;
        5'd19: id_rs1_raw = rf_x19;
        5'd20: id_rs1_raw = rf_x20;
        5'd21: id_rs1_raw = rf_x21;
        5'd22: id_rs1_raw = rf_x22;
        5'd23: id_rs1_raw = rf_x23;
        5'd24: id_rs1_raw = rf_x24;
        5'd25: id_rs1_raw = rf_x25;
        5'd26: id_rs1_raw = rf_x26;
        5'd27: id_rs1_raw = rf_x27;
        5'd28: id_rs1_raw = rf_x28;
        5'd29: id_rs1_raw = rf_x29;
        5'd30: id_rs1_raw = rf_x30;
        5'd31: id_rs1_raw = rf_x31;
        default: id_rs1_raw = 32'd0;
    endcase
end*/
/* @(*) begin
    id_rs1_raw = (id_rs1 == 5'd0) ? 32'd0 : regs[id_rs1];
end*/

/*always @(*) begin
    case (id_rs2)
        5'd1:  id_rs2_raw = rf_x1;
        5'd2:  id_rs2_raw = rf_x2;
        5'd3:  id_rs2_raw = rf_x3;
        5'd4:  id_rs2_raw = rf_x4;
        5'd5:  id_rs2_raw = rf_x5;
        5'd6:  id_rs2_raw = rf_x6;
        5'd7:  id_rs2_raw = rf_x7;
        5'd8:  id_rs2_raw = rf_x8;
        5'd9:  id_rs2_raw = rf_x9;
        5'd10: id_rs2_raw = rf_x10;
        5'd11: id_rs2_raw = rf_x11;
        5'd12: id_rs2_raw = rf_x12;
        5'd13: id_rs2_raw = rf_x13;
        5'd14: id_rs2_raw = rf_x14;
        5'd15: id_rs2_raw = rf_x15;
        5'd16: id_rs2_raw = rf_x16;
        5'd17: id_rs2_raw = rf_x17;
        5'd18: id_rs2_raw = rf_x18;
        5'd19: id_rs2_raw = rf_x19;
        5'd20: id_rs2_raw = rf_x20;
        5'd21: id_rs2_raw = rf_x21;
        5'd22: id_rs2_raw = rf_x22;
        5'd23: id_rs2_raw = rf_x23;
        5'd24: id_rs2_raw = rf_x24;
        5'd25: id_rs2_raw = rf_x25;
        5'd26: id_rs2_raw = rf_x26;
        5'd27: id_rs2_raw = rf_x27;
        5'd28: id_rs2_raw = rf_x28;
        5'd29: id_rs2_raw = rf_x29;
        5'd30: id_rs2_raw = rf_x30;
        5'd31: id_rs2_raw = rf_x31;
        default: id_rs2_raw = 32'd0;
    endcase
end*/
/*always @(*) begin
    id_rs2_raw = (id_rs2 == 5'd0) ? 32'd0 : regs[id_rs2];
end*/

Instruction_Memory u_instr_mem(
    .clka(CLK),
    .addra(pc_word),
    .douta(instr_mem_dout)
);

assign instr = instr_mem_dout;

always @(*) begin
    dmem_en = 1'b0;
    dmem_we = 1'b0;
    dmem_addr = 10'd0;
    dmem_wdata = 32'd0;

    if (id_ex_valid && (id_ex_mem_read || id_ex_mem_write)) begin
        dmem_en = 1'b1;
        dmem_we = id_ex_mem_write;
        dmem_addr = mem_addr_result[11:2];
        dmem_wdata = mem_rs2_fwd;
    end
end

/*always @(posedge CLK or negedge RSTN) begin
    if (!RSTN) begin
        rf_x1  <= 32'd0;
        rf_x2  <= 32'd0;
        rf_x3  <= 32'd0;
        rf_x4  <= 32'd0;
        rf_x5  <= 32'd0;
        rf_x6  <= 32'd0;
        rf_x7  <= 32'd0;
        rf_x8  <= 32'd0;
        rf_x9  <= 32'd0;
        rf_x10 <= 32'd0;
        rf_x11 <= 32'd0;
        rf_x12 <= 32'd0;
        rf_x13 <= 32'd0;
        rf_x14 <= 32'd0;
        rf_x15 <= 32'd0;
        rf_x16 <= 32'd0;
        rf_x17 <= 32'd0;
        rf_x18 <= 32'd0;
        rf_x19 <= 32'd0;
        rf_x20 <= 32'd0;
        rf_x21 <= 32'd0;
        rf_x22 <= 32'd0;
        rf_x23 <= 32'd0;
        rf_x24 <= 32'd0;
        rf_x25 <= 32'd0;
        rf_x26 <= 32'd0;
        rf_x27 <= 32'd0;
        rf_x28 <= 32'd0;
        rf_x29 <= 32'd0;
        rf_x30 <= 32'd0;
        rf_x31 <= 32'd0;
    end
    else begin
        if (mem_wb_valid && mem_wb_reg_write) begin
            case (mem_wb_rd)
                5'd1:  rf_x1  <= wb_wdata;
                5'd2:  rf_x2  <= wb_wdata;
                5'd3:  rf_x3  <= wb_wdata;
                5'd4:  rf_x4  <= wb_wdata;
                5'd5:  rf_x5  <= wb_wdata;
                5'd6:  rf_x6  <= wb_wdata;
                5'd7:  rf_x7  <= wb_wdata;
                5'd8:  rf_x8  <= wb_wdata;
                5'd9:  rf_x9  <= wb_wdata;
                5'd10: rf_x10 <= wb_wdata;
                5'd11: rf_x11 <= wb_wdata;
                5'd12: rf_x12 <= wb_wdata;
                5'd13: rf_x13 <= wb_wdata;
                5'd14: rf_x14 <= wb_wdata;
                5'd15: rf_x15 <= wb_wdata;
                5'd16: rf_x16 <= wb_wdata;
                5'd17: rf_x17 <= wb_wdata;
                5'd18: rf_x18 <= wb_wdata;
                5'd19: rf_x19 <= wb_wdata;
                5'd20: rf_x20 <= wb_wdata;
                5'd21: rf_x21 <= wb_wdata;
                5'd22: rf_x22 <= wb_wdata;
                5'd23: rf_x23 <= wb_wdata;
                5'd24: rf_x24 <= wb_wdata;
                5'd25: rf_x25 <= wb_wdata;
                5'd26: rf_x26 <= wb_wdata;
                5'd27: rf_x27 <= wb_wdata;
                5'd28: rf_x28 <= wb_wdata;
                5'd29: rf_x29 <= wb_wdata;
                5'd30: rf_x30 <= wb_wdata;
                5'd31: rf_x31 <= wb_wdata;
                default: begin end
            endcase
        end
    end
end*/

/*always @(posedge CLK or negedge RSTN) begin
    if (!RSTN) begin
        for (rf_i = 0; rf_i < 32; rf_i = rf_i + 1) begin
            regs[rf_i] <= 32'd0;
        end
    end
    else begin
        regs[0] <= 32'd0;

        if (mem_wb_valid && mem_wb_reg_write && (mem_wb_rd != 5'd0)) begin
            regs[mem_wb_rd] <= wb_wdata;
        end
    end
end*/
always @(posedge CLK) begin
    if (rf_clear_active) begin
        rf_a[rf_clear_idx[4:0]] <= 32'd0;
        rf_b[rf_clear_idx[4:0]] <= 32'd0;
    end
    else begin
        if (mem_wb_valid && mem_wb_reg_write && (mem_wb_rd != 5'd0)) begin
            rf_a[mem_wb_rd] <= wb_wdata;
            rf_b[mem_wb_rd] <= wb_wdata;
        end
    end
end

always @(posedge CLK or negedge RSTN) begin
    if (!RSTN) begin
        pc_word <= 10'd0;
        fetch_pc_word_q <= 10'd0;
        imem_valid_q <= 1'b0;
        fetch_buf_valid <= 1'b0;
        fetch_buf_pc_word <= 10'd0;
        fetch_buf_instr <= 32'd0;
        if_id_valid <= 1'b0;
        if_id_pc_word <= 10'd0;
        if_id_instr <= 32'd0;

        id_ex_valid <= 1'b0;
        id_ex_pc_word <= 10'd0;
        id_ex_rs1_val <= 32'd0;
        id_ex_rs2_val <= 32'd0;
        id_ex_imm <= 32'd0;
        id_ex_rs1 <= 5'd0;
        id_ex_rs2 <= 5'd0;
        id_ex_rd <= 5'd0;
        id_ex_funct3 <= 3'd0;
        id_ex_funct7 <= 7'd0;
        id_ex_reg_write <= 1'b0;
        id_ex_mem_read <= 1'b0;
        id_ex_mem_write <= 1'b0;
        id_ex_mem_to_reg <= 1'b0;
        id_ex_alu_src_imm <= 1'b0;
        id_ex_branch <= 1'b0;
        id_ex_sub <= 1'b0;

        ex_mem_valid <= 1'b0;
        ex_mem_reg_write <= 1'b0;
        ex_mem_mem_to_reg <= 1'b0;
        ex_mem_rd <= 5'd0;
        ex_mem_alu_result <= 32'd0;

        mem_wb_valid <= 1'b0;
        mem_wb_reg_write <= 1'b0;
        mem_wb_mem_to_reg <= 1'b0;
        mem_wb_rd <= 5'd0;
        mem_wb_alu_result <= 32'd0;
        mem_wb_load_data <= 32'd0;

    end 
    else if (rf_clear_active) begin
    pc_word         <= 10'd0;
    fetch_pc_word_q <= 10'd0;
    imem_valid_q    <= 1'b0;
    fetch_buf_valid <= 1'b0;
    fetch_buf_pc_word <= 10'd0;
    fetch_buf_instr <= 32'd0;

    if_id_valid   <= 1'b0;
    if_id_pc_word <= 10'd0;
    if_id_instr   <= 32'd0;

    id_ex_valid      <= 1'b0;
    id_ex_pc_word    <= 10'd0;
    id_ex_rs1_val    <= 32'd0;
    id_ex_rs2_val    <= 32'd0;
    id_ex_imm        <= 32'd0;
    id_ex_rs1        <= 5'd0;
    id_ex_rs2        <= 5'd0;
    id_ex_rd         <= 5'd0;
    id_ex_funct3     <= 3'd0;
    id_ex_funct7     <= 7'd0;
    id_ex_reg_write  <= 1'b0;
    id_ex_mem_read   <= 1'b0;
    id_ex_mem_write  <= 1'b0;
    id_ex_mem_to_reg <= 1'b0;
    id_ex_alu_src_imm <= 1'b0;
    id_ex_branch     <= 1'b0;
    id_ex_sub        <= 1'b0;

    ex_mem_valid      <= 1'b0;
    ex_mem_reg_write  <= 1'b0;
    ex_mem_mem_to_reg <= 1'b0;
    ex_mem_rd         <= 5'd0;
    ex_mem_alu_result <= 32'd0;

    mem_wb_valid      <= 1'b0;
    mem_wb_reg_write  <= 1'b0;
    mem_wb_mem_to_reg <= 1'b0;
    mem_wb_rd         <= 5'd0;
    mem_wb_alu_result <= 32'd0;
    mem_wb_load_data  <= 32'd0;
end
    else begin
        mem_wb_valid <= ex_mem_valid;
        mem_wb_reg_write <= ex_mem_reg_write;
        mem_wb_mem_to_reg <= ex_mem_mem_to_reg;
        mem_wb_rd <= ex_mem_rd;
        mem_wb_alu_result <= ex_mem_alu_result;
        mem_wb_load_data <= dmem_rdata;

        ex_mem_valid <= id_ex_valid;
        ex_mem_reg_write <= id_ex_reg_write;
        ex_mem_mem_to_reg <= id_ex_mem_to_reg;
        ex_mem_rd <= id_ex_rd;
        ex_mem_alu_result <= ex_alu_result;

        if (branch_taken) begin
            id_ex_valid <= 1'b0;
            id_ex_pc_word <= 10'd0;
            id_ex_rs1_val <= 32'd0;
            id_ex_rs2_val <= 32'd0;
            id_ex_imm <= 32'd0;
            id_ex_rs1 <= 5'd0;
            id_ex_rs2 <= 5'd0;
            id_ex_rd <= 5'd0;
            id_ex_funct3 <= 3'd0;
            id_ex_funct7 <= 7'd0;
            id_ex_reg_write <= 1'b0;
            id_ex_mem_read <= 1'b0;
            id_ex_mem_write <= 1'b0;
            id_ex_mem_to_reg <= 1'b0;
            id_ex_alu_src_imm <= 1'b0;
            id_ex_branch <= 1'b0;
            id_ex_sub <= 1'b0;

            if_id_valid <= 1'b0;
            if_id_pc_word <= 10'd0;
            if_id_instr <= 32'd0;
            fetch_buf_valid <= 1'b0;
            imem_valid_q <= 1'b0;
            pc_word <= branch_target_word;
            fetch_pc_word_q <= branch_target_word;
        end
        else if (decode_stall) begin
            fetch_buf_valid <= imem_valid_q;
            fetch_buf_pc_word <= fetch_pc_word_q;
            fetch_buf_instr <= instr;

            id_ex_valid <= 1'b0;
            id_ex_pc_word <= 10'd0;
            id_ex_rs1_val <= 32'd0;
            id_ex_rs2_val <= 32'd0;
            id_ex_imm <= 32'd0;
            id_ex_rs1 <= 5'd0;
            id_ex_rs2 <= 5'd0;
            id_ex_rd <= 5'd0;
            id_ex_funct3 <= 3'd0;
            id_ex_funct7 <= 7'd0;
            id_ex_reg_write <= 1'b0;
            id_ex_mem_read <= 1'b0;
            id_ex_mem_write <= 1'b0;
            id_ex_mem_to_reg <= 1'b0;
            id_ex_alu_src_imm <= 1'b0;
            id_ex_branch <= 1'b0;
            id_ex_sub <= 1'b0;
        end
        else begin
            id_ex_valid <= if_id_valid && (id_is_load || id_is_store || id_is_addi ||
                                           id_is_addsub || id_is_branch);
            id_ex_pc_word <= if_id_pc_word;
            id_ex_rs1_val <= id_rs1_value;
            id_ex_rs2_val <= id_rs2_value;
            id_ex_imm <= id_is_store ? id_imm_s :
                         (id_is_branch ? id_imm_b : id_imm_i);
            id_ex_rs1 <= id_rs1;
            id_ex_rs2 <= id_rs2;
            id_ex_rd <= id_rd;
            id_ex_funct3 <= id_funct3;
            id_ex_funct7 <= id_funct7;
            id_ex_reg_write <= id_is_load || id_is_addi || id_is_addsub;
            id_ex_mem_read <= id_is_load;
            id_ex_mem_write <= id_is_store;
            id_ex_mem_to_reg <= id_is_load;
            id_ex_alu_src_imm <= id_is_load || id_is_store || id_is_addi;
            id_ex_branch <= id_is_branch;
            id_ex_sub <= id_is_addsub && (id_funct7 == 7'b0100000);

            if (fetch_buf_valid) begin
                if_id_valid <= 1'b1;
                if_id_pc_word <= fetch_buf_pc_word;
                if_id_instr <= fetch_buf_instr;
                fetch_buf_valid <= 1'b0;
            end
            else begin
                if_id_valid <= imem_valid_q;
                if_id_pc_word <= fetch_pc_word_q;
                if_id_instr <= instr;
            end
            fetch_pc_word_q <= pc_word;
            pc_word <= pc_word + 10'd1;
            imem_valid_q <= 1'b1;
        end
    end
end

endmodule
