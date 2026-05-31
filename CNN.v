// ============================================================================
// CNN.v 逐行中文註解版
// 來源：使用者提供的 CNN Verilog 程式
// 說明：每個非空白原始碼行後方加入中文註解，方便組員閱讀與接手。
// 注意：此檔主要供閱讀；若要直接拿去 Vivado 編譯，建議先另存備份。
// ============================================================================

`timescale 1ns / 1ps                                                                                           // L0001: 設定模擬時間單位為 1ns、精度為 1ps

module CNN(                                                                                                    // L0003: 宣告 CNN 模組，負責兩層 3x3 convolution 與 DataMemory Port B 存取
    input         clk,                                                                                         // L0004: CNN 使用的時脈輸入
    input         rstn,                                                                                        // L0005: 低有效 reset，來自 test circuit 的 sys_rstn
    input  [31:0] doutb,                                                                                       // L0006: DataMemory Port B 讀出的 32-bit 資料
    output reg        web,                                                                                     // L0007: DataMemory Port B write enable
    output reg        enb,                                                                                     // L0008: DataMemory Port B enable
    output reg [31:0] dinb,                                                                                    // L0009: CNN 要寫回 DataMemory 的 32-bit 資料
    output reg [9:0]  addr,                                                                                    // L0010: CNN 存取 DataMemory Port B 的 word address
    output reg        done                                                                                     // L0011: CNN 內部完成旗標，S_DONE 後維持為 1
);                                                                                                             // L0012: 結束 module port list

localparam [9:0] INPUT_BASE  = 10'd16;                                                                         // L0014: 原始 input feature map 在 DataMemory 的起始 word 位址
localparam [9:0] INTER_BASE  = 10'd512;                                                                        // L0015: 第一層 convolution intermediate output 的起始 word 位址
localparam [9:0] DEFAULT_OUT = 10'd272;                                                                        // L0016: 最終 output feature map 的預設起始 word 位址
localparam [9:0] CNN_DONE_ADDR = 10'd10;                                                                       // L0017: CNN 完成旗標寫入位址，CPU 會 polling DataMemory[10]
localparam [9:0] START_WAIT_CYCLES = 10'd64;                                                                   // L0018: CNN reset 後先等待的 cycle 數，用來避免太早讀 CPU 尚未寫好的 bias
localparam ACC_W = 20;                                                                                         // L0019: CNN 乘加中間值/accumulator 的 signed bit width

localparam S_WAIT        = 5'd0;                                                                               // L0021: 定義 FSM state：重置釋放後的等待狀態，避免太早讀取尚未準備好的記憶體資料
localparam S_CFG_REQ     = 5'd1;                                                                               // L0022: 定義 FSM state：送出讀取設定值 DataMemory[12] 的請求
localparam S_CFG_CAP     = 5'd2;                                                                               // L0023: 定義 FSM state：擷取設定值，主要取得 feature map size
localparam S_OUT_REQ     = 5'd3;                                                                               // L0024: 定義 FSM state：送出讀取 output base / finish word DataMemory[13] 的請求
localparam S_OUT_CAP     = 5'd4;                                                                               // L0025: 定義 FSM state：擷取 output base；若為 0 則使用預設輸出位址
localparam S_BIAS0_REQ   = 5'd5;                                                                               // L0026: 定義 FSM state：送出讀取第一層 bias0 的請求
localparam S_BIAS0_CAP   = 5'd6;                                                                               // L0027: 定義 FSM state：擷取第一層 bias0
localparam S_BIAS1_REQ   = 5'd7;                                                                               // L0028: 定義 FSM state：送出讀取第二層 bias1 的請求
localparam S_BIAS1_CAP   = 5'd8;                                                                               // L0029: 定義 FSM state：擷取第二層 bias1，接著準備讀取權重
localparam S_W_REQ       = 5'd9;                                                                               // L0030: 定義 FSM state：送出讀取 convolution weight 的請求
localparam S_W_CAP       = 5'd10;                                                                              // L0031: 定義 FSM state：擷取 convolution weight 並存入 w0 或 w1
localparam S_CONV1_INIT  = 5'd11;                                                                              // L0032: 定義 FSM state：初始化第一層 convolution 的尺寸、索引與 buffer 狀態
localparam S_CONV2_INIT  = 5'd12;                                                                              // L0033: 定義 FSM state：初始化第二層 convolution，輸入來源改為 intermediate buffer
localparam S_ROW_MUL     = 5'd13;                                                                              // L0034: 定義 FSM state：row-based 路徑中執行一列三個 pixel 的乘法
localparam S_LB_DRAIN    = 5'd14;                                                                              // L0035: 定義 FSM state：line-buffer pipeline 尾端排空，確保最後一筆 quantize/write-back 完成
localparam S_CALC        = 5'd15;                                                                              // L0036: 定義 FSM state：舊版/row-path 的計算後控制與 sliding window 更新狀態
localparam S_FIN_REQ     = 5'd17;                                                                              // L0037: 定義 FSM state：CNN 完成後寫入 DataMemory[10]=1 作為 done flag
localparam S_DONE        = 5'd19;                                                                              // L0038: 定義 FSM state：CNN 結束狀態，done 持續維持為 1
localparam S_ADDR_CALC   = 5'd22;                                                                              // L0039: 定義 FSM state：準備讀取目前 window 第一個 word 的位址
localparam S_ROW_CAP     = 5'd23;                                                                              // L0040: 定義 FSM state：擷取 row-path 讀出的 word，必要時處理跨 word 視窗
localparam S_ROW_XCAP    = 5'd24;                                                                              // L0041: 定義 FSM state：擷取跨 word 的第二個 word
localparam S_ROW_FLUSH   = 5'd25;                                                                              // L0042: 定義 FSM state：把 row-path 最後一列乘積累加進 acc
localparam S_BUF_REQ     = 5'd26;                                                                              // L0043: 定義 FSM state：送出 line buffer 載入 row word 的讀取請求
localparam S_BUF_CAP     = 5'd27;                                                                              // L0044: 定義 FSM state：擷取 row word 並寫入 row_buf0/1/2
localparam S_DOT         = 5'd28;                                                                              // L0045: 定義 FSM state：line-buffer 路徑中對 3x3 window 的 9 個乘法啟動暫存
localparam S_SUM         = 5'd29;                                                                              // L0046: 定義 FSM state：把 9 個乘法結果分三組加總，並推進 pipeline
localparam S_ROW_QUANT   = 5'd30;                                                                              // L0047: 定義 FSM state：row-path 將 accumulator 做 quantize
localparam S_LB_QUANT    = 5'd31;                                                                              // L0048: 定義 FSM state：line-buffer 路徑將 sum 做 quantize 並安排 write-back

reg [4:0] state;                                                                                               // L0050: CNN FSM 目前狀態
reg [9:0] wait_count;                                                                                          // L0051: S_WAIT 中使用的啟動等待 counter
reg layer;                                                                                                     // L0052: 目前 convolution 層數；0=第一層，1=第二層
reg [2:0] weight_addr;                                                                                         // L0053: 讀取 weight words 的索引

reg [5:0] feature_size;                                                                                        // L0055: 原始 input feature map 邊長 N
reg [5:0] in_size;                                                                                             // L0056: 目前 layer 的 input feature map 邊長
reg [5:0] out_size;                                                                                            // L0057: 目前 layer 的 output feature map 邊長
reg [9:0] total_elems;                                                                                         // L0058: 目前 layer 要產生的 output element 總數
reg [9:0] elem_idx;                                                                                            // L0059: 目前正在處理的 output element index
reg [5:0] row;                                                                                                 // L0060: 目前 output element 所在 row
reg [5:0] col;                                                                                                 // L0061: 目前 output element 所在 column
reg [9:0] row_base;                                                                                            // L0062: 目前 input row 起始 element index
reg [9:0] output_base;                                                                                         // L0063: 最終 output 在 DataMemory 的起始位址
reg [31:0] pack_word;                                                                                          // L0064: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
reg signed [ACC_W-1:0] acc;                                                                                    // L0065: CNN 乘加中間值/accumulator 的 signed bit width
reg signed [7:0] result_q;                                                                                     // L0066: row-path quantize 後的 8-bit 結果
reg signed [7:0] bias0;                                                                                        // L0067: 第一層 convolution bias，8-bit Q1.6
reg signed [7:0] bias1;                                                                                        // L0068: 第二層 convolution bias，8-bit Q1.6

reg signed [7:0] w0 [0:8];                                                                                     // L0070: 第一層 3x3 convolution weights
reg signed [7:0] w1 [0:8];                                                                                     // L0071: 第二層 3x3 convolution weights

reg signed [7:0] row_w0_c;                                                                                     // L0073: 目前 row_scan 對應的第 0 個 row weight
reg signed [7:0] row_w1_c;                                                                                     // L0074: 目前 row_scan 對應的第 1 個 row weight
reg signed [7:0] row_w2_c;                                                                                     // L0075: 目前 row_scan 對應的第 2 個 row weight
reg [9:0] read_addr_q;                                                                                         // L0076: 目前 row-path 要讀取的 DataMemory word address
reg [1:0] read_byte_sel_q;                                                                                     // L0077: 目前 row-path window 在 word 內的 byte offset
reg [1:0] row_scan;                                                                                            // L0078: row-path 正在掃描 3x3 window 的第幾列
reg       cross_word_q;                                                                                        // L0079: 目前 3-byte window 是否跨越 32-bit word 邊界
reg [31:0] row_word0_q;                                                                                        // L0080: 跨 word 情況下暫存第一個 word
reg signed [ACC_W-1:0] prod0_q;                                                                                // L0081: row-path 第 0 個乘積暫存
reg signed [ACC_W-1:0] prod1_q;                                                                                // L0082: row-path 第 1 個乘積暫存
reg signed [ACC_W-1:0] prod2_q;                                                                                // L0083: row-path 第 2 個乘積暫存
reg prod_valid_q;                                                                                              // L0084: row-path 乘積暫存是否有效
reg signed [7:0] pix0_q;                                                                                       // L0085: row-path 目前列第 0 個 pixel
reg signed [7:0] pix1_q;                                                                                       // L0086: row-path 目前列第 1 個 pixel
reg signed [7:0] pix2_q;                                                                                       // L0087: row-path 目前列第 2 個 pixel
reg signed [7:0] row_w0_q;                                                                                     // L0088: row-path 第 0 個 weight 暫存
reg signed [7:0] row_w1_q;                                                                                     // L0089: row-path 第 1 個 weight 暫存
reg signed [7:0] row_w2_q;                                                                                     // L0090: row-path 第 2 個 weight 暫存

reg [31:0] row_buf0 [0:8];                                                                                     // L0092: line-buffer 的 top row physical buffer
reg [31:0] row_buf1 [0:8];                                                                                     // L0093: line-buffer 的 middle row physical buffer
reg [31:0] row_buf2 [0:8];                                                                                     // L0094: line-buffer 的 bottom row physical buffer
reg [1:0]  row0_sel;                                                                                           // L0095: row_buf0 的 byte alignment offset
reg [1:0]  row1_sel;                                                                                           // L0096: row_buf1 的 byte alignment offset
reg [1:0]  row2_sel;                                                                                           // L0097: row_buf2 的 byte alignment offset
reg [1:0]  load_row_sel;                                                                                       // L0098: 目前正在載入 row_buf0/1/2 的選擇
reg [3:0]  load_word_idx;                                                                                      // L0099: 目前載入一列中的第幾個 32-bit word
reg [3:0]  load_words_q;                                                                                       // L0100: 目前 row 需要載入的 word 數量
reg [9:0] load_row_base;                                                                                       // L0101: 目前要載入 row 的 element base index
reg signed [7:0] win00_q;                                                                                      // L0102: 3x3 window 第 0 row 第 0 col pixel
reg signed [7:0] win01_q;                                                                                      // L0103: 3x3 window 第 0 row 第 1 col pixel
reg signed [7:0] win02_q;                                                                                      // L0104: 3x3 window 第 0 row 第 2 col pixel
reg signed [7:0] win10_q;                                                                                      // L0105: 3x3 window 第 1 row 第 0 col pixel
reg signed [7:0] win11_q;                                                                                      // L0106: 3x3 window 第 1 row 第 1 col pixel
reg signed [7:0] win12_q;                                                                                      // L0107: 3x3 window 第 1 row 第 2 col pixel
reg signed [7:0] win20_q;                                                                                      // L0108: 3x3 window 第 2 row 第 0 col pixel
reg signed [7:0] win21_q;                                                                                      // L0109: 3x3 window 第 2 row 第 1 col pixel
reg signed [7:0] win22_q;                                                                                      // L0110: 3x3 window 第 2 row 第 2 col pixel
reg signed [ACC_W-1:0] dot0_q;                                                                                 // L0111: 3x3 dot product 第 0 個乘積暫存
reg signed [ACC_W-1:0] dot1_q;                                                                                 // L0112: 3x3 dot product 第 1 個乘積暫存
reg signed [ACC_W-1:0] dot2_q;                                                                                 // L0113: 3x3 dot product 第 2 個乘積暫存
reg signed [ACC_W-1:0] dot3_q;                                                                                 // L0114: 3x3 dot product 第 3 個乘積暫存
reg signed [ACC_W-1:0] dot4_q;                                                                                 // L0115: 3x3 dot product 第 4 個乘積暫存
reg signed [ACC_W-1:0] dot5_q;                                                                                 // L0116: 3x3 dot product 第 5 個乘積暫存
reg signed [ACC_W-1:0] dot6_q;                                                                                 // L0117: 3x3 dot product 第 6 個乘積暫存
reg signed [ACC_W-1:0] dot7_q;                                                                                 // L0118: 3x3 dot product 第 7 個乘積暫存
reg signed [ACC_W-1:0] dot8_q;                                                                                 // L0119: 3x3 dot product 第 8 個乘積暫存
reg signed [ACC_W-1:0] sum0_q;                                                                                 // L0120: dot0~dot2 的部分和
reg signed [ACC_W-1:0] sum1_q;                                                                                 // L0121: dot3~dot5 的部分和
reg signed [ACC_W-1:0] sum2_q;                                                                                 // L0122: dot6~dot8 加 bias 的部分和
reg row_path_pixel;                                                                                            // L0123: 第一個 window 經 row-path 初始化後，切入 line-buffer path 的旗標
reg pipe_launch_q;                                                                                             // L0124: line-buffer pipeline 是否繼續發射下一個 dot 計算
reg dot_valid_q;                                                                                               // L0125: dot stage 輸出是否有效
reg sum_valid_q;                                                                                               // L0126: sum stage 輸出是否有效
reg [9:0] dot_elem_idx_q;                                                                                      // L0127: dot stage 對應的 output element index
reg [9:0] sum_elem_idx_q;                                                                                      // L0128: sum stage 對應的 output element index
reg dot_word_done_q;                                                                                           // L0129: dot stage 這個 element 是否應該完成一個 32-bit output word
reg sum_word_done_q;                                                                                           // L0130: sum stage 這個 element 是否應該完成一個 32-bit output word
reg dot_last_q;                                                                                                // L0131: dot stage 這個 element 是否為本 layer 最後一個 output
reg sum_last_q;                                                                                                // L0132: sum stage 這個 element 是否為本 layer 最後一個 output
reg dot_row_last_q;                                                                                            // L0133: dot stage 這個 element 是否為該 output row 最後一欄
reg sum_row_last_q;                                                                                            // L0134: sum stage 這個 element 是否為該 output row 最後一欄
reg quant_valid_q;                                                                                             // L0135: quantize stage 是否有有效 output 等待 packing/write-back
reg signed [7:0] quant_result_q;                                                                               // L0136: quantize 後的 8-bit output 暫存
reg [1:0] quant_elem_sel_q;                                                                                    // L0137: quantized output 在 32-bit pack_word 中的 byte 位置
reg quant_word_done_q;                                                                                         // L0138: quantized output 是否完成一個 32-bit word
reg [9:0] quant_write_addr_q;                                                                                  // L0139: quantized output 對應的 DataMemory write address
reg wb_valid_q;                                                                                                // L0140: write-back stage 是否有有效資料要寫 Port B
reg [9:0] wb_addr_q;                                                                                           // L0141: write-back stage 的 DataMemory address
reg [31:0] wb_data_q;                                                                                          // L0142: write-back stage 的 32-bit data
reg [4:0] drain_state_q;                                                                                       // L0143: pipeline drain 結束後要跳回的下一個 state

wire signed [ACC_W-1:0] bias0_q12 = {{(ACC_W-8){bias0[7]}}, bias0} <<< 6;                                      // L0145: bias0 轉為 Q?.12 後的 accumulator 格式
wire signed [ACC_W-1:0] bias1_q12 = {{(ACC_W-8){bias1[7]}}, bias1} <<< 6;                                      // L0146: bias1 轉為 Q?.12 後的 accumulator 格式

wire last_elem = (elem_idx == (total_elems - 10'd1));                                                          // L0148: 目前 layer 要產生的 output element 總數
wire word_done = (elem_idx[1:0] == 2'd3) || last_elem;                                                         // L0149: 目前是否剛好湊滿 4 bytes 或到達最後 element
wire [9:0] source_base = layer ? INTER_BASE : INPUT_BASE;                                                      // L0150: 目前 layer 的資料來源 base address；layer0=input，layer1=intermediate
wire row_last_col = (col == (out_size - 6'd1));                                                                // L0151: 目前 col 是否為 output row 最後一欄
wire [5:0] next_pixel_col = row_last_col ? 6'd0 : (col + 6'd1);                                                // L0152: 下一個 output pixel 的 column
wire [9:0] next_pixel_row_base = row_last_col ? (row_base + {4'd0, in_size}) : row_base;                       // L0153: 下一個 output pixel 對應的 input row base
wire [9:0] next_pixel_first_index = next_pixel_row_base + {4'd0, next_pixel_col};                              // L0154: 下一個 output pixel 左上角 input index
wire [9:0] next_read_addr = source_base + next_pixel_first_index[9:2];                                         // L0155: 下一個 output pixel 左上角 input index
wire [1:0] next_read_sel = next_pixel_first_index[1:0];                                                        // L0156: 下一個 output pixel 左上角 input index
wire next_cross_word = next_pixel_first_index[1];                                                              // L0157: 下一個 output pixel 左上角 input index
wire [9:0] curr_pixel_first_index = row_base + {4'd0, col};                                                    // L0158: 目前 output pixel 左上角 input index
wire [9:0] curr_read_addr = source_base + curr_pixel_first_index[9:2];                                         // L0159: 目前 output pixel 左上角 input index
wire [1:0] curr_read_sel = curr_pixel_first_index[1:0];                                                        // L0160: 目前 output pixel 左上角 input index
wire curr_cross_word = curr_pixel_first_index[1];                                                              // L0161: 目前 output pixel 左上角 input index
wire [7:0] row_advance_sum = {6'd0, read_byte_sel_q} + {2'd0, in_size};                                        // L0162: 目前 row-path window 在 word 內的 byte offset
wire [9:0] row_advance_addr = read_addr_q + {5'd0, row_advance_sum[7:2]};                                      // L0163: row-path 往下一列後的 word address
wire [1:0] row_advance_sel = row_advance_sum[1:0];                                                             // L0164: row-path 往下一列時 byte offset 加上 in_size 的總和
wire [31:0] dot_word0_c = (state == S_ROW_XCAP) ? row_word0_q : doutb;                                         // L0165: 跨 word 情況下暫存第一個 word
wire [31:0] dot_word1_c = (state == S_ROW_XCAP) ? doutb : 32'd0;                                               // L0166: dot/window 跨 word 時使用的第二個 word
wire signed [7:0] dot_pix0_c = get_window_byte(dot_word0_c, dot_word1_c, read_byte_sel_q, 2'd0);               // L0167: 目前 row-path window 在 word 內的 byte offset
wire signed [7:0] dot_pix1_c = get_window_byte(dot_word0_c, dot_word1_c, read_byte_sel_q, 2'd1);               // L0168: 目前 row-path window 在 word 內的 byte offset
wire signed [7:0] dot_pix2_c = get_window_byte(dot_word0_c, dot_word1_c, read_byte_sel_q, 2'd2);               // L0169: 目前 row-path window 在 word 內的 byte offset
wire signed [ACC_W-1:0] prod0_c = mul_q(dot_pix0_c, row_w0_c);                                                 // L0170: 目前 window 的第 0 個 pixel 組合值
wire signed [ACC_W-1:0] prod1_c = mul_q(dot_pix1_c, row_w1_c);                                                 // L0171: 目前 window 的第 1 個 pixel 組合值
wire signed [ACC_W-1:0] prod2_c = mul_q(dot_pix2_c, row_w2_c);                                                 // L0172: 目前 window 的第 2 個 pixel 組合值
wire signed [ACC_W-1:0] prod_sum_q = prod0_q + prod1_q + prod2_q;                                              // L0173: row-path 三個乘積的部分和
wire signed [ACC_W-1:0] final_acc_c = prod_valid_q ? (acc + prod_sum_q) : acc;                                 // L0174: row-path 乘積暫存是否有效
wire [9:0] next_top_row_base = row_base + {4'd0, in_size};                                                     // L0175: 滑到下一個 output row 時新的 top row base
wire [9:0] next_bottom_load_base = row_base + {4'd0, in_size} + {3'd0, in_size, 1'b0};                         // L0176: 滑到下一個 output row 時需要載入的新 bottom row base
wire [1:0] next_bottom_load_sel = next_bottom_load_base[1:0];                                                  // L0177: 滑到下一個 output row 時需要載入的新 bottom row base
wire [3:0] next_bottom_load_words = row_words_for(next_bottom_load_sel, in_size);                              // L0178: 新 bottom row 需要載入的 word 數量
wire [9:0] load_addr = source_base + load_row_base[9:2] + {6'd0, load_word_idx};                               // L0179: 目前載入一列中的第幾個 32-bit word
wire [3:0] load_word_idx_next = load_word_idx + 4'd1;                                                          // L0180: 下一個要載入的 row word index
wire load_row_done = (load_word_idx == (load_words_q - 4'd1));                                                 // L0181: 目前載入一列中的第幾個 32-bit word
wire [9:0] load_next_row_base = load_row_base + {4'd0, in_size};                                               // L0182: 下一列 row 的 base index
wire [1:0] load_next_row_sel = load_next_row_base[1:0];                                                        // L0183: 下一列 row 的 base index
wire signed [7:0] lb00_c = win00_q;                                                                            // L0184: 3x3 window 第 0 row 第 0 col pixel
wire signed [7:0] lb01_c = win01_q;                                                                            // L0185: 3x3 window 第 0 row 第 1 col pixel
wire signed [7:0] lb02_c = win02_q;                                                                            // L0186: 3x3 window 第 0 row 第 2 col pixel
wire signed [7:0] lb10_c = win10_q;                                                                            // L0187: 3x3 window 第 1 row 第 0 col pixel
wire signed [7:0] lb11_c = win11_q;                                                                            // L0188: 3x3 window 第 1 row 第 1 col pixel
wire signed [7:0] lb12_c = win12_q;                                                                            // L0189: 3x3 window 第 1 row 第 2 col pixel
wire signed [7:0] lb20_c = win20_q;                                                                            // L0190: 3x3 window 第 2 row 第 0 col pixel
wire signed [7:0] lb21_c = win21_q;                                                                            // L0191: 3x3 window 第 2 row 第 1 col pixel
wire signed [7:0] lb22_c = win22_q;                                                                            // L0192: 3x3 window 第 2 row 第 2 col pixel
wire signed [7:0] dot_w0_c = layer ? w1[0] : w0[0];                                                            // L0193: 目前 layer 的 weight[0]
wire signed [7:0] dot_w1_c = layer ? w1[1] : w0[1];                                                            // L0194: 目前 layer 的 weight[1]
wire signed [7:0] dot_w2_c = layer ? w1[2] : w0[2];                                                            // L0195: 目前 layer 的 weight[2]
wire signed [7:0] dot_w3_c = layer ? w1[3] : w0[3];                                                            // L0196: 目前 layer 的 weight[3]
wire signed [7:0] dot_w4_c = layer ? w1[4] : w0[4];                                                            // L0197: 目前 layer 的 weight[4]
wire signed [7:0] dot_w5_c = layer ? w1[5] : w0[5];                                                            // L0198: 目前 layer 的 weight[5]
wire signed [7:0] dot_w6_c = layer ? w1[6] : w0[6];                                                            // L0199: 目前 layer 的 weight[6]
wire signed [7:0] dot_w7_c = layer ? w1[7] : w0[7];                                                            // L0200: 目前 layer 的 weight[7]
wire signed [7:0] dot_w8_c = layer ? w1[8] : w0[8];                                                            // L0201: 目前 layer 的 weight[8]
wire signed [7:0] slide00_c = win01_q;                                                                         // L0202: sliding window 往右移後的新 win00
wire signed [7:0] slide01_c = win02_q;                                                                         // L0203: sliding window 往右移後的新 win01
wire signed [7:0] slide02_c = get_buf0_byte(col + 6'd3);                                                       // L0204: sliding window 往右移後的新 win02，由 row_buf0 取新 column
wire signed [7:0] slide10_c = win11_q;                                                                         // L0205: sliding window 往右移後的新 win10
wire signed [7:0] slide11_c = win12_q;                                                                         // L0206: sliding window 往右移後的新 win11
wire signed [7:0] slide12_c = get_buf1_byte(col + 6'd3);                                                       // L0207: sliding window 往右移後的新 win12，由 row_buf1 取新 column
wire signed [7:0] slide20_c = win21_q;                                                                         // L0208: sliding window 往右移後的新 win20
wire signed [7:0] slide21_c = win22_q;                                                                         // L0209: sliding window 往右移後的新 win21
wire signed [7:0] slide22_c = get_buf2_byte(col + 6'd3);                                                       // L0210: sliding window 往右移後的新 win22，由 row_buf2 取新 column
wire signed [ACC_W-1:0] conv_acc_c = sum0_q + sum1_q + sum2_q;                                                 // L0211: line-buffer pipeline 的完整 convolution accumulator
wire signed [7:0] conv_result_c = quantize_q12(conv_acc_c);                                                    // L0212: line-buffer accumulator quantize 後的 8-bit 結果
wire [31:0] pack_next = put_byte(pack_word, elem_idx[1:0], result_q);                                          // L0213: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
wire [31:0] pipe_pack_next = put_byte(pack_word, sum_elem_idx_q[1:0], conv_result_c);                          // L0214: sum stage 對應的 output element index
wire [31:0] quant_pack_next = put_byte(pack_word, quant_elem_sel_q, quant_result_q);                           // L0215: quantized output 在 32-bit pack_word 中的 byte 位置
wire [9:0] pipe_write_addr = (layer ? output_base : INTER_BASE) + sum_elem_idx_q[9:2];                         // L0216: line-buffer pipeline output 對應的 write address

integer i;                                                                                                     // L0218: 宣告整數變數，主要作為 for-loop index

function signed [ACC_W-1:0] mul_q;                                                                             // L0220: 宣告 function：8-bit signed 乘法，輸出 sign-extended 到 ACC_W 寬度
    input signed [7:0] a;                                                                                      // L0221: 宣告模組輸入/輸出埠
    input signed [7:0] b;                                                                                      // L0222: 宣告模組輸入/輸出埠
    reg signed [15:0] product;                                                                                 // L0223: 宣告暫存器，用於 sequential logic 或 pipeline 暫存
    begin                                                                                                      // L0224: 開始一個 Verilog 程式區塊
        product = a * b;                                                                                       // L0225: 執行資料或控制訊號指派
        mul_q = {{(ACC_W-16){product[15]}}, product};                                                          // L0226: CNN 乘加中間值/accumulator 的 signed bit width
    end                                                                                                        // L0227: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0228: 結束目前 function 定義

function [9:0] row_offset_for;                                                                                 // L0230: 宣告 function：依 row index 回傳 row offset；目前主要保留作 address 輔助
    input [1:0] idx;                                                                                           // L0231: 宣告模組輸入/輸出埠
    begin                                                                                                      // L0232: 開始一個 Verilog 程式區塊
        case (idx)                                                                                             // L0233: 開始 case 分支，依條件選擇不同控制/資料路徑
            2'd0: row_offset_for = 10'd0;                                                                      // L0234: 執行資料或控制訊號指派
            2'd1: row_offset_for = {4'd0, in_size};                                                            // L0235: 目前 layer 的 input feature map 邊長
            default: row_offset_for = {3'd0, in_size, 1'b0};                                                   // L0236: 目前 layer 的 input feature map 邊長
        endcase                                                                                                // L0237: 結束 case 分支
    end                                                                                                        // L0238: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0239: 結束目前 function 定義

function signed [7:0] get_byte;                                                                                // L0241: 宣告 function：從 32-bit word 中依 byte select 取出 signed 8-bit
    input [31:0] word;                                                                                         // L0242: 宣告模組輸入/輸出埠
    input [1:0] sel;                                                                                           // L0243: 宣告模組輸入/輸出埠
    begin                                                                                                      // L0244: 開始一個 Verilog 程式區塊
        case (sel)                                                                                             // L0245: 開始 case 分支，依條件選擇不同控制/資料路徑
            2'd0: get_byte = word[31:24];                                                                      // L0246: 執行資料或控制訊號指派
            2'd1: get_byte = word[23:16];                                                                      // L0247: 執行資料或控制訊號指派
            2'd2: get_byte = word[15:8];                                                                       // L0248: 執行資料或控制訊號指派
            default: get_byte = word[7:0];                                                                     // L0249: 執行資料或控制訊號指派
        endcase                                                                                                // L0250: 結束 case 分支
    end                                                                                                        // L0251: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0252: 結束目前 function 定義

function [3:0] row_words_for;                                                                                  // L0254: 宣告 function：計算一列資料從指定 byte alignment 開始需要讀幾個 32-bit word
    input [1:0] start_sel;                                                                                     // L0255: 宣告模組輸入/輸出埠
    input [5:0] size;                                                                                          // L0256: 宣告模組輸入/輸出埠
    reg [7:0] span;                                                                                            // L0257: 宣告暫存器，用於 sequential logic 或 pipeline 暫存
    begin                                                                                                      // L0258: 開始一個 Verilog 程式區塊
        span = {6'd0, start_sel} + {2'd0, size} + 8'd3;                                                        // L0259: 執行資料或控制訊號指派
        row_words_for = span[7:2];                                                                             // L0260: 執行資料或控制訊號指派
    end                                                                                                        // L0261: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0262: 結束目前 function 定義

function signed [7:0] get_buf0_byte;                                                                           // L0264: 宣告 function：從 row_buf0 依 column 取出對應 byte
    input [5:0] c;                                                                                             // L0265: 宣告模組輸入/輸出埠
    reg [7:0] pos;                                                                                             // L0266: 宣告暫存器，用於 sequential logic 或 pipeline 暫存
    begin                                                                                                      // L0267: 開始一個 Verilog 程式區塊
        pos = {6'd0, row0_sel} + {2'd0, c};                                                                    // L0268: row_buf0 的 byte alignment offset
        case (pos[5:2])                                                                                        // L0269: 開始 case 分支，依條件選擇不同控制/資料路徑
            4'd0: get_buf0_byte = get_byte(row_buf0[0], pos[1:0]);                                             // L0270: line-buffer 的 top row physical buffer
            4'd1: get_buf0_byte = get_byte(row_buf0[1], pos[1:0]);                                             // L0271: line-buffer 的 top row physical buffer
            4'd2: get_buf0_byte = get_byte(row_buf0[2], pos[1:0]);                                             // L0272: line-buffer 的 top row physical buffer
            4'd3: get_buf0_byte = get_byte(row_buf0[3], pos[1:0]);                                             // L0273: line-buffer 的 top row physical buffer
            4'd4: get_buf0_byte = get_byte(row_buf0[4], pos[1:0]);                                             // L0274: line-buffer 的 top row physical buffer
            4'd5: get_buf0_byte = get_byte(row_buf0[5], pos[1:0]);                                             // L0275: line-buffer 的 top row physical buffer
            4'd6: get_buf0_byte = get_byte(row_buf0[6], pos[1:0]);                                             // L0276: line-buffer 的 top row physical buffer
            4'd7: get_buf0_byte = get_byte(row_buf0[7], pos[1:0]);                                             // L0277: line-buffer 的 top row physical buffer
            default: get_buf0_byte = get_byte(row_buf0[8], pos[1:0]);                                          // L0278: line-buffer 的 top row physical buffer
        endcase                                                                                                // L0279: 結束 case 分支
    end                                                                                                        // L0280: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0281: 結束目前 function 定義

function signed [7:0] get_buf1_byte;                                                                           // L0283: 宣告 function：從 row_buf1 依 column 取出對應 byte
    input [5:0] c;                                                                                             // L0284: 宣告模組輸入/輸出埠
    reg [7:0] pos;                                                                                             // L0285: 宣告暫存器，用於 sequential logic 或 pipeline 暫存
    begin                                                                                                      // L0286: 開始一個 Verilog 程式區塊
        pos = {6'd0, row1_sel} + {2'd0, c};                                                                    // L0287: row_buf1 的 byte alignment offset
        case (pos[5:2])                                                                                        // L0288: 開始 case 分支，依條件選擇不同控制/資料路徑
            4'd0: get_buf1_byte = get_byte(row_buf1[0], pos[1:0]);                                             // L0289: line-buffer 的 middle row physical buffer
            4'd1: get_buf1_byte = get_byte(row_buf1[1], pos[1:0]);                                             // L0290: line-buffer 的 middle row physical buffer
            4'd2: get_buf1_byte = get_byte(row_buf1[2], pos[1:0]);                                             // L0291: line-buffer 的 middle row physical buffer
            4'd3: get_buf1_byte = get_byte(row_buf1[3], pos[1:0]);                                             // L0292: line-buffer 的 middle row physical buffer
            4'd4: get_buf1_byte = get_byte(row_buf1[4], pos[1:0]);                                             // L0293: line-buffer 的 middle row physical buffer
            4'd5: get_buf1_byte = get_byte(row_buf1[5], pos[1:0]);                                             // L0294: line-buffer 的 middle row physical buffer
            4'd6: get_buf1_byte = get_byte(row_buf1[6], pos[1:0]);                                             // L0295: line-buffer 的 middle row physical buffer
            4'd7: get_buf1_byte = get_byte(row_buf1[7], pos[1:0]);                                             // L0296: line-buffer 的 middle row physical buffer
            default: get_buf1_byte = get_byte(row_buf1[8], pos[1:0]);                                          // L0297: line-buffer 的 middle row physical buffer
        endcase                                                                                                // L0298: 結束 case 分支
    end                                                                                                        // L0299: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0300: 結束目前 function 定義

function signed [7:0] get_buf2_byte;                                                                           // L0302: 宣告 function：從 row_buf2 依 column 取出對應 byte
    input [5:0] c;                                                                                             // L0303: 宣告模組輸入/輸出埠
    reg [7:0] pos;                                                                                             // L0304: 宣告暫存器，用於 sequential logic 或 pipeline 暫存
    begin                                                                                                      // L0305: 開始一個 Verilog 程式區塊
        pos = {6'd0, row2_sel} + {2'd0, c};                                                                    // L0306: row_buf2 的 byte alignment offset
        case (pos[5:2])                                                                                        // L0307: 開始 case 分支，依條件選擇不同控制/資料路徑
            4'd0: get_buf2_byte = get_byte(row_buf2[0], pos[1:0]);                                             // L0308: line-buffer 的 bottom row physical buffer
            4'd1: get_buf2_byte = get_byte(row_buf2[1], pos[1:0]);                                             // L0309: line-buffer 的 bottom row physical buffer
            4'd2: get_buf2_byte = get_byte(row_buf2[2], pos[1:0]);                                             // L0310: line-buffer 的 bottom row physical buffer
            4'd3: get_buf2_byte = get_byte(row_buf2[3], pos[1:0]);                                             // L0311: line-buffer 的 bottom row physical buffer
            4'd4: get_buf2_byte = get_byte(row_buf2[4], pos[1:0]);                                             // L0312: line-buffer 的 bottom row physical buffer
            4'd5: get_buf2_byte = get_byte(row_buf2[5], pos[1:0]);                                             // L0313: line-buffer 的 bottom row physical buffer
            4'd6: get_buf2_byte = get_byte(row_buf2[6], pos[1:0]);                                             // L0314: line-buffer 的 bottom row physical buffer
            4'd7: get_buf2_byte = get_byte(row_buf2[7], pos[1:0]);                                             // L0315: line-buffer 的 bottom row physical buffer
            default: get_buf2_byte = get_byte(row_buf2[8], pos[1:0]);                                          // L0316: line-buffer 的 bottom row physical buffer
        endcase                                                                                                // L0317: 結束 case 分支
    end                                                                                                        // L0318: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0319: 結束目前 function 定義

function signed [7:0] get_window_byte;                                                                         // L0321: 宣告 function：從一或兩個 32-bit word 中取出 3-byte window 的指定 tap
    input [31:0] word0;                                                                                        // L0322: 宣告模組輸入/輸出埠
    input [31:0] word1;                                                                                        // L0323: 宣告模組輸入/輸出埠
    input [1:0] start_sel;                                                                                     // L0324: 宣告模組輸入/輸出埠
    input [1:0] tap_col;                                                                                       // L0325: 宣告模組輸入/輸出埠
    begin                                                                                                      // L0326: 開始一個 Verilog 程式區塊
        case (tap_col)                                                                                         // L0327: 開始 case 分支，依條件選擇不同控制/資料路徑
            2'd0: get_window_byte = get_byte(word0, start_sel);                                                // L0328: 執行資料或控制訊號指派
            2'd1: get_window_byte = (start_sel == 2'd3) ?                                                      // L0329: 執行資料或控制訊號指派
                                     get_byte(word1, 2'd0) :                                                   // L0330: Verilog 語句，維持 CNN FSM 或資料路徑運作
                                     get_byte(word0, start_sel + 2'd1);                                        // L0331: Verilog 語句，維持 CNN FSM 或資料路徑運作
            default: get_window_byte = (start_sel[1] == 1'b0) ?                                                // L0332: 執行資料或控制訊號指派
                                       get_byte(word0, start_sel + 2'd2) :                                     // L0333: Verilog 語句，維持 CNN FSM 或資料路徑運作
                                       get_byte(word1, {1'b0, start_sel[0]});                                  // L0334: Verilog 語句，維持 CNN FSM 或資料路徑運作
        endcase                                                                                                // L0335: 結束 case 分支
    end                                                                                                        // L0336: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0337: 結束目前 function 定義

function [31:0] put_byte;                                                                                      // L0339: 宣告 function：把 8-bit output 放入 32-bit pack word 的指定 byte 位置
    input [31:0] word;                                                                                         // L0340: 宣告模組輸入/輸出埠
    input [1:0] sel;                                                                                           // L0341: 宣告模組輸入/輸出埠
    input [7:0] value;                                                                                         // L0342: 宣告模組輸入/輸出埠
    begin                                                                                                      // L0343: 開始一個 Verilog 程式區塊
        case (sel)                                                                                             // L0344: 開始 case 分支，依條件選擇不同控制/資料路徑
            2'd0: put_byte = {value, word[23:0]};                                                              // L0345: 執行資料或控制訊號指派
            2'd1: put_byte = {word[31:24], value, word[15:0]};                                                 // L0346: 執行資料或控制訊號指派
            2'd2: put_byte = {word[31:16], value, word[7:0]};                                                  // L0347: 執行資料或控制訊號指派
            default: put_byte = {word[31:8], value};                                                           // L0348: 執行資料或控制訊號指派
        endcase                                                                                                // L0349: 結束 case 分支
    end                                                                                                        // L0350: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0351: 結束目前 function 定義

function signed [7:0] quantize_q12;                                                                            // L0353: 宣告 function：把 Q?.12 accumulator 做 ties-to-even rounding 並 saturation 成 signed 8-bit
    input signed [ACC_W-1:0] value;                                                                            // L0354: CNN 乘加中間值/accumulator 的 signed bit width
    reg signed [ACC_W-1:0] shifted;                                                                            // L0355: CNN 乘加中間值/accumulator 的 signed bit width
    reg [5:0] fraction;                                                                                        // L0356: 宣告暫存器，用於 sequential logic 或 pipeline 暫存
    reg round_up;                                                                                              // L0357: 宣告暫存器，用於 sequential logic 或 pipeline 暫存
    reg signed [ACC_W-1:0] rounded;                                                                            // L0358: CNN 乘加中間值/accumulator 的 signed bit width
    reg signed [ACC_W-1:0] qmax;                                                                               // L0359: CNN 乘加中間值/accumulator 的 signed bit width
    reg signed [ACC_W-1:0] qmin;                                                                               // L0360: CNN 乘加中間值/accumulator 的 signed bit width
    begin                                                                                                      // L0361: 開始一個 Verilog 程式區塊
        qmax = {{(ACC_W-8){1'b0}}, 8'sh7f};                                                                    // L0362: CNN 乘加中間值/accumulator 的 signed bit width
        qmin = {{(ACC_W-8){1'b1}}, 8'sh80};                                                                    // L0363: CNN 乘加中間值/accumulator 的 signed bit width
        shifted = value >>> 6;                                                                                 // L0364: 執行資料或控制訊號指派
        fraction = value[5:0];                                                                                 // L0365: 執行資料或控制訊號指派
        round_up = (fraction > 6'd32) ||                                                                       // L0366: 執行資料或控制訊號指派
                   ((fraction == 6'd32) && (shifted[0] == 1'b1));                                              // L0367: 執行資料或控制訊號指派
        rounded = shifted + {{(ACC_W-1){1'b0}}, round_up};                                                     // L0368: CNN 乘加中間值/accumulator 的 signed bit width

        if (rounded > qmax) begin                                                                              // L0370: 條件判斷，依目前狀態或旗標選擇不同流程
            quantize_q12 = 8'sh7f;                                                                             // L0371: 執行資料或控制訊號指派
        end                                                                                                    // L0372: 結束目前 Verilog 程式區塊
        else if (rounded < qmin) begin                                                                         // L0373: 前一個條件不成立時，檢查下一個條件分支
            quantize_q12 = -8'sd128;                                                                           // L0374: 執行資料或控制訊號指派
        end                                                                                                    // L0375: 結束目前 Verilog 程式區塊
        else begin                                                                                             // L0376: 前面條件皆不成立時執行的預設分支
            quantize_q12 = rounded[7:0];                                                                       // L0377: 執行資料或控制訊號指派
        end                                                                                                    // L0378: 結束目前 Verilog 程式區塊
    end                                                                                                        // L0379: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0380: 結束目前 function 定義

function [9:0] square_elems;                                                                                   // L0382: 宣告 function：依 output side length 回傳 side*side 的 element count
    input [5:0] side;                                                                                          // L0383: 宣告模組輸入/輸出埠
    begin                                                                                                      // L0384: 開始一個 Verilog 程式區塊
        case (side)                                                                                            // L0385: 開始 case 分支，依條件選擇不同控制/資料路徑
            6'd6:  square_elems = 10'd36;                                                                      // L0386: 執行資料或控制訊號指派
            6'd8:  square_elems = 10'd64;                                                                      // L0387: 執行資料或控制訊號指派
            6'd10: square_elems = 10'd100;                                                                     // L0388: 執行資料或控制訊號指派
            6'd12: square_elems = 10'd144;                                                                     // L0389: 執行資料或控制訊號指派
            6'd14: square_elems = 10'd196;                                                                     // L0390: 執行資料或控制訊號指派
            6'd16: square_elems = 10'd256;                                                                     // L0391: 執行資料或控制訊號指派
            6'd18: square_elems = 10'd324;                                                                     // L0392: 執行資料或控制訊號指派
            6'd20: square_elems = 10'd400;                                                                     // L0393: 執行資料或控制訊號指派
            6'd22: square_elems = 10'd484;                                                                     // L0394: 執行資料或控制訊號指派
            6'd24: square_elems = 10'd576;                                                                     // L0395: 執行資料或控制訊號指派
            6'd26: square_elems = 10'd676;                                                                     // L0396: 執行資料或控制訊號指派
            6'd28: square_elems = 10'd784;                                                                     // L0397: 執行資料或控制訊號指派
            6'd30: square_elems = 10'd900;                                                                     // L0398: 執行資料或控制訊號指派
            default: square_elems = 10'd0;                                                                     // L0399: 執行資料或控制訊號指派
        endcase                                                                                                // L0400: 結束 case 分支
    end                                                                                                        // L0401: 結束目前 Verilog 程式區塊
endfunction                                                                                                    // L0402: 結束目前 function 定義

always @(*) begin                                                                                              // L0404: 組合邏輯 always block，輸出依目前輸入/狀態即時變化
    case (row_scan)                                                                                            // L0405: 開始 case 分支，依條件選擇不同控制/資料路徑
        2'd0: begin                                                                                            // L0406: case 分支 2'd0 的處理區塊
            row_w0_c = layer ? w1[0] : w0[0];                                                                  // L0407: 目前 row_scan 對應的第 0 個 row weight
            row_w1_c = layer ? w1[1] : w0[1];                                                                  // L0408: 目前 row_scan 對應的第 1 個 row weight
            row_w2_c = layer ? w1[2] : w0[2];                                                                  // L0409: 目前 row_scan 對應的第 2 個 row weight
        end                                                                                                    // L0410: 結束目前 Verilog 程式區塊
        2'd1: begin                                                                                            // L0411: case 分支 2'd1 的處理區塊
            row_w0_c = layer ? w1[3] : w0[3];                                                                  // L0412: 目前 row_scan 對應的第 0 個 row weight
            row_w1_c = layer ? w1[4] : w0[4];                                                                  // L0413: 目前 row_scan 對應的第 1 個 row weight
            row_w2_c = layer ? w1[5] : w0[5];                                                                  // L0414: 目前 row_scan 對應的第 2 個 row weight
        end                                                                                                    // L0415: 結束目前 Verilog 程式區塊
        default: begin                                                                                         // L0416: case 的 default 分支，處理未列出的情況
            row_w0_c = layer ? w1[6] : w0[6];                                                                  // L0417: 目前 row_scan 對應的第 0 個 row weight
            row_w1_c = layer ? w1[7] : w0[7];                                                                  // L0418: 目前 row_scan 對應的第 1 個 row weight
            row_w2_c = layer ? w1[8] : w0[8];                                                                  // L0419: 目前 row_scan 對應的第 2 個 row weight
        end                                                                                                    // L0420: 結束目前 Verilog 程式區塊
    endcase                                                                                                    // L0421: 結束 case 分支
end                                                                                                            // L0422: 結束目前 Verilog 程式區塊

always @(*) begin                                                                                              // L0424: 組合邏輯 always block，輸出依目前輸入/狀態即時變化
    web = 1'b0;                                                                                                // L0425: DataMemory Port B write enable
    enb = 1'b0;                                                                                                // L0426: DataMemory Port B enable
    dinb = 32'd0;                                                                                              // L0427: 設定寫回 DataMemory Port B 的 32-bit 資料
    addr = 10'd0;                                                                                              // L0428: CNN 存取 DataMemory Port B 的 word address

    if (wb_valid_q) begin                                                                                      // L0430: 條件判斷，依目前狀態或旗標選擇不同流程
        enb = 1'b1;                                                                                            // L0431: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
        web = 1'b1;                                                                                            // L0432: 拉高 write enable，表示此 cycle 要寫 DataMemory Port B
        addr = wb_addr_q;                                                                                      // L0433: write-back stage 的 DataMemory address
        dinb = wb_data_q;                                                                                      // L0434: 設定寫回 DataMemory Port B 的 32-bit 資料
    end                                                                                                        // L0435: 結束目前 Verilog 程式區塊
    else begin                                                                                                 // L0436: 前面條件皆不成立時執行的預設分支
    case (state)                                                                                               // L0437: 開始 case 分支，依條件選擇不同控制/資料路徑
        S_CFG_REQ: begin                                                                                       // L0438: FSM 狀態處理：送出讀取設定值 DataMemory[12] 的請求
            enb = 1'b1;                                                                                        // L0439: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
            addr = 10'd12;                                                                                     // L0440: CNN 存取 DataMemory Port B 的 word address
        end                                                                                                    // L0441: 結束目前 Verilog 程式區塊
        S_OUT_REQ: begin                                                                                       // L0442: FSM 狀態處理：送出讀取 output base / finish word DataMemory[13] 的請求
            enb = 1'b1;                                                                                        // L0443: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
            addr = 10'd13;                                                                                     // L0444: CNN 存取 DataMemory Port B 的 word address
        end                                                                                                    // L0445: 結束目前 Verilog 程式區塊
        S_BIAS0_REQ: begin                                                                                     // L0446: FSM 狀態處理：送出讀取第一層 bias0 的請求
            enb = 1'b1;                                                                                        // L0447: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
            addr = 10'd14;                                                                                     // L0448: CNN 存取 DataMemory Port B 的 word address
        end                                                                                                    // L0449: 結束目前 Verilog 程式區塊
        S_BIAS1_REQ: begin                                                                                     // L0450: FSM 狀態處理：送出讀取第二層 bias1 的請求
            enb = 1'b1;                                                                                        // L0451: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
            addr = 10'd15;                                                                                     // L0452: CNN 存取 DataMemory Port B 的 word address
        end                                                                                                    // L0453: 結束目前 Verilog 程式區塊
        S_W_REQ: begin                                                                                         // L0454: FSM 狀態處理：送出讀取 convolution weight 的請求
            enb = 1'b1;                                                                                        // L0455: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
            addr = {7'd0, weight_addr};                                                                        // L0456: 讀取 weight words 的索引
        end                                                                                                    // L0457: 結束目前 Verilog 程式區塊
        S_ADDR_CALC: begin                                                                                     // L0458: FSM 狀態處理：準備讀取目前 window 第一個 word 的位址
            enb = 1'b1;                                                                                        // L0459: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
            addr = read_addr_q;                                                                                // L0460: 目前 row-path 要讀取的 DataMemory word address
        end                                                                                                    // L0461: 結束目前 Verilog 程式區塊
        S_ROW_CAP: begin                                                                                       // L0462: FSM 狀態處理：擷取 row-path 讀出的 word，必要時處理跨 word 視窗
            if (cross_word_q) begin                                                                            // L0463: 條件判斷，依目前狀態或旗標選擇不同流程
                enb = 1'b1;                                                                                    // L0464: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
                addr = read_addr_q + 10'd1;                                                                    // L0465: 目前 row-path 要讀取的 DataMemory word address
            end                                                                                                // L0466: 結束目前 Verilog 程式區塊
        end                                                                                                    // L0467: 結束目前 Verilog 程式區塊
        S_ROW_MUL: begin                                                                                       // L0468: FSM 狀態處理：row-based 路徑中執行一列三個 pixel 的乘法
            if (row_scan != 2'd2) begin                                                                        // L0469: 條件判斷，依目前狀態或旗標選擇不同流程
                enb = 1'b1;                                                                                    // L0470: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
                addr = row_advance_addr;                                                                       // L0471: row-path 往下一列後的 word address
            end                                                                                                // L0472: 結束目前 Verilog 程式區塊
        end                                                                                                    // L0473: 結束目前 Verilog 程式區塊
        S_ROW_XCAP: begin                                                                                      // L0474: FSM 狀態處理：擷取跨 word 的第二個 word
        end                                                                                                    // L0475: 結束目前 Verilog 程式區塊
        S_ROW_FLUSH: begin                                                                                     // L0476: FSM 狀態處理：把 row-path 最後一列乘積累加進 acc
            enb = 1'b0;                                                                                        // L0477: DataMemory Port B enable
            addr = 10'd0;                                                                                      // L0478: CNN 存取 DataMemory Port B 的 word address
        end                                                                                                    // L0479: 結束目前 Verilog 程式區塊
        S_BUF_REQ: begin                                                                                       // L0480: FSM 狀態處理：送出 line buffer 載入 row word 的讀取請求
            enb = 1'b1;                                                                                        // L0481: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
            addr = load_addr;                                                                                  // L0482: line buffer 載入 row word 時的 DataMemory address
        end                                                                                                    // L0483: 結束目前 Verilog 程式區塊
        S_BUF_CAP: begin                                                                                       // L0484: FSM 狀態處理：擷取 row word 並寫入 row_buf0/1/2
            if (!load_row_done) begin                                                                          // L0485: 條件判斷，依目前狀態或旗標選擇不同流程
                enb = 1'b1;                                                                                    // L0486: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
                addr = source_base + load_row_base[9:2] + {6'd0, load_word_idx_next};                          // L0487: 下一個要載入的 row word index
            end                                                                                                // L0488: 結束目前 Verilog 程式區塊
        end                                                                                                    // L0489: 結束目前 Verilog 程式區塊
        S_CALC: begin                                                                                          // L0490: FSM 狀態處理：舊版/row-path 的計算後控制與 sliding window 更新狀態
            if (word_done) begin                                                                               // L0491: 條件判斷，依目前狀態或旗標選擇不同流程
                enb = 1'b1;                                                                                    // L0492: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
                web = 1'b1;                                                                                    // L0493: 拉高 write enable，表示此 cycle 要寫 DataMemory Port B
                addr = (layer ? output_base : INTER_BASE) + elem_idx[9:2];                                     // L0494: 最終 output 在 DataMemory 的起始位址
                dinb = pack_next;                                                                              // L0495: 設定寫回 DataMemory Port B 的 32-bit 資料
            end                                                                                                // L0496: 結束目前 Verilog 程式區塊
            else if (layer) begin                                                                              // L0497: 前一個條件不成立時，檢查下一個條件分支
                enb = 1'b1;                                                                                    // L0498: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
                addr = next_read_addr;                                                                         // L0499: 下一個 row-path 讀取 word address
            end                                                                                                // L0500: 結束目前 Verilog 程式區塊
        end                                                                                                    // L0501: 結束目前 Verilog 程式區塊
        S_LB_QUANT: begin                                                                                      // L0502: FSM 狀態處理：line-buffer 路徑將 sum 做 quantize 並安排 write-back
        end                                                                                                    // L0503: 結束目前 Verilog 程式區塊
        S_LB_DRAIN: begin                                                                                      // L0504: FSM 狀態處理：line-buffer pipeline 尾端排空，確保最後一筆 quantize/write-back 完成
        end                                                                                                    // L0505: 結束目前 Verilog 程式區塊
        S_FIN_REQ: begin                                                                                       // L0506: FSM 狀態處理：CNN 完成後寫入 DataMemory[10]=1 作為 done flag
            enb = 1'b1;                                                                                        // L0507: 拉高 memory enable，表示此 cycle 啟用 DataMemory Port B
            web = 1'b1;                                                                                        // L0508: 拉高 write enable，表示此 cycle 要寫 DataMemory Port B
            addr = CNN_DONE_ADDR;                                                                              // L0509: CNN 完成旗標寫入位址，CPU 會 polling DataMemory[10]
            dinb = 32'd1;                                                                                      // L0510: 設定寫回 DataMemory Port B 的 32-bit 資料
        end                                                                                                    // L0511: 結束目前 Verilog 程式區塊
        default: begin                                                                                         // L0512: case 的 default 分支，處理未列出的情況
            web = 1'b0;                                                                                        // L0513: DataMemory Port B write enable
            enb = 1'b0;                                                                                        // L0514: DataMemory Port B enable
            dinb = 32'd0;                                                                                      // L0515: 設定寫回 DataMemory Port B 的 32-bit 資料
            addr = 10'd0;                                                                                      // L0516: CNN 存取 DataMemory Port B 的 word address
        end                                                                                                    // L0517: 結束目前 Verilog 程式區塊
    endcase                                                                                                    // L0518: 結束 case 分支
    end                                                                                                        // L0519: 結束目前 Verilog 程式區塊
end                                                                                                            // L0520: 結束目前 Verilog 程式區塊

always @(posedge clk or negedge rstn) begin                                                                    // L0522: 時序邏輯 always block，在 clock edge 或 reset 時更新 FSM/register
    if (!rstn) begin                                                                                           // L0523: 條件判斷，依目前狀態或旗標選擇不同流程
        state <= S_WAIT;                                                                                       // L0524: FSM 下一步跳到 S_WAIT：重置釋放後的等待狀態，避免太早讀取尚未準備好的記憶體資料
        wait_count <= 10'd0;                                                                                   // L0525: S_WAIT 中使用的啟動等待 counter
        done <= 1'b0;                                                                                          // L0526: CNN 內部完成旗標，S_DONE 後維持為 1
        layer <= 1'b0;                                                                                         // L0527: 目前 convolution 層數；0=第一層，1=第二層
        weight_addr <= 3'd0;                                                                                   // L0528: 讀取 weight words 的索引
        feature_size <= 6'd0;                                                                                  // L0529: 原始 input feature map 邊長 N
        in_size <= 6'd0;                                                                                       // L0530: 目前 layer 的 input feature map 邊長
        out_size <= 6'd0;                                                                                      // L0531: 目前 layer 的 output feature map 邊長
        total_elems <= 10'd0;                                                                                  // L0532: 目前 layer 要產生的 output element 總數
        elem_idx <= 10'd0;                                                                                     // L0533: 目前正在處理的 output element index
        row <= 6'd0;                                                                                           // L0534: 目前 output element 所在 row
        col <= 6'd0;                                                                                           // L0535: 目前 output element 所在 column
        row_base <= 10'd0;                                                                                     // L0536: 目前 input row 起始 element index
        output_base <= DEFAULT_OUT;                                                                            // L0537: 最終 output 在 DataMemory 的起始位址
        pack_word <= 32'd0;                                                                                    // L0538: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
        acc <= {ACC_W{1'b0}};                                                                                  // L0539: CNN 乘加中間值/accumulator 的 signed bit width
        result_q <= 8'sd0;                                                                                     // L0540: row-path quantize 後的 8-bit 結果
        read_addr_q <= 10'd0;                                                                                  // L0541: 目前 row-path 要讀取的 DataMemory word address
        read_byte_sel_q <= 2'd0;                                                                               // L0542: 目前 row-path window 在 word 內的 byte offset
        row_scan <= 2'd0;                                                                                      // L0543: row-path 正在掃描 3x3 window 的第幾列
        cross_word_q <= 1'b0;                                                                                  // L0544: 目前 3-byte window 是否跨越 32-bit word 邊界
        row_word0_q <= 32'd0;                                                                                  // L0545: 跨 word 情況下暫存第一個 word
        prod0_q <= {ACC_W{1'b0}};                                                                              // L0546: row-path 第 0 個乘積暫存
        prod1_q <= {ACC_W{1'b0}};                                                                              // L0547: row-path 第 1 個乘積暫存
        prod2_q <= {ACC_W{1'b0}};                                                                              // L0548: row-path 第 2 個乘積暫存
        prod_valid_q <= 1'b0;                                                                                  // L0549: row-path 乘積暫存是否有效
        pix0_q <= 8'sd0;                                                                                       // L0550: row-path 目前列第 0 個 pixel
        pix1_q <= 8'sd0;                                                                                       // L0551: row-path 目前列第 1 個 pixel
        pix2_q <= 8'sd0;                                                                                       // L0552: row-path 目前列第 2 個 pixel
        row_w0_q <= 8'sd0;                                                                                     // L0553: row-path 第 0 個 weight 暫存
        row_w1_q <= 8'sd0;                                                                                     // L0554: row-path 第 1 個 weight 暫存
        row_w2_q <= 8'sd0;                                                                                     // L0555: row-path 第 2 個 weight 暫存
        row0_sel <= 2'd0;                                                                                      // L0556: row_buf0 的 byte alignment offset
        row1_sel <= 2'd0;                                                                                      // L0557: row_buf1 的 byte alignment offset
        row2_sel <= 2'd0;                                                                                      // L0558: row_buf2 的 byte alignment offset
        load_row_sel <= 2'd0;                                                                                  // L0559: 目前正在載入 row_buf0/1/2 的選擇
        load_word_idx <= 4'd0;                                                                                 // L0560: 目前載入一列中的第幾個 32-bit word
        load_words_q <= 4'd0;                                                                                  // L0561: 目前 row 需要載入的 word 數量
        load_row_base <= 10'd0;                                                                                // L0562: 目前要載入 row 的 element base index
        win00_q <= 8'sd0;                                                                                      // L0563: 3x3 window 第 0 row 第 0 col pixel
        win01_q <= 8'sd0;                                                                                      // L0564: 3x3 window 第 0 row 第 1 col pixel
        win02_q <= 8'sd0;                                                                                      // L0565: 3x3 window 第 0 row 第 2 col pixel
        win10_q <= 8'sd0;                                                                                      // L0566: 3x3 window 第 1 row 第 0 col pixel
        win11_q <= 8'sd0;                                                                                      // L0567: 3x3 window 第 1 row 第 1 col pixel
        win12_q <= 8'sd0;                                                                                      // L0568: 3x3 window 第 1 row 第 2 col pixel
        win20_q <= 8'sd0;                                                                                      // L0569: 3x3 window 第 2 row 第 0 col pixel
        win21_q <= 8'sd0;                                                                                      // L0570: 3x3 window 第 2 row 第 1 col pixel
        win22_q <= 8'sd0;                                                                                      // L0571: 3x3 window 第 2 row 第 2 col pixel
        dot0_q <= {ACC_W{1'b0}};                                                                               // L0572: 3x3 dot product 第 0 個乘積暫存
        dot1_q <= {ACC_W{1'b0}};                                                                               // L0573: 3x3 dot product 第 1 個乘積暫存
        dot2_q <= {ACC_W{1'b0}};                                                                               // L0574: 3x3 dot product 第 2 個乘積暫存
        dot3_q <= {ACC_W{1'b0}};                                                                               // L0575: 3x3 dot product 第 3 個乘積暫存
        dot4_q <= {ACC_W{1'b0}};                                                                               // L0576: 3x3 dot product 第 4 個乘積暫存
        dot5_q <= {ACC_W{1'b0}};                                                                               // L0577: 3x3 dot product 第 5 個乘積暫存
        dot6_q <= {ACC_W{1'b0}};                                                                               // L0578: 3x3 dot product 第 6 個乘積暫存
        dot7_q <= {ACC_W{1'b0}};                                                                               // L0579: 3x3 dot product 第 7 個乘積暫存
        dot8_q <= {ACC_W{1'b0}};                                                                               // L0580: 3x3 dot product 第 8 個乘積暫存
        sum0_q <= {ACC_W{1'b0}};                                                                               // L0581: dot0~dot2 的部分和
        sum1_q <= {ACC_W{1'b0}};                                                                               // L0582: dot3~dot5 的部分和
        sum2_q <= {ACC_W{1'b0}};                                                                               // L0583: dot6~dot8 加 bias 的部分和
        row_path_pixel <= 1'b0;                                                                                // L0584: 第一個 window 經 row-path 初始化後，切入 line-buffer path 的旗標
        pipe_launch_q <= 1'b0;                                                                                 // L0585: line-buffer pipeline 是否繼續發射下一個 dot 計算
        dot_valid_q <= 1'b0;                                                                                   // L0586: dot stage 輸出是否有效
        sum_valid_q <= 1'b0;                                                                                   // L0587: sum stage 輸出是否有效
        dot_elem_idx_q <= 10'd0;                                                                               // L0588: dot stage 對應的 output element index
        sum_elem_idx_q <= 10'd0;                                                                               // L0589: sum stage 對應的 output element index
        dot_word_done_q <= 1'b0;                                                                               // L0590: dot stage 這個 element 是否應該完成一個 32-bit output word
        sum_word_done_q <= 1'b0;                                                                               // L0591: sum stage 這個 element 是否應該完成一個 32-bit output word
        dot_last_q <= 1'b0;                                                                                    // L0592: dot stage 這個 element 是否為本 layer 最後一個 output
        sum_last_q <= 1'b0;                                                                                    // L0593: sum stage 這個 element 是否為本 layer 最後一個 output
        dot_row_last_q <= 1'b0;                                                                                // L0594: dot stage 這個 element 是否為該 output row 最後一欄
        sum_row_last_q <= 1'b0;                                                                                // L0595: sum stage 這個 element 是否為該 output row 最後一欄
        quant_valid_q <= 1'b0;                                                                                 // L0596: quantize stage 是否有有效 output 等待 packing/write-back
        quant_result_q <= 8'sd0;                                                                               // L0597: quantize 後的 8-bit output 暫存
        quant_elem_sel_q <= 2'd0;                                                                              // L0598: quantized output 在 32-bit pack_word 中的 byte 位置
        quant_word_done_q <= 1'b0;                                                                             // L0599: quantized output 是否完成一個 32-bit word
        quant_write_addr_q <= 10'd0;                                                                           // L0600: quantized output 對應的 DataMemory write address
        wb_valid_q <= 1'b0;                                                                                    // L0601: write-back stage 是否有有效資料要寫 Port B
        wb_addr_q <= 10'd0;                                                                                    // L0602: write-back stage 的 DataMemory address
        wb_data_q <= 32'd0;                                                                                    // L0603: write-back stage 的 32-bit data
        drain_state_q <= S_WAIT;                                                                               // L0604: pipeline drain 結束後要跳回的下一個 state
        bias0 <= 8'sd0;                                                                                        // L0605: 第一層 convolution bias，8-bit Q1.6
        bias1 <= 8'sd0;                                                                                        // L0606: 第二層 convolution bias，8-bit Q1.6
        for (i = 0; i < 9; i = i + 1) begin                                                                    // L0607: for-loop，通常用於 reset 初始化或 row buffer 搬移
            w0[i] <= 8'sd0;                                                                                    // L0608: 第一層 3x3 convolution weights
            w1[i] <= 8'sd0;                                                                                    // L0609: 第二層 3x3 convolution weights
            row_buf0[i] <= 32'd0;                                                                              // L0610: line-buffer 的 top row physical buffer
            row_buf1[i] <= 32'd0;                                                                              // L0611: line-buffer 的 middle row physical buffer
            row_buf2[i] <= 32'd0;                                                                              // L0612: line-buffer 的 bottom row physical buffer
        end                                                                                                    // L0613: 結束目前 Verilog 程式區塊
    end                                                                                                        // L0614: 結束目前 Verilog 程式區塊
    else begin                                                                                                 // L0615: 前面條件皆不成立時執行的預設分支
        wb_valid_q <= 1'b0;                                                                                    // L0616: write-back stage 是否有有效資料要寫 Port B
        case (state)                                                                                           // L0617: 開始 case 分支，依條件選擇不同控制/資料路徑
            S_WAIT: begin                                                                                      // L0618: FSM 狀態處理：重置釋放後的等待狀態，避免太早讀取尚未準備好的記憶體資料
                done <= 1'b0;                                                                                  // L0619: CNN 內部完成旗標，S_DONE 後維持為 1
                if (wait_count == START_WAIT_CYCLES) begin                                                     // L0620: 條件判斷，依目前狀態或旗標選擇不同流程
                    state <= S_CFG_REQ;                                                                        // L0621: FSM 下一步跳到 S_CFG_REQ：送出讀取設定值 DataMemory[12] 的請求
                end                                                                                            // L0622: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L0623: 前面條件皆不成立時執行的預設分支
                    wait_count <= wait_count + 10'd1;                                                          // L0624: S_WAIT 中使用的啟動等待 counter
                end                                                                                            // L0625: 結束目前 Verilog 程式區塊
            end                                                                                                // L0626: 結束目前 Verilog 程式區塊

            S_CFG_REQ: begin                                                                                   // L0628: FSM 狀態處理：送出讀取設定值 DataMemory[12] 的請求
                state <= S_CFG_CAP;                                                                            // L0629: FSM 下一步跳到 S_CFG_CAP：擷取設定值，主要取得 feature map size
            end                                                                                                // L0630: 結束目前 Verilog 程式區塊

            S_CFG_CAP: begin                                                                                   // L0632: FSM 狀態處理：擷取設定值，主要取得 feature map size
                feature_size <= doutb[6:1];                                                                    // L0633: 原始 input feature map 邊長 N
                state <= S_OUT_REQ;                                                                            // L0634: FSM 下一步跳到 S_OUT_REQ：送出讀取 output base / finish word DataMemory[13] 的請求
            end                                                                                                // L0635: 結束目前 Verilog 程式區塊

            S_OUT_REQ: begin                                                                                   // L0637: FSM 狀態處理：送出讀取 output base / finish word DataMemory[13] 的請求
                state <= S_OUT_CAP;                                                                            // L0638: FSM 下一步跳到 S_OUT_CAP：擷取 output base；若為 0 則使用預設輸出位址
            end                                                                                                // L0639: 結束目前 Verilog 程式區塊

            S_OUT_CAP: begin                                                                                   // L0641: FSM 狀態處理：擷取 output base；若為 0 則使用預設輸出位址
                output_base <= (doutb[10:1] == 10'd0) ? DEFAULT_OUT : doutb[10:1];                             // L0642: 最終 output 在 DataMemory 的起始位址
                state <= S_BIAS0_REQ;                                                                          // L0643: FSM 下一步跳到 S_BIAS0_REQ：送出讀取第一層 bias0 的請求
            end                                                                                                // L0644: 結束目前 Verilog 程式區塊

            S_BIAS0_REQ: begin                                                                                 // L0646: FSM 狀態處理：送出讀取第一層 bias0 的請求
                state <= S_BIAS0_CAP;                                                                          // L0647: FSM 下一步跳到 S_BIAS0_CAP：擷取第一層 bias0
            end                                                                                                // L0648: 結束目前 Verilog 程式區塊

            S_BIAS0_CAP: begin                                                                                 // L0650: FSM 狀態處理：擷取第一層 bias0
                bias0 <= doutb[7:0];                                                                           // L0651: 第一層 convolution bias，8-bit Q1.6
                state <= S_BIAS1_REQ;                                                                          // L0652: FSM 下一步跳到 S_BIAS1_REQ：送出讀取第二層 bias1 的請求
            end                                                                                                // L0653: 結束目前 Verilog 程式區塊

            S_BIAS1_REQ: begin                                                                                 // L0655: FSM 狀態處理：送出讀取第二層 bias1 的請求
                state <= S_BIAS1_CAP;                                                                          // L0656: FSM 下一步跳到 S_BIAS1_CAP：擷取第二層 bias1，接著準備讀取權重
            end                                                                                                // L0657: 結束目前 Verilog 程式區塊

            S_BIAS1_CAP: begin                                                                                 // L0659: FSM 狀態處理：擷取第二層 bias1，接著準備讀取權重
                bias1 <= doutb[7:0];                                                                           // L0660: 第二層 convolution bias，8-bit Q1.6
                weight_addr <= 3'd0;                                                                           // L0661: 讀取 weight words 的索引
                state <= S_W_REQ;                                                                              // L0662: FSM 下一步跳到 S_W_REQ：送出讀取 convolution weight 的請求
            end                                                                                                // L0663: 結束目前 Verilog 程式區塊

            S_W_REQ: begin                                                                                     // L0665: FSM 狀態處理：送出讀取 convolution weight 的請求
                state <= S_W_CAP;                                                                              // L0666: FSM 下一步跳到 S_W_CAP：擷取 convolution weight 並存入 w0 或 w1
            end                                                                                                // L0667: 結束目前 Verilog 程式區塊

            S_W_CAP: begin                                                                                     // L0669: FSM 狀態處理：擷取 convolution weight 並存入 w0 或 w1
                case (weight_addr)                                                                             // L0670: 開始 case 分支，依條件選擇不同控制/資料路徑
                    3'd0: begin                                                                                // L0671: case 分支 3'd0 的處理區塊
                        w0[0] <= doutb[31:24];                                                                 // L0672: DataMemory Port B 讀出的 32-bit 資料
                        w0[1] <= doutb[23:16];                                                                 // L0673: DataMemory Port B 讀出的 32-bit 資料
                        w0[2] <= doutb[15:8];                                                                  // L0674: DataMemory Port B 讀出的 32-bit 資料
                        w0[3] <= doutb[7:0];                                                                   // L0675: DataMemory Port B 讀出的 32-bit 資料
                    end                                                                                        // L0676: 結束目前 Verilog 程式區塊
                    3'd1: begin                                                                                // L0677: case 分支 3'd1 的處理區塊
                        w0[4] <= doutb[31:24];                                                                 // L0678: DataMemory Port B 讀出的 32-bit 資料
                        w0[5] <= doutb[23:16];                                                                 // L0679: DataMemory Port B 讀出的 32-bit 資料
                        w0[6] <= doutb[15:8];                                                                  // L0680: DataMemory Port B 讀出的 32-bit 資料
                        w0[7] <= doutb[7:0];                                                                   // L0681: DataMemory Port B 讀出的 32-bit 資料
                    end                                                                                        // L0682: 結束目前 Verilog 程式區塊
                    3'd2: begin                                                                                // L0683: case 分支 3'd2 的處理區塊
                        w0[8] <= doutb[31:24];                                                                 // L0684: DataMemory Port B 讀出的 32-bit 資料
                    end                                                                                        // L0685: 結束目前 Verilog 程式區塊
                    3'd3: begin                                                                                // L0686: case 分支 3'd3 的處理區塊
                        w1[0] <= doutb[31:24];                                                                 // L0687: DataMemory Port B 讀出的 32-bit 資料
                        w1[1] <= doutb[23:16];                                                                 // L0688: DataMemory Port B 讀出的 32-bit 資料
                        w1[2] <= doutb[15:8];                                                                  // L0689: DataMemory Port B 讀出的 32-bit 資料
                        w1[3] <= doutb[7:0];                                                                   // L0690: DataMemory Port B 讀出的 32-bit 資料
                    end                                                                                        // L0691: 結束目前 Verilog 程式區塊
                    3'd4: begin                                                                                // L0692: case 分支 3'd4 的處理區塊
                        w1[4] <= doutb[31:24];                                                                 // L0693: DataMemory Port B 讀出的 32-bit 資料
                        w1[5] <= doutb[23:16];                                                                 // L0694: DataMemory Port B 讀出的 32-bit 資料
                        w1[6] <= doutb[15:8];                                                                  // L0695: DataMemory Port B 讀出的 32-bit 資料
                        w1[7] <= doutb[7:0];                                                                   // L0696: DataMemory Port B 讀出的 32-bit 資料
                    end                                                                                        // L0697: 結束目前 Verilog 程式區塊
                    default: begin                                                                             // L0698: case 的 default 分支，處理未列出的情況
                        w1[8] <= doutb[31:24];                                                                 // L0699: DataMemory Port B 讀出的 32-bit 資料
                    end                                                                                        // L0700: 結束目前 Verilog 程式區塊
                endcase                                                                                        // L0701: 結束 case 分支

                if (weight_addr == 3'd5) begin                                                                 // L0703: 條件判斷，依目前狀態或旗標選擇不同流程
                    state <= S_CONV1_INIT;                                                                     // L0704: FSM 下一步跳到 S_CONV1_INIT：初始化第一層 convolution 的尺寸、索引與 buffer 狀態
                end                                                                                            // L0705: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L0706: 前面條件皆不成立時執行的預設分支
                    weight_addr <= weight_addr + 3'd1;                                                         // L0707: 讀取 weight words 的索引
                    state <= S_W_REQ;                                                                          // L0708: FSM 下一步跳到 S_W_REQ：送出讀取 convolution weight 的請求
                end                                                                                            // L0709: 結束目前 Verilog 程式區塊
            end                                                                                                // L0710: 結束目前 Verilog 程式區塊

            S_CONV1_INIT: begin                                                                                // L0712: FSM 狀態處理：初始化第一層 convolution 的尺寸、索引與 buffer 狀態
                layer <= 1'b0;                                                                                 // L0713: 目前 convolution 層數；0=第一層，1=第二層
                in_size <= feature_size;                                                                       // L0714: 原始 input feature map 邊長 N
                out_size <= feature_size - 6'd2;                                                               // L0715: 原始 input feature map 邊長 N
                total_elems <= square_elems(feature_size - 6'd2);                                              // L0716: 原始 input feature map 邊長 N
                elem_idx <= 10'd0;                                                                             // L0717: 目前正在處理的 output element index
                row <= 6'd0;                                                                                   // L0718: 目前 output element 所在 row
                col <= 6'd0;                                                                                   // L0719: 目前 output element 所在 column
                row_base <= 10'd0;                                                                             // L0720: 目前 input row 起始 element index
                pack_word <= 32'd0;                                                                            // L0721: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                acc <= bias0_q12;                                                                              // L0722: bias0 轉為 Q?.12 後的 accumulator 格式
                prod_valid_q <= 1'b0;                                                                          // L0723: row-path 乘積暫存是否有效
                result_q <= 8'sd0;                                                                             // L0724: row-path quantize 後的 8-bit 結果
                row_scan <= 2'd0;                                                                              // L0725: row-path 正在掃描 3x3 window 的第幾列
                read_addr_q <= INPUT_BASE;                                                                     // L0726: 目前 row-path 要讀取的 DataMemory word address
                read_byte_sel_q <= 2'd0;                                                                       // L0727: 目前 row-path window 在 word 內的 byte offset
                cross_word_q <= 1'b0;                                                                          // L0728: 目前 3-byte window 是否跨越 32-bit word 邊界
                row0_sel <= 2'd0;                                                                              // L0729: row_buf0 的 byte alignment offset
                row1_sel <= 2'd0;                                                                              // L0730: row_buf1 的 byte alignment offset
                row2_sel <= 2'd0;                                                                              // L0731: row_buf2 的 byte alignment offset
                load_row_sel <= 2'd0;                                                                          // L0732: 目前正在載入 row_buf0/1/2 的選擇
                load_word_idx <= 4'd0;                                                                         // L0733: 目前載入一列中的第幾個 32-bit word
                load_row_base <= 10'd0;                                                                        // L0734: 目前要載入 row 的 element base index
                load_words_q <= row_words_for(2'd0, feature_size);                                             // L0735: 目前 row 需要載入的 word 數量
                row_path_pixel <= 1'b0;                                                                        // L0736: 第一個 window 經 row-path 初始化後，切入 line-buffer path 的旗標
                pipe_launch_q <= 1'b0;                                                                         // L0737: line-buffer pipeline 是否繼續發射下一個 dot 計算
                dot_valid_q <= 1'b0;                                                                           // L0738: dot stage 輸出是否有效
                sum_valid_q <= 1'b0;                                                                           // L0739: sum stage 輸出是否有效
                quant_valid_q <= 1'b0;                                                                         // L0740: quantize stage 是否有有效 output 等待 packing/write-back
                wb_valid_q <= 1'b0;                                                                            // L0741: write-back stage 是否有有效資料要寫 Port B
                state <= S_BUF_REQ;                                                                            // L0742: FSM 下一步跳到 S_BUF_REQ：送出 line buffer 載入 row word 的讀取請求
            end                                                                                                // L0743: 結束目前 Verilog 程式區塊

            S_CONV2_INIT: begin                                                                                // L0745: FSM 狀態處理：初始化第二層 convolution，輸入來源改為 intermediate buffer
                layer <= 1'b1;                                                                                 // L0746: 目前 convolution 層數；0=第一層，1=第二層
                in_size <= feature_size - 6'd2;                                                                // L0747: 原始 input feature map 邊長 N
                out_size <= feature_size - 6'd4;                                                               // L0748: 原始 input feature map 邊長 N
                total_elems <= square_elems(feature_size - 6'd4);                                              // L0749: 原始 input feature map 邊長 N
                elem_idx <= 10'd0;                                                                             // L0750: 目前正在處理的 output element index
                row <= 6'd0;                                                                                   // L0751: 目前 output element 所在 row
                col <= 6'd0;                                                                                   // L0752: 目前 output element 所在 column
                row_base <= 10'd0;                                                                             // L0753: 目前 input row 起始 element index
                pack_word <= 32'd0;                                                                            // L0754: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                acc <= bias1_q12;                                                                              // L0755: bias1 轉為 Q?.12 後的 accumulator 格式
                prod_valid_q <= 1'b0;                                                                          // L0756: row-path 乘積暫存是否有效
                result_q <= 8'sd0;                                                                             // L0757: row-path quantize 後的 8-bit 結果
                row_scan <= 2'd0;                                                                              // L0758: row-path 正在掃描 3x3 window 的第幾列
                read_addr_q <= INTER_BASE;                                                                     // L0759: 目前 row-path 要讀取的 DataMemory word address
                read_byte_sel_q <= 2'd0;                                                                       // L0760: 目前 row-path window 在 word 內的 byte offset
                cross_word_q <= 1'b0;                                                                          // L0761: 目前 3-byte window 是否跨越 32-bit word 邊界
                row0_sel <= 2'd0;                                                                              // L0762: row_buf0 的 byte alignment offset
                row1_sel <= 2'd0;                                                                              // L0763: row_buf1 的 byte alignment offset
                row2_sel <= 2'd0;                                                                              // L0764: row_buf2 的 byte alignment offset
                load_row_sel <= 2'd0;                                                                          // L0765: 目前正在載入 row_buf0/1/2 的選擇
                load_word_idx <= 4'd0;                                                                         // L0766: 目前載入一列中的第幾個 32-bit word
                load_row_base <= 10'd0;                                                                        // L0767: 目前要載入 row 的 element base index
                load_words_q <= row_words_for(2'd0, feature_size - 6'd2);                                      // L0768: 目前 row 需要載入的 word 數量
                row_path_pixel <= 1'b0;                                                                        // L0769: 第一個 window 經 row-path 初始化後，切入 line-buffer path 的旗標
                pipe_launch_q <= 1'b0;                                                                         // L0770: line-buffer pipeline 是否繼續發射下一個 dot 計算
                dot_valid_q <= 1'b0;                                                                           // L0771: dot stage 輸出是否有效
                sum_valid_q <= 1'b0;                                                                           // L0772: sum stage 輸出是否有效
                quant_valid_q <= 1'b0;                                                                         // L0773: quantize stage 是否有有效 output 等待 packing/write-back
                wb_valid_q <= 1'b0;                                                                            // L0774: write-back stage 是否有有效資料要寫 Port B
                state <= S_BUF_REQ;                                                                            // L0775: FSM 下一步跳到 S_BUF_REQ：送出 line buffer 載入 row word 的讀取請求
            end                                                                                                // L0776: 結束目前 Verilog 程式區塊

            S_ADDR_CALC: begin                                                                                 // L0778: FSM 狀態處理：準備讀取目前 window 第一個 word 的位址
                prod_valid_q <= 1'b0;                                                                          // L0779: row-path 乘積暫存是否有效
                row_scan <= 2'd0;                                                                              // L0780: row-path 正在掃描 3x3 window 的第幾列
                state <= S_ROW_CAP;                                                                            // L0781: FSM 下一步跳到 S_ROW_CAP：擷取 row-path 讀出的 word，必要時處理跨 word 視窗
            end                                                                                                // L0782: 結束目前 Verilog 程式區塊

            S_ROW_CAP: begin                                                                                   // L0784: FSM 狀態處理：擷取 row-path 讀出的 word，必要時處理跨 word 視窗
                if (cross_word_q) begin                                                                        // L0785: 條件判斷，依目前狀態或旗標選擇不同流程
                    if (prod_valid_q) begin                                                                    // L0786: 條件判斷，依目前狀態或旗標選擇不同流程
                        acc <= acc + prod_sum_q;                                                               // L0787: row-path 三個乘積的部分和
                        prod_valid_q <= 1'b0;                                                                  // L0788: row-path 乘積暫存是否有效
                    end                                                                                        // L0789: 結束目前 Verilog 程式區塊
                    row_word0_q <= doutb;                                                                      // L0790: 跨 word 情況下暫存第一個 word
                    state <= S_ROW_XCAP;                                                                       // L0791: FSM 下一步跳到 S_ROW_XCAP：擷取跨 word 的第二個 word
                end                                                                                            // L0792: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L0793: 前面條件皆不成立時執行的預設分支
                    if (prod_valid_q) begin                                                                    // L0794: 條件判斷，依目前狀態或旗標選擇不同流程
                        acc <= acc + prod_sum_q;                                                               // L0795: row-path 三個乘積的部分和
                        prod_valid_q <= 1'b0;                                                                  // L0796: row-path 乘積暫存是否有效
                    end                                                                                        // L0797: 結束目前 Verilog 程式區塊
                    pix0_q <= dot_pix0_c;                                                                      // L0798: 目前 window 的第 0 個 pixel 組合值
                    pix1_q <= dot_pix1_c;                                                                      // L0799: 目前 window 的第 1 個 pixel 組合值
                    pix2_q <= dot_pix2_c;                                                                      // L0800: 目前 window 的第 2 個 pixel 組合值
                    row_w0_q <= row_w0_c;                                                                      // L0801: 目前 row_scan 對應的第 0 個 row weight
                    row_w1_q <= row_w1_c;                                                                      // L0802: 目前 row_scan 對應的第 1 個 row weight
                    row_w2_q <= row_w2_c;                                                                      // L0803: 目前 row_scan 對應的第 2 個 row weight
                    state <= S_ROW_MUL;                                                                        // L0804: FSM 下一步跳到 S_ROW_MUL：row-based 路徑中執行一列三個 pixel 的乘法
                end                                                                                            // L0805: 結束目前 Verilog 程式區塊
            end                                                                                                // L0806: 結束目前 Verilog 程式區塊

            S_ROW_XCAP: begin                                                                                  // L0808: FSM 狀態處理：擷取跨 word 的第二個 word
                if (prod_valid_q) begin                                                                        // L0809: 條件判斷，依目前狀態或旗標選擇不同流程
                    acc <= acc + prod_sum_q;                                                                   // L0810: row-path 三個乘積的部分和
                    prod_valid_q <= 1'b0;                                                                      // L0811: row-path 乘積暫存是否有效
                end                                                                                            // L0812: 結束目前 Verilog 程式區塊
                pix0_q <= dot_pix0_c;                                                                          // L0813: 目前 window 的第 0 個 pixel 組合值
                pix1_q <= dot_pix1_c;                                                                          // L0814: 目前 window 的第 1 個 pixel 組合值
                pix2_q <= dot_pix2_c;                                                                          // L0815: 目前 window 的第 2 個 pixel 組合值
                row_w0_q <= row_w0_c;                                                                          // L0816: 目前 row_scan 對應的第 0 個 row weight
                row_w1_q <= row_w1_c;                                                                          // L0817: 目前 row_scan 對應的第 1 個 row weight
                row_w2_q <= row_w2_c;                                                                          // L0818: 目前 row_scan 對應的第 2 個 row weight
                state <= S_ROW_MUL;                                                                            // L0819: FSM 下一步跳到 S_ROW_MUL：row-based 路徑中執行一列三個 pixel 的乘法
            end                                                                                                // L0820: 結束目前 Verilog 程式區塊

            S_ROW_MUL: begin                                                                                   // L0822: FSM 狀態處理：row-based 路徑中執行一列三個 pixel 的乘法
                prod0_q <= mul_q(pix0_q, row_w0_q);                                                            // L0823: row-path 第 0 個 weight 暫存
                prod1_q <= mul_q(pix1_q, row_w1_q);                                                            // L0824: row-path 第 1 個 weight 暫存
                prod2_q <= mul_q(pix2_q, row_w2_q);                                                            // L0825: row-path 第 2 個 weight 暫存
                prod_valid_q <= 1'b1;                                                                          // L0826: row-path 乘積暫存是否有效
                if (row_scan == 2'd2) begin                                                                    // L0827: 條件判斷，依目前狀態或旗標選擇不同流程
                    state <= S_ROW_FLUSH;                                                                      // L0828: FSM 下一步跳到 S_ROW_FLUSH：把 row-path 最後一列乘積累加進 acc
                end                                                                                            // L0829: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L0830: 前面條件皆不成立時執行的預設分支
                    row_scan <= row_scan + 2'd1;                                                               // L0831: row-path 正在掃描 3x3 window 的第幾列
                    read_addr_q <= row_advance_addr;                                                           // L0832: row-path 往下一列後的 word address
                    read_byte_sel_q <= row_advance_sel;                                                        // L0833: 目前 row-path window 在 word 內的 byte offset
                    cross_word_q <= row_advance_sel[1];                                                        // L0834: row-path 往下一列後的 byte offset
                    state <= S_ROW_CAP;                                                                        // L0835: FSM 下一步跳到 S_ROW_CAP：擷取 row-path 讀出的 word，必要時處理跨 word 視窗
                end                                                                                            // L0836: 結束目前 Verilog 程式區塊
            end                                                                                                // L0837: 結束目前 Verilog 程式區塊

            S_ROW_FLUSH: begin                                                                                 // L0839: FSM 狀態處理：把 row-path 最後一列乘積累加進 acc
                if (prod_valid_q) begin                                                                        // L0840: 條件判斷，依目前狀態或旗標選擇不同流程
                    acc <= acc + prod_sum_q;                                                                   // L0841: row-path 三個乘積的部分和
                    prod_valid_q <= 1'b0;                                                                      // L0842: row-path 乘積暫存是否有效
                end                                                                                            // L0843: 結束目前 Verilog 程式區塊
                state <= S_ROW_QUANT;                                                                          // L0844: FSM 下一步跳到 S_ROW_QUANT：row-path 將 accumulator 做 quantize
            end                                                                                                // L0845: 結束目前 Verilog 程式區塊

            S_BUF_REQ: begin                                                                                   // L0847: FSM 狀態處理：送出 line buffer 載入 row word 的讀取請求
                state <= S_BUF_CAP;                                                                            // L0848: FSM 下一步跳到 S_BUF_CAP：擷取 row word 並寫入 row_buf0/1/2
            end                                                                                                // L0849: 結束目前 Verilog 程式區塊

            S_BUF_CAP: begin                                                                                   // L0851: FSM 狀態處理：擷取 row word 並寫入 row_buf0/1/2
                case (load_row_sel)                                                                            // L0852: 開始 case 分支，依條件選擇不同控制/資料路徑
                    2'd0: row_buf0[load_word_idx] <= doutb;                                                    // L0853: 目前載入一列中的第幾個 32-bit word
                    2'd1: row_buf1[load_word_idx] <= doutb;                                                    // L0854: 目前載入一列中的第幾個 32-bit word
                    default: row_buf2[load_word_idx] <= doutb;                                                 // L0855: 目前載入一列中的第幾個 32-bit word
                endcase                                                                                        // L0856: 結束 case 分支

                if (load_row_done) begin                                                                       // L0858: 條件判斷，依目前狀態或旗標選擇不同流程
                    load_word_idx <= 4'd0;                                                                     // L0859: 目前載入一列中的第幾個 32-bit word
                    case (load_row_sel)                                                                        // L0860: 開始 case 分支，依條件選擇不同控制/資料路徑
                        2'd0: begin                                                                            // L0861: case 分支 2'd0 的處理區塊
                            row0_sel <= load_row_base[1:0];                                                    // L0862: 目前要載入 row 的 element base index
                            load_row_sel <= 2'd1;                                                              // L0863: 目前正在載入 row_buf0/1/2 的選擇
                            load_row_base <= load_next_row_base;                                               // L0864: 下一列 row 的 base index
                            load_words_q <= row_words_for(load_next_row_sel, in_size);                         // L0865: 下一列 row 的 byte alignment
                            state <= S_BUF_REQ;                                                                // L0866: FSM 下一步跳到 S_BUF_REQ：送出 line buffer 載入 row word 的讀取請求
                        end                                                                                    // L0867: 結束目前 Verilog 程式區塊
                        2'd1: begin                                                                            // L0868: case 分支 2'd1 的處理區塊
                            row1_sel <= load_row_base[1:0];                                                    // L0869: 目前要載入 row 的 element base index
                            load_row_sel <= 2'd2;                                                              // L0870: 目前正在載入 row_buf0/1/2 的選擇
                            load_row_base <= load_next_row_base;                                               // L0871: 下一列 row 的 base index
                            load_words_q <= row_words_for(load_next_row_sel, in_size);                         // L0872: 下一列 row 的 byte alignment
                            state <= S_BUF_REQ;                                                                // L0873: FSM 下一步跳到 S_BUF_REQ：送出 line buffer 載入 row word 的讀取請求
                        end                                                                                    // L0874: 結束目前 Verilog 程式區塊
                        default: begin                                                                         // L0875: case 的 default 分支，處理未列出的情況
                            row2_sel <= load_row_base[1:0];                                                    // L0876: 目前要載入 row 的 element base index
                            row_path_pixel <= 1'b1;                                                            // L0877: 第一個 window 經 row-path 初始化後，切入 line-buffer path 的旗標
                            pipe_launch_q <= 1'b0;                                                             // L0878: line-buffer pipeline 是否繼續發射下一個 dot 計算
                            dot_valid_q <= 1'b0;                                                               // L0879: dot stage 輸出是否有效
                            sum_valid_q <= 1'b0;                                                               // L0880: sum stage 輸出是否有效
                            acc <= layer ? bias1_q12 : bias0_q12;                                              // L0881: bias1 轉為 Q?.12 後的 accumulator 格式
                            prod_valid_q <= 1'b0;                                                              // L0882: row-path 乘積暫存是否有效
                            row_scan <= 2'd0;                                                                  // L0883: row-path 正在掃描 3x3 window 的第幾列
                            read_addr_q <= curr_read_addr;                                                     // L0884: 目前 output pixel 左上角 word address
                            read_byte_sel_q <= curr_read_sel;                                                  // L0885: 目前 row-path window 在 word 內的 byte offset
                            cross_word_q <= curr_cross_word;                                                   // L0886: 目前 window 是否跨 word
                            state <= S_ADDR_CALC;                                                              // L0887: FSM 下一步跳到 S_ADDR_CALC：準備讀取目前 window 第一個 word 的位址
                        end                                                                                    // L0888: 結束目前 Verilog 程式區塊
                    endcase                                                                                    // L0889: 結束 case 分支
                end                                                                                            // L0890: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L0891: 前面條件皆不成立時執行的預設分支
                    load_word_idx <= load_word_idx_next;                                                       // L0892: 下一個要載入的 row word index
                    state <= S_BUF_CAP;                                                                        // L0893: FSM 下一步跳到 S_BUF_CAP：擷取 row word 並寫入 row_buf0/1/2
                end                                                                                            // L0894: 結束目前 Verilog 程式區塊
            end                                                                                                // L0895: 結束目前 Verilog 程式區塊

            S_DOT: begin                                                                                       // L0897: FSM 狀態處理：line-buffer 路徑中對 3x3 window 的 9 個乘法啟動暫存
                dot0_q <= mul_q(lb00_c, dot_w0_c);                                                             // L0898: 目前 layer 的 weight[0]
                dot1_q <= mul_q(lb01_c, dot_w1_c);                                                             // L0899: 目前 layer 的 weight[1]
                dot2_q <= mul_q(lb02_c, dot_w2_c);                                                             // L0900: 目前 layer 的 weight[2]
                dot3_q <= mul_q(lb10_c, dot_w3_c);                                                             // L0901: 目前 layer 的 weight[3]
                dot4_q <= mul_q(lb11_c, dot_w4_c);                                                             // L0902: 目前 layer 的 weight[4]
                dot5_q <= mul_q(lb12_c, dot_w5_c);                                                             // L0903: 目前 layer 的 weight[5]
                dot6_q <= mul_q(lb20_c, dot_w6_c);                                                             // L0904: 目前 layer 的 weight[6]
                dot7_q <= mul_q(lb21_c, dot_w7_c);                                                             // L0905: 目前 layer 的 weight[7]
                dot8_q <= mul_q(lb22_c, dot_w8_c);                                                             // L0906: 目前 layer 的 weight[8]
                dot_elem_idx_q <= elem_idx;                                                                    // L0907: dot stage 對應的 output element index
                dot_word_done_q <= word_done;                                                                  // L0908: dot stage 這個 element 是否應該完成一個 32-bit output word
                dot_last_q <= last_elem;                                                                       // L0909: dot stage 這個 element 是否為本 layer 最後一個 output
                dot_row_last_q <= row_last_col;                                                                // L0910: dot stage 這個 element 是否為該 output row 最後一欄
                dot_valid_q <= 1'b1;                                                                           // L0911: dot stage 輸出是否有效

                if (last_elem || row_last_col) begin                                                           // L0913: 條件判斷，依目前狀態或旗標選擇不同流程
                    pipe_launch_q <= 1'b0;                                                                     // L0914: line-buffer pipeline 是否繼續發射下一個 dot 計算
                end                                                                                            // L0915: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L0916: 前面條件皆不成立時執行的預設分支
                    pipe_launch_q <= 1'b1;                                                                     // L0917: line-buffer pipeline 是否繼續發射下一個 dot 計算
                    elem_idx <= elem_idx + 10'd1;                                                              // L0918: 目前正在處理的 output element index
                    win00_q <= slide00_c;                                                                      // L0919: sliding window 往右移後的新 win00
                    win01_q <= slide01_c;                                                                      // L0920: sliding window 往右移後的新 win01
                    win02_q <= slide02_c;                                                                      // L0921: sliding window 往右移後的新 win02，由 row_buf0 取新 column
                    win10_q <= slide10_c;                                                                      // L0922: sliding window 往右移後的新 win10
                    win11_q <= slide11_c;                                                                      // L0923: sliding window 往右移後的新 win11
                    win12_q <= slide12_c;                                                                      // L0924: sliding window 往右移後的新 win12，由 row_buf1 取新 column
                    win20_q <= slide20_c;                                                                      // L0925: sliding window 往右移後的新 win20
                    win21_q <= slide21_c;                                                                      // L0926: sliding window 往右移後的新 win21
                    win22_q <= slide22_c;                                                                      // L0927: sliding window 往右移後的新 win22，由 row_buf2 取新 column
                    col <= col + 6'd1;                                                                         // L0928: 目前 output element 所在 column
                end                                                                                            // L0929: 結束目前 Verilog 程式區塊
                state <= S_SUM;                                                                                // L0930: FSM 下一步跳到 S_SUM：把 9 個乘法結果分三組加總，並推進 pipeline
            end                                                                                                // L0931: 結束目前 Verilog 程式區塊

            S_ROW_QUANT: begin                                                                                 // L0933: FSM 狀態處理：row-path 將 accumulator 做 quantize
                result_q <= quantize_q12(acc);                                                                 // L0934: row-path quantize 後的 8-bit 結果
                state <= S_CALC;                                                                               // L0935: FSM 下一步跳到 S_CALC：舊版/row-path 的計算後控制與 sliding window 更新狀態
            end                                                                                                // L0936: 結束目前 Verilog 程式區塊

            S_SUM: begin                                                                                       // L0938: FSM 狀態處理：把 9 個乘法結果分三組加總，並推進 pipeline
                sum0_q <= dot0_q + dot1_q + dot2_q;                                                            // L0939: dot0~dot2 的部分和
                sum1_q <= dot3_q + dot4_q + dot5_q;                                                            // L0940: dot3~dot5 的部分和
                sum2_q <= dot6_q + dot7_q + dot8_q + (layer ? bias1_q12 : bias0_q12);                          // L0941: bias1 轉為 Q?.12 後的 accumulator 格式
                sum_elem_idx_q <= dot_elem_idx_q;                                                              // L0942: sum stage 對應的 output element index
                sum_word_done_q <= dot_word_done_q;                                                            // L0943: sum stage 這個 element 是否應該完成一個 32-bit output word
                sum_last_q <= dot_last_q;                                                                      // L0944: sum stage 這個 element 是否為本 layer 最後一個 output
                sum_row_last_q <= dot_row_last_q;                                                              // L0945: sum stage 這個 element 是否為該 output row 最後一欄
                sum_valid_q <= dot_valid_q;                                                                    // L0946: sum stage 輸出是否有效

                if (pipe_launch_q) begin                                                                       // L0948: 條件判斷，依目前狀態或旗標選擇不同流程
                    dot0_q <= mul_q(lb00_c, dot_w0_c);                                                         // L0949: 目前 layer 的 weight[0]
                    dot1_q <= mul_q(lb01_c, dot_w1_c);                                                         // L0950: 目前 layer 的 weight[1]
                    dot2_q <= mul_q(lb02_c, dot_w2_c);                                                         // L0951: 目前 layer 的 weight[2]
                    dot3_q <= mul_q(lb10_c, dot_w3_c);                                                         // L0952: 目前 layer 的 weight[3]
                    dot4_q <= mul_q(lb11_c, dot_w4_c);                                                         // L0953: 目前 layer 的 weight[4]
                    dot5_q <= mul_q(lb12_c, dot_w5_c);                                                         // L0954: 目前 layer 的 weight[5]
                    dot6_q <= mul_q(lb20_c, dot_w6_c);                                                         // L0955: 目前 layer 的 weight[6]
                    dot7_q <= mul_q(lb21_c, dot_w7_c);                                                         // L0956: 目前 layer 的 weight[7]
                    dot8_q <= mul_q(lb22_c, dot_w8_c);                                                         // L0957: 目前 layer 的 weight[8]
                    dot_elem_idx_q <= elem_idx;                                                                // L0958: dot stage 對應的 output element index
                    dot_word_done_q <= word_done;                                                              // L0959: dot stage 這個 element 是否應該完成一個 32-bit output word
                    dot_last_q <= last_elem;                                                                   // L0960: dot stage 這個 element 是否為本 layer 最後一個 output
                    dot_row_last_q <= row_last_col;                                                            // L0961: dot stage 這個 element 是否為該 output row 最後一欄
                    dot_valid_q <= 1'b1;                                                                       // L0962: dot stage 輸出是否有效

                    if (last_elem || row_last_col) begin                                                       // L0964: 條件判斷，依目前狀態或旗標選擇不同流程
                        pipe_launch_q <= 1'b0;                                                                 // L0965: line-buffer pipeline 是否繼續發射下一個 dot 計算
                    end                                                                                        // L0966: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L0967: 前面條件皆不成立時執行的預設分支
                        elem_idx <= elem_idx + 10'd1;                                                          // L0968: 目前正在處理的 output element index
                        win00_q <= slide00_c;                                                                  // L0969: sliding window 往右移後的新 win00
                        win01_q <= slide01_c;                                                                  // L0970: sliding window 往右移後的新 win01
                        win02_q <= slide02_c;                                                                  // L0971: sliding window 往右移後的新 win02，由 row_buf0 取新 column
                        win10_q <= slide10_c;                                                                  // L0972: sliding window 往右移後的新 win10
                        win11_q <= slide11_c;                                                                  // L0973: sliding window 往右移後的新 win11
                        win12_q <= slide12_c;                                                                  // L0974: sliding window 往右移後的新 win12，由 row_buf1 取新 column
                        win20_q <= slide20_c;                                                                  // L0975: sliding window 往右移後的新 win20
                        win21_q <= slide21_c;                                                                  // L0976: sliding window 往右移後的新 win21
                        win22_q <= slide22_c;                                                                  // L0977: sliding window 往右移後的新 win22，由 row_buf2 取新 column
                        col <= col + 6'd1;                                                                     // L0978: 目前 output element 所在 column
                    end                                                                                        // L0979: 結束目前 Verilog 程式區塊
                end                                                                                            // L0980: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L0981: 前面條件皆不成立時執行的預設分支
                    dot_valid_q <= 1'b0;                                                                       // L0982: dot stage 輸出是否有效
                end                                                                                            // L0983: 結束目前 Verilog 程式區塊
                state <= S_LB_QUANT;                                                                           // L0984: FSM 下一步跳到 S_LB_QUANT：line-buffer 路徑將 sum 做 quantize 並安排 write-back
            end                                                                                                // L0985: 結束目前 Verilog 程式區塊

            S_LB_QUANT: begin                                                                                  // L0987: FSM 狀態處理：line-buffer 路徑將 sum 做 quantize 並安排 write-back
                if (quant_valid_q) begin                                                                       // L0988: 條件判斷，依目前狀態或旗標選擇不同流程
                    if (quant_word_done_q) begin                                                               // L0989: 條件判斷，依目前狀態或旗標選擇不同流程
                        wb_valid_q <= 1'b1;                                                                    // L0990: write-back stage 是否有有效資料要寫 Port B
                        wb_addr_q <= quant_write_addr_q;                                                       // L0991: quantized output 對應的 DataMemory write address
                        wb_data_q <= quant_pack_next;                                                          // L0992: registered quantize 結果放入 pack_word 後的下一值
                        pack_word <= 32'd0;                                                                    // L0993: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                    end                                                                                        // L0994: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L0995: 前面條件皆不成立時執行的預設分支
                        pack_word <= quant_pack_next;                                                          // L0996: registered quantize 結果放入 pack_word 後的下一值
                    end                                                                                        // L0997: 結束目前 Verilog 程式區塊
                end                                                                                            // L0998: 結束目前 Verilog 程式區塊
                quant_valid_q <= 1'b0;                                                                         // L0999: quantize stage 是否有有效 output 等待 packing/write-back

                if (sum_valid_q) begin                                                                         // L1001: 條件判斷，依目前狀態或旗標選擇不同流程
                    quant_valid_q <= 1'b1;                                                                     // L1002: quantize stage 是否有有效 output 等待 packing/write-back
                    quant_result_q <= conv_result_c;                                                           // L1003: quantize 後的 8-bit output 暫存
                    quant_elem_sel_q <= sum_elem_idx_q[1:0];                                                   // L1004: quantized output 在 32-bit pack_word 中的 byte 位置
                    quant_word_done_q <= sum_word_done_q;                                                      // L1005: quantized output 是否完成一個 32-bit word
                    quant_write_addr_q <= pipe_write_addr;                                                     // L1006: quantized output 對應的 DataMemory write address
                end                                                                                            // L1007: 結束目前 Verilog 程式區塊

                if (sum_valid_q && sum_last_q) begin                                                           // L1009: 條件判斷，依目前狀態或旗標選擇不同流程
                    dot_valid_q <= 1'b0;                                                                       // L1010: dot stage 輸出是否有效
                    sum_valid_q <= 1'b0;                                                                       // L1011: sum stage 輸出是否有效
                    pipe_launch_q <= 1'b0;                                                                     // L1012: line-buffer pipeline 是否繼續發射下一個 dot 計算
                    drain_state_q <= layer ? S_FIN_REQ : S_CONV2_INIT;                                         // L1013: pipeline drain 結束後要跳回的下一個 state
                    state <= S_LB_DRAIN;                                                                       // L1014: FSM 下一步跳到 S_LB_DRAIN：line-buffer pipeline 尾端排空，確保最後一筆 quantize/write-back 完成
                end                                                                                            // L1015: 結束目前 Verilog 程式區塊
                else if (sum_valid_q && sum_row_last_q) begin                                                  // L1016: 前一個條件不成立時，檢查下一個條件分支
                    dot_valid_q <= 1'b0;                                                                       // L1017: dot stage 輸出是否有效
                    sum_valid_q <= 1'b0;                                                                       // L1018: sum stage 輸出是否有效
                    pipe_launch_q <= 1'b0;                                                                     // L1019: line-buffer pipeline 是否繼續發射下一個 dot 計算
                    elem_idx <= sum_elem_idx_q + 10'd1;                                                        // L1020: sum stage 對應的 output element index
                    for (i = 0; i < 9; i = i + 1) begin                                                        // L1021: for-loop，通常用於 reset 初始化或 row buffer 搬移
                        row_buf0[i] <= row_buf1[i];                                                            // L1022: line-buffer 的 top row physical buffer
                        row_buf1[i] <= row_buf2[i];                                                            // L1023: line-buffer 的 middle row physical buffer
                    end                                                                                        // L1024: 結束目前 Verilog 程式區塊
                    row0_sel <= row1_sel;                                                                      // L1025: row_buf1 的 byte alignment offset
                    row1_sel <= row2_sel;                                                                      // L1026: row_buf2 的 byte alignment offset
                    col <= 6'd0;                                                                               // L1027: 目前 output element 所在 column
                    row <= row + 6'd1;                                                                         // L1028: 目前 output element 所在 row
                    row_base <= next_top_row_base;                                                             // L1029: 滑到下一個 output row 時新的 top row base
                    load_row_sel <= 2'd2;                                                                      // L1030: 目前正在載入 row_buf0/1/2 的選擇
                    load_word_idx <= 4'd0;                                                                     // L1031: 目前載入一列中的第幾個 32-bit word
                    load_row_base <= next_bottom_load_base;                                                    // L1032: 滑到下一個 output row 時需要載入的新 bottom row base
                    load_words_q <= next_bottom_load_words;                                                    // L1033: 新 bottom row 需要載入的 word 數量
                    drain_state_q <= S_BUF_REQ;                                                                // L1034: pipeline drain 結束後要跳回的下一個 state
                    state <= S_LB_DRAIN;                                                                       // L1035: FSM 下一步跳到 S_LB_DRAIN：line-buffer pipeline 尾端排空，確保最後一筆 quantize/write-back 完成
                end                                                                                            // L1036: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L1037: 前面條件皆不成立時執行的預設分支
                    if (dot_valid_q) begin                                                                     // L1038: 條件判斷，依目前狀態或旗標選擇不同流程
                        sum0_q <= dot0_q + dot1_q + dot2_q;                                                    // L1039: dot0~dot2 的部分和
                        sum1_q <= dot3_q + dot4_q + dot5_q;                                                    // L1040: dot3~dot5 的部分和
                        sum2_q <= dot6_q + dot7_q + dot8_q + (layer ? bias1_q12 : bias0_q12);                  // L1041: bias1 轉為 Q?.12 後的 accumulator 格式
                        sum_elem_idx_q <= dot_elem_idx_q;                                                      // L1042: sum stage 對應的 output element index
                        sum_word_done_q <= dot_word_done_q;                                                    // L1043: sum stage 這個 element 是否應該完成一個 32-bit output word
                        sum_last_q <= dot_last_q;                                                              // L1044: sum stage 這個 element 是否為本 layer 最後一個 output
                        sum_row_last_q <= dot_row_last_q;                                                      // L1045: sum stage 這個 element 是否為該 output row 最後一欄
                        sum_valid_q <= 1'b1;                                                                   // L1046: sum stage 輸出是否有效
                    end                                                                                        // L1047: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L1048: 前面條件皆不成立時執行的預設分支
                        sum_valid_q <= 1'b0;                                                                   // L1049: sum stage 輸出是否有效
                    end                                                                                        // L1050: 結束目前 Verilog 程式區塊

                    if (pipe_launch_q) begin                                                                   // L1052: 條件判斷，依目前狀態或旗標選擇不同流程
                        dot0_q <= mul_q(lb00_c, dot_w0_c);                                                     // L1053: 目前 layer 的 weight[0]
                        dot1_q <= mul_q(lb01_c, dot_w1_c);                                                     // L1054: 目前 layer 的 weight[1]
                        dot2_q <= mul_q(lb02_c, dot_w2_c);                                                     // L1055: 目前 layer 的 weight[2]
                        dot3_q <= mul_q(lb10_c, dot_w3_c);                                                     // L1056: 目前 layer 的 weight[3]
                        dot4_q <= mul_q(lb11_c, dot_w4_c);                                                     // L1057: 目前 layer 的 weight[4]
                        dot5_q <= mul_q(lb12_c, dot_w5_c);                                                     // L1058: 目前 layer 的 weight[5]
                        dot6_q <= mul_q(lb20_c, dot_w6_c);                                                     // L1059: 目前 layer 的 weight[6]
                        dot7_q <= mul_q(lb21_c, dot_w7_c);                                                     // L1060: 目前 layer 的 weight[7]
                        dot8_q <= mul_q(lb22_c, dot_w8_c);                                                     // L1061: 目前 layer 的 weight[8]
                        dot_elem_idx_q <= elem_idx;                                                            // L1062: dot stage 對應的 output element index
                        dot_word_done_q <= word_done;                                                          // L1063: dot stage 這個 element 是否應該完成一個 32-bit output word
                        dot_last_q <= last_elem;                                                               // L1064: dot stage 這個 element 是否為本 layer 最後一個 output
                        dot_row_last_q <= row_last_col;                                                        // L1065: dot stage 這個 element 是否為該 output row 最後一欄
                        dot_valid_q <= 1'b1;                                                                   // L1066: dot stage 輸出是否有效

                        if (last_elem || row_last_col) begin                                                   // L1068: 條件判斷，依目前狀態或旗標選擇不同流程
                            pipe_launch_q <= 1'b0;                                                             // L1069: line-buffer pipeline 是否繼續發射下一個 dot 計算
                        end                                                                                    // L1070: 結束目前 Verilog 程式區塊
                        else begin                                                                             // L1071: 前面條件皆不成立時執行的預設分支
                            elem_idx <= elem_idx + 10'd1;                                                      // L1072: 目前正在處理的 output element index
                            win00_q <= slide00_c;                                                              // L1073: sliding window 往右移後的新 win00
                            win01_q <= slide01_c;                                                              // L1074: sliding window 往右移後的新 win01
                            win02_q <= slide02_c;                                                              // L1075: sliding window 往右移後的新 win02，由 row_buf0 取新 column
                            win10_q <= slide10_c;                                                              // L1076: sliding window 往右移後的新 win10
                            win11_q <= slide11_c;                                                              // L1077: sliding window 往右移後的新 win11
                            win12_q <= slide12_c;                                                              // L1078: sliding window 往右移後的新 win12，由 row_buf1 取新 column
                            win20_q <= slide20_c;                                                              // L1079: sliding window 往右移後的新 win20
                            win21_q <= slide21_c;                                                              // L1080: sliding window 往右移後的新 win21
                            win22_q <= slide22_c;                                                              // L1081: sliding window 往右移後的新 win22，由 row_buf2 取新 column
                            col <= col + 6'd1;                                                                 // L1082: 目前 output element 所在 column
                        end                                                                                    // L1083: 結束目前 Verilog 程式區塊
                    end                                                                                        // L1084: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L1085: 前面條件皆不成立時執行的預設分支
                        dot_valid_q <= 1'b0;                                                                   // L1086: dot stage 輸出是否有效
                    end                                                                                        // L1087: 結束目前 Verilog 程式區塊
                    state <= S_LB_QUANT;                                                                       // L1088: FSM 下一步跳到 S_LB_QUANT：line-buffer 路徑將 sum 做 quantize 並安排 write-back
                end                                                                                            // L1089: 結束目前 Verilog 程式區塊
            end                                                                                                // L1090: 結束目前 Verilog 程式區塊

            S_LB_DRAIN: begin                                                                                  // L1092: FSM 狀態處理：line-buffer pipeline 尾端排空，確保最後一筆 quantize/write-back 完成
                if (quant_valid_q) begin                                                                       // L1093: 條件判斷，依目前狀態或旗標選擇不同流程
                    if (quant_word_done_q) begin                                                               // L1094: 條件判斷，依目前狀態或旗標選擇不同流程
                        wb_valid_q <= 1'b1;                                                                    // L1095: write-back stage 是否有有效資料要寫 Port B
                        wb_addr_q <= quant_write_addr_q;                                                       // L1096: quantized output 對應的 DataMemory write address
                        wb_data_q <= quant_pack_next;                                                          // L1097: registered quantize 結果放入 pack_word 後的下一值
                        pack_word <= 32'd0;                                                                    // L1098: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                        state <= S_LB_DRAIN;                                                                   // L1099: FSM 下一步跳到 S_LB_DRAIN：line-buffer pipeline 尾端排空，確保最後一筆 quantize/write-back 完成
                    end                                                                                        // L1100: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L1101: 前面條件皆不成立時執行的預設分支
                        pack_word <= quant_pack_next;                                                          // L1102: registered quantize 結果放入 pack_word 後的下一值
                        state <= drain_state_q;                                                                // L1103: 更新 FSM state
                    end                                                                                        // L1104: 結束目前 Verilog 程式區塊
                    quant_valid_q <= 1'b0;                                                                     // L1105: quantize stage 是否有有效 output 等待 packing/write-back
                end                                                                                            // L1106: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L1107: 前面條件皆不成立時執行的預設分支
                    state <= drain_state_q;                                                                    // L1108: 更新 FSM state
                end                                                                                            // L1109: 結束目前 Verilog 程式區塊
            end                                                                                                // L1110: 結束目前 Verilog 程式區塊

            S_CALC: begin                                                                                      // L1112: FSM 狀態處理：舊版/row-path 的計算後控制與 sliding window 更新狀態
                if (1'b0) begin                                                                                // L1113: 條件判斷，依目前狀態或旗標選擇不同流程
                    if (word_done) begin                                                                       // L1114: 條件判斷，依目前狀態或旗標選擇不同流程
                        pack_word <= 32'd0;                                                                    // L1115: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                        if (last_elem) begin                                                                   // L1116: 條件判斷，依目前狀態或旗標選擇不同流程
                            state <= S_FIN_REQ;                                                                // L1117: FSM 下一步跳到 S_FIN_REQ：CNN 完成後寫入 DataMemory[10]=1 作為 done flag
                        end                                                                                    // L1118: 結束目前 Verilog 程式區塊
                        else begin                                                                             // L1119: 前面條件皆不成立時執行的預設分支
                            read_addr_q <= next_read_addr;                                                     // L1120: 下一個 row-path 讀取 word address
                            read_byte_sel_q <= next_read_sel;                                                  // L1121: 目前 row-path window 在 word 內的 byte offset
                            cross_word_q <= next_cross_word;                                                   // L1122: 下一個 row-path window 是否跨 word
                            elem_idx <= elem_idx + 10'd1;                                                      // L1123: 目前正在處理的 output element index
                            acc <= bias1_q12;                                                                  // L1124: bias1 轉為 Q?.12 後的 accumulator 格式
                            if (row_last_col) begin                                                            // L1125: 條件判斷，依目前狀態或旗標選擇不同流程
                                col <= 6'd0;                                                                   // L1126: 目前 output element 所在 column
                                row <= row + 6'd1;                                                             // L1127: 目前 output element 所在 row
                                row_base <= row_base + {4'd0, in_size};                                        // L1128: 目前 input row 起始 element index
                            end                                                                                // L1129: 結束目前 Verilog 程式區塊
                            else begin                                                                         // L1130: 前面條件皆不成立時執行的預設分支
                                col <= col + 6'd1;                                                             // L1131: 目前 output element 所在 column
                            end                                                                                // L1132: 結束目前 Verilog 程式區塊
                            state <= S_ADDR_CALC;                                                              // L1133: FSM 下一步跳到 S_ADDR_CALC：準備讀取目前 window 第一個 word 的位址
                        end                                                                                    // L1134: 結束目前 Verilog 程式區塊
                    end                                                                                        // L1135: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L1136: 前面條件皆不成立時執行的預設分支
                        pack_word <= pack_next;                                                                // L1137: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                        read_addr_q <= next_read_addr;                                                         // L1138: 下一個 row-path 讀取 word address
                        read_byte_sel_q <= next_read_sel;                                                      // L1139: 目前 row-path window 在 word 內的 byte offset
                        cross_word_q <= next_cross_word;                                                       // L1140: 下一個 row-path window 是否跨 word
                        row_scan <= 2'd0;                                                                      // L1141: row-path 正在掃描 3x3 window 的第幾列
                        prod_valid_q <= 1'b0;                                                                  // L1142: row-path 乘積暫存是否有效
                        elem_idx <= elem_idx + 10'd1;                                                          // L1143: 目前正在處理的 output element index
                        acc <= bias1_q12;                                                                      // L1144: bias1 轉為 Q?.12 後的 accumulator 格式
                        if (row_last_col) begin                                                                // L1145: 條件判斷，依目前狀態或旗標選擇不同流程
                            col <= 6'd0;                                                                       // L1146: 目前 output element 所在 column
                            row <= row + 6'd1;                                                                 // L1147: 目前 output element 所在 row
                            row_base <= row_base + {4'd0, in_size};                                            // L1148: 目前 input row 起始 element index
                        end                                                                                    // L1149: 結束目前 Verilog 程式區塊
                        else begin                                                                             // L1150: 前面條件皆不成立時執行的預設分支
                            col <= col + 6'd1;                                                                 // L1151: 目前 output element 所在 column
                        end                                                                                    // L1152: 結束目前 Verilog 程式區塊
                        state <= S_ROW_CAP;                                                                    // L1153: FSM 下一步跳到 S_ROW_CAP：擷取 row-path 讀出的 word，必要時處理跨 word 視窗
                    end                                                                                        // L1154: 結束目前 Verilog 程式區塊
                end                                                                                            // L1155: 結束目前 Verilog 程式區塊
                else if (row_path_pixel) begin                                                                 // L1156: 前一個條件不成立時，檢查下一個條件分支
                    row_path_pixel <= 1'b0;                                                                    // L1157: 第一個 window 經 row-path 初始化後，切入 line-buffer path 的旗標
                    if (word_done) begin                                                                       // L1158: 條件判斷，依目前狀態或旗標選擇不同流程
                        pack_word <= 32'd0;                                                                    // L1159: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                        if (last_elem) begin                                                                   // L1160: 條件判斷，依目前狀態或旗標選擇不同流程
                            state <= layer ? S_FIN_REQ : S_CONV2_INIT;                                         // L1161: 更新 FSM state
                        end                                                                                    // L1162: 結束目前 Verilog 程式區塊
                        else begin                                                                             // L1163: 前面條件皆不成立時執行的預設分支
                            elem_idx <= elem_idx + 10'd1;                                                      // L1164: 目前正在處理的 output element index
                            if (row_last_col) begin                                                            // L1165: 條件判斷，依目前狀態或旗標選擇不同流程
                                for (i = 0; i < 9; i = i + 1) begin                                            // L1166: for-loop，通常用於 reset 初始化或 row buffer 搬移
                                    row_buf0[i] <= row_buf1[i];                                                // L1167: line-buffer 的 top row physical buffer
                                    row_buf1[i] <= row_buf2[i];                                                // L1168: line-buffer 的 middle row physical buffer
                                end                                                                            // L1169: 結束目前 Verilog 程式區塊
                                row0_sel <= row1_sel;                                                          // L1170: row_buf1 的 byte alignment offset
                                row1_sel <= row2_sel;                                                          // L1171: row_buf2 的 byte alignment offset
                                col <= 6'd0;                                                                   // L1172: 目前 output element 所在 column
                                row <= row + 6'd1;                                                             // L1173: 目前 output element 所在 row
                                row_base <= next_top_row_base;                                                 // L1174: 滑到下一個 output row 時新的 top row base
                                load_row_sel <= 2'd2;                                                          // L1175: 目前正在載入 row_buf0/1/2 的選擇
                                load_word_idx <= 4'd0;                                                         // L1176: 目前載入一列中的第幾個 32-bit word
                                load_row_base <= next_bottom_load_base;                                        // L1177: 滑到下一個 output row 時需要載入的新 bottom row base
                                load_words_q <= next_bottom_load_words;                                        // L1178: 新 bottom row 需要載入的 word 數量
                                state <= S_BUF_REQ;                                                            // L1179: FSM 下一步跳到 S_BUF_REQ：送出 line buffer 載入 row word 的讀取請求
                            end                                                                                // L1180: 結束目前 Verilog 程式區塊
                            else begin                                                                         // L1181: 前面條件皆不成立時執行的預設分支
                                win00_q <= get_buf0_byte(col + 6'd1);                                          // L1182: 3x3 window 第 0 row 第 0 col pixel
                                win01_q <= get_buf0_byte(col + 6'd2);                                          // L1183: 3x3 window 第 0 row 第 1 col pixel
                                win02_q <= get_buf0_byte(col + 6'd3);                                          // L1184: 3x3 window 第 0 row 第 2 col pixel
                                win10_q <= get_buf1_byte(col + 6'd1);                                          // L1185: 3x3 window 第 1 row 第 0 col pixel
                                win11_q <= get_buf1_byte(col + 6'd2);                                          // L1186: 3x3 window 第 1 row 第 1 col pixel
                                win12_q <= get_buf1_byte(col + 6'd3);                                          // L1187: 3x3 window 第 1 row 第 2 col pixel
                                win20_q <= get_buf2_byte(col + 6'd1);                                          // L1188: 3x3 window 第 2 row 第 0 col pixel
                                win21_q <= get_buf2_byte(col + 6'd2);                                          // L1189: 3x3 window 第 2 row 第 1 col pixel
                                win22_q <= get_buf2_byte(col + 6'd3);                                          // L1190: 3x3 window 第 2 row 第 2 col pixel
                                col <= col + 6'd1;                                                             // L1191: 目前 output element 所在 column
                                state <= S_DOT;                                                                // L1192: FSM 下一步跳到 S_DOT：line-buffer 路徑中對 3x3 window 的 9 個乘法啟動暫存
                            end                                                                                // L1193: 結束目前 Verilog 程式區塊
                        end                                                                                    // L1194: 結束目前 Verilog 程式區塊
                    end                                                                                        // L1195: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L1196: 前面條件皆不成立時執行的預設分支
                        pack_word <= pack_next;                                                                // L1197: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                        elem_idx <= elem_idx + 10'd1;                                                          // L1198: 目前正在處理的 output element index
                        if (row_last_col) begin                                                                // L1199: 條件判斷，依目前狀態或旗標選擇不同流程
                            for (i = 0; i < 9; i = i + 1) begin                                                // L1200: for-loop，通常用於 reset 初始化或 row buffer 搬移
                                row_buf0[i] <= row_buf1[i];                                                    // L1201: line-buffer 的 top row physical buffer
                                row_buf1[i] <= row_buf2[i];                                                    // L1202: line-buffer 的 middle row physical buffer
                            end                                                                                // L1203: 結束目前 Verilog 程式區塊
                            row0_sel <= row1_sel;                                                              // L1204: row_buf1 的 byte alignment offset
                            row1_sel <= row2_sel;                                                              // L1205: row_buf2 的 byte alignment offset
                            col <= 6'd0;                                                                       // L1206: 目前 output element 所在 column
                            row <= row + 6'd1;                                                                 // L1207: 目前 output element 所在 row
                            row_base <= next_top_row_base;                                                     // L1208: 滑到下一個 output row 時新的 top row base
                            load_row_sel <= 2'd2;                                                              // L1209: 目前正在載入 row_buf0/1/2 的選擇
                            load_word_idx <= 4'd0;                                                             // L1210: 目前載入一列中的第幾個 32-bit word
                            load_row_base <= next_bottom_load_base;                                            // L1211: 滑到下一個 output row 時需要載入的新 bottom row base
                            load_words_q <= next_bottom_load_words;                                            // L1212: 新 bottom row 需要載入的 word 數量
                            state <= S_BUF_REQ;                                                                // L1213: FSM 下一步跳到 S_BUF_REQ：送出 line buffer 載入 row word 的讀取請求
                        end                                                                                    // L1214: 結束目前 Verilog 程式區塊
                        else begin                                                                             // L1215: 前面條件皆不成立時執行的預設分支
                            win00_q <= get_buf0_byte(col + 6'd1);                                              // L1216: 3x3 window 第 0 row 第 0 col pixel
                            win01_q <= get_buf0_byte(col + 6'd2);                                              // L1217: 3x3 window 第 0 row 第 1 col pixel
                            win02_q <= get_buf0_byte(col + 6'd3);                                              // L1218: 3x3 window 第 0 row 第 2 col pixel
                            win10_q <= get_buf1_byte(col + 6'd1);                                              // L1219: 3x3 window 第 1 row 第 0 col pixel
                            win11_q <= get_buf1_byte(col + 6'd2);                                              // L1220: 3x3 window 第 1 row 第 1 col pixel
                            win12_q <= get_buf1_byte(col + 6'd3);                                              // L1221: 3x3 window 第 1 row 第 2 col pixel
                            win20_q <= get_buf2_byte(col + 6'd1);                                              // L1222: 3x3 window 第 2 row 第 0 col pixel
                            win21_q <= get_buf2_byte(col + 6'd2);                                              // L1223: 3x3 window 第 2 row 第 1 col pixel
                            win22_q <= get_buf2_byte(col + 6'd3);                                              // L1224: 3x3 window 第 2 row 第 2 col pixel
                            col <= col + 6'd1;                                                                 // L1225: 目前 output element 所在 column
                            state <= S_DOT;                                                                    // L1226: FSM 下一步跳到 S_DOT：line-buffer 路徑中對 3x3 window 的 9 個乘法啟動暫存
                        end                                                                                    // L1227: 結束目前 Verilog 程式區塊
                    end                                                                                        // L1228: 結束目前 Verilog 程式區塊
                end                                                                                            // L1229: 結束目前 Verilog 程式區塊
                else if (word_done) begin                                                                      // L1230: 前一個條件不成立時，檢查下一個條件分支
                    pack_word <= 32'd0;                                                                        // L1231: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                    if (last_elem) begin                                                                       // L1232: 條件判斷，依目前狀態或旗標選擇不同流程
                        state <= layer ? S_FIN_REQ : S_CONV2_INIT;                                             // L1233: 更新 FSM state
                    end                                                                                        // L1234: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L1235: 前面條件皆不成立時執行的預設分支
                        elem_idx <= elem_idx + 10'd1;                                                          // L1236: 目前正在處理的 output element index
                        if (row_last_col) begin                                                                // L1237: 條件判斷，依目前狀態或旗標選擇不同流程
                            for (i = 0; i < 9; i = i + 1) begin                                                // L1238: for-loop，通常用於 reset 初始化或 row buffer 搬移
                                row_buf0[i] <= row_buf1[i];                                                    // L1239: line-buffer 的 top row physical buffer
                                row_buf1[i] <= row_buf2[i];                                                    // L1240: line-buffer 的 middle row physical buffer
                            end                                                                                // L1241: 結束目前 Verilog 程式區塊
                            row0_sel <= row1_sel;                                                              // L1242: row_buf1 的 byte alignment offset
                            row1_sel <= row2_sel;                                                              // L1243: row_buf2 的 byte alignment offset
                            col <= 6'd0;                                                                       // L1244: 目前 output element 所在 column
                            row <= row + 6'd1;                                                                 // L1245: 目前 output element 所在 row
                            row_base <= next_top_row_base;                                                     // L1246: 滑到下一個 output row 時新的 top row base
                            load_row_sel <= 2'd2;                                                              // L1247: 目前正在載入 row_buf0/1/2 的選擇
                            load_word_idx <= 4'd0;                                                             // L1248: 目前載入一列中的第幾個 32-bit word
                            load_row_base <= next_bottom_load_base;                                            // L1249: 滑到下一個 output row 時需要載入的新 bottom row base
                            load_words_q <= next_bottom_load_words;                                            // L1250: 新 bottom row 需要載入的 word 數量
                            state <= S_BUF_REQ;                                                                // L1251: FSM 下一步跳到 S_BUF_REQ：送出 line buffer 載入 row word 的讀取請求
                        end                                                                                    // L1252: 結束目前 Verilog 程式區塊
                        else begin                                                                             // L1253: 前面條件皆不成立時執行的預設分支
                            win00_q <= win01_q;                                                                // L1254: 3x3 window 第 0 row 第 1 col pixel
                            win01_q <= win02_q;                                                                // L1255: 3x3 window 第 0 row 第 2 col pixel
                            win02_q <= get_buf0_byte(col + 6'd3);                                              // L1256: 3x3 window 第 0 row 第 2 col pixel
                            win10_q <= win11_q;                                                                // L1257: 3x3 window 第 1 row 第 1 col pixel
                            win11_q <= win12_q;                                                                // L1258: 3x3 window 第 1 row 第 2 col pixel
                            win12_q <= get_buf1_byte(col + 6'd3);                                              // L1259: 3x3 window 第 1 row 第 2 col pixel
                            win20_q <= win21_q;                                                                // L1260: 3x3 window 第 2 row 第 1 col pixel
                            win21_q <= win22_q;                                                                // L1261: 3x3 window 第 2 row 第 2 col pixel
                            win22_q <= get_buf2_byte(col + 6'd3);                                              // L1262: 3x3 window 第 2 row 第 2 col pixel
                            col <= col + 6'd1;                                                                 // L1263: 目前 output element 所在 column
                            state <= S_DOT;                                                                    // L1264: FSM 下一步跳到 S_DOT：line-buffer 路徑中對 3x3 window 的 9 個乘法啟動暫存
                        end                                                                                    // L1265: 結束目前 Verilog 程式區塊
                    end                                                                                        // L1266: 結束目前 Verilog 程式區塊
                end                                                                                            // L1267: 結束目前 Verilog 程式區塊
                else begin                                                                                     // L1268: 前面條件皆不成立時執行的預設分支
                    pack_word <= pack_next;                                                                    // L1269: 暫存 4 個 8-bit output，準備組成 32-bit word 寫回
                    elem_idx <= elem_idx + 10'd1;                                                              // L1270: 目前正在處理的 output element index
                    if (row_last_col) begin                                                                    // L1271: 條件判斷，依目前狀態或旗標選擇不同流程
                        for (i = 0; i < 9; i = i + 1) begin                                                    // L1272: for-loop，通常用於 reset 初始化或 row buffer 搬移
                            row_buf0[i] <= row_buf1[i];                                                        // L1273: line-buffer 的 top row physical buffer
                            row_buf1[i] <= row_buf2[i];                                                        // L1274: line-buffer 的 middle row physical buffer
                        end                                                                                    // L1275: 結束目前 Verilog 程式區塊
                        row0_sel <= row1_sel;                                                                  // L1276: row_buf1 的 byte alignment offset
                        row1_sel <= row2_sel;                                                                  // L1277: row_buf2 的 byte alignment offset
                        col <= 6'd0;                                                                           // L1278: 目前 output element 所在 column
                        row <= row + 6'd1;                                                                     // L1279: 目前 output element 所在 row
                        row_base <= next_top_row_base;                                                         // L1280: 滑到下一個 output row 時新的 top row base
                        load_row_sel <= 2'd2;                                                                  // L1281: 目前正在載入 row_buf0/1/2 的選擇
                        load_word_idx <= 4'd0;                                                                 // L1282: 目前載入一列中的第幾個 32-bit word
                        load_row_base <= next_bottom_load_base;                                                // L1283: 滑到下一個 output row 時需要載入的新 bottom row base
                        load_words_q <= next_bottom_load_words;                                                // L1284: 新 bottom row 需要載入的 word 數量
                        state <= S_BUF_REQ;                                                                    // L1285: FSM 下一步跳到 S_BUF_REQ：送出 line buffer 載入 row word 的讀取請求
                    end                                                                                        // L1286: 結束目前 Verilog 程式區塊
                    else begin                                                                                 // L1287: 前面條件皆不成立時執行的預設分支
                        win00_q <= win01_q;                                                                    // L1288: 3x3 window 第 0 row 第 1 col pixel
                        win01_q <= win02_q;                                                                    // L1289: 3x3 window 第 0 row 第 2 col pixel
                        win02_q <= get_buf0_byte(col + 6'd3);                                                  // L1290: 3x3 window 第 0 row 第 2 col pixel
                        win10_q <= win11_q;                                                                    // L1291: 3x3 window 第 1 row 第 1 col pixel
                        win11_q <= win12_q;                                                                    // L1292: 3x3 window 第 1 row 第 2 col pixel
                        win12_q <= get_buf1_byte(col + 6'd3);                                                  // L1293: 3x3 window 第 1 row 第 2 col pixel
                        win20_q <= win21_q;                                                                    // L1294: 3x3 window 第 2 row 第 1 col pixel
                        win21_q <= win22_q;                                                                    // L1295: 3x3 window 第 2 row 第 2 col pixel
                        win22_q <= get_buf2_byte(col + 6'd3);                                                  // L1296: 3x3 window 第 2 row 第 2 col pixel
                        col <= col + 6'd1;                                                                     // L1297: 目前 output element 所在 column
                        state <= S_DOT;                                                                        // L1298: FSM 下一步跳到 S_DOT：line-buffer 路徑中對 3x3 window 的 9 個乘法啟動暫存
                    end                                                                                        // L1299: 結束目前 Verilog 程式區塊
                end                                                                                            // L1300: 結束目前 Verilog 程式區塊
            end                                                                                                // L1301: 結束目前 Verilog 程式區塊

            S_FIN_REQ: begin                                                                                   // L1303: FSM 狀態處理：CNN 完成後寫入 DataMemory[10]=1 作為 done flag
                done <= 1'b1;                                                                                  // L1304: CNN 內部完成旗標，S_DONE 後維持為 1
                state <= S_DONE;                                                                               // L1305: FSM 下一步跳到 S_DONE：CNN 結束狀態，done 持續維持為 1
            end                                                                                                // L1306: 結束目前 Verilog 程式區塊

            S_DONE: begin                                                                                      // L1308: FSM 狀態處理：CNN 結束狀態，done 持續維持為 1
                done <= 1'b1;                                                                                  // L1309: CNN 內部完成旗標，S_DONE 後維持為 1
            end                                                                                                // L1310: 結束目前 Verilog 程式區塊

            default: begin                                                                                     // L1312: case 的 default 分支，處理未列出的情況
                state <= S_WAIT;                                                                               // L1313: FSM 下一步跳到 S_WAIT：重置釋放後的等待狀態，避免太早讀取尚未準備好的記憶體資料
            end                                                                                                // L1314: 結束目前 Verilog 程式區塊
        endcase                                                                                                // L1315: 結束 case 分支
    end                                                                                                        // L1316: 結束目前 Verilog 程式區塊
end                                                                                                            // L1317: 結束目前 Verilog 程式區塊

endmodule                                                                                                      // L1319: 結束 CNN 模組

