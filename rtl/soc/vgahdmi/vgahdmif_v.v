// 640x480 video display

// Emard:
// doubling x and y pixel size
// adding both HDMI and VGA output
// no vendor-specific modules here
// (differential buffers, PLLs)

// LICENSE=BSD

// some code taken from
// (c) fpga4fun.com & KNJN LLC 2013

////////////////////////////////////////////////////////////////////////
module vgahdmi_v(
        input wire clk, /* CPU clock */
        input wire clk_pixel, /* 25 MHz */
        input wire clk_tmds, /* 250 MHz (set to 0 for VGA-only) */
        input wire [7:0] dispData, // get data from fifo
        output wire rd, // video reads data during clock cycle when rd=1
        // next cycle: free time for fifo to prepare new data
        output wire vga_hsync, vga_vsync, // active low, vsync will reset fifo
        output wire [2:0] vga_r, vga_g, vga_b,
	output wire [2:0] TMDS_out_RGB
);

parameter test_picture = 0;
parameter dbl_x = 0; // 0-normal X, 1-double X
parameter dbl_y = 0; // 0-normal Y, 1-double Y
parameter mem_size_kb = 4; // KB
parameter mem_size_y = (mem_size_kb * 1024 / (640/8)) << (dbl_x + dbl_y); // depending on available RAM we can lower this


////////////////////////////////////////////////////////////////////////

wire clk_TMDS;
wire pixclk;

assign clk_TMDS = clk_tmds; // 250 MHz
assign pixclk = clk_pixel;  //  25 MHz

reg [9:0] CounterX, CounterY;
reg hSync, vSync, DrawArea;
always @(posedge pixclk) DrawArea <= (CounterX<640) && (CounterY<480);

always @(posedge pixclk) CounterX <= (CounterX==799) ? 0 : CounterX+1;
always @(posedge pixclk) if(CounterX==799) CounterY <= (CounterY==524) ? 0 : CounterY+1;

always @(posedge pixclk) hSync <= (CounterX>=656) && (CounterX<752);
always @(posedge pixclk) vSync <= (CounterY>=490) && (CounterY<492);

// signal when to change address (to get new data from the memory)
// phase shifted some pixels after the data fetch
// so memory will have enough time to select new address and
// stabilize data on the bus
wire changeaddr;
assign changeaddr = CounterX[2+dbl_x:0] == 2;

parameter synclen = 3; // >=3, bit length of the clock synchronizer shift register
reg [synclen-1:0] clksync; /* fifo to clock synchronizer shift register */

// signal: when to shift pixel data and when to get new data from the memory
wire getdata;
assign getdata = CounterX[2+dbl_x:0] == 0 && DrawArea;

/* clk-to-pixclk synchronizer:
** pixclk rising edge is detected using shift register
** edge detection happens after delay (clk * synclen)
** then rd is set high for one clk cycle
** intiating fetch from new data from RAM fifo
** for various clk and pixclk ratios, synclen may need to be adjusted
** in order not to change dispData before content is copied to shiftData register
*/
always @(posedge clk)
  clksync <= {clksync[synclen-2:0], pixclk}; // at bit 0 enter new pixclk value
assign rd = clksync[synclen-2] == 0 && clksync[synclen-1] == 1;  // rd = pixclk rising edge

reg [7:0] shiftData;
always @(posedge pixclk)
  begin
    if(dbl_x == 0 || CounterX[0] == 0)
      shiftData <= getdata != 0 ? dispData : shiftData[7:1];
  end

wire [7:0] colorValue;
assign colorValue = (mem_size_y < 480 ? CounterY < mem_size_y-dbl_y : 1==1) && shiftData[0] != 0 ? 255 : 0;

// test picture generator
wire [7:0] W = {8{CounterX[7:0]==CounterY[7:0]}};
wire [7:0] A = {8{CounterX[7:5]==3'h2 && CounterY[7:5]==3'h2}};
reg [7:0] test_red, test_green, test_blue;
always @(posedge pixclk) test_red <= ({CounterX[5:0] & {6{CounterY[4:3]==~CounterX[4:3]}}, 2'b00} | W) & ~A;
always @(posedge pixclk) test_green <= (CounterX[7:0] & {8{CounterY[6]}} | W) & ~A;
always @(posedge pixclk) test_blue <= CounterY[7:0] | W | A;

// generate VGA output, mixing with test picture if enabled
assign vga_r = test_picture ? test_red[7:5] :  colorValue[7:5];
assign vga_g =                                 colorValue[7:5];
assign vga_b = test_picture ? test_blue[7:5] : colorValue[7:5];
assign vga_hsync = ~hSync;
assign vga_vsync = ~vSync;

// generate HDMI output, mixing with test picture if enabled
wire [9:0] TMDS_red, TMDS_green, TMDS_blue;

TMDS_encoder encode_R
(
  .clk(pixclk),
  .VD(test_picture ? test_red : colorValue),
  .CD(2'b00),
  .VDE(DrawArea),
  .TMDS(TMDS_red)
);
TMDS_encoder encode_G
(
  .clk(pixclk),
  .VD(colorValue),
  .CD(2'b00),
  .VDE(DrawArea),
  .TMDS(TMDS_green)
);
TMDS_encoder encode_B
(
  .clk(pixclk),
  .VD(test_picture ? test_blue : colorValue),
  .CD({vSync,hSync}),
  .VDE(DrawArea),
  .TMDS(TMDS_blue)
);

////////////////////////////////////////////////////////////////////////
reg [3:0] TMDS_mod10=0;  // modulus 10 counter
reg [9:0] TMDS_shift_red=0, TMDS_shift_green=0, TMDS_shift_blue=0;
reg TMDS_shift_load=0;
always @(posedge clk_TMDS) TMDS_shift_load <= (TMDS_mod10==4'd9);

always @(posedge clk_TMDS)
begin
	TMDS_shift_red   <= TMDS_shift_load ? TMDS_red   : TMDS_shift_red  [9:1];
	TMDS_shift_green <= TMDS_shift_load ? TMDS_green : TMDS_shift_green[9:1];
	TMDS_shift_blue  <= TMDS_shift_load ? TMDS_blue  : TMDS_shift_blue [9:1];
	TMDS_mod10 <= (TMDS_mod10==4'd9) ? 4'd0 : TMDS_mod10+4'd1;
end

// ******* HDMI OUTPUT ********
assign TMDS_out_RGB = {TMDS_shift_red[0], TMDS_shift_green[0], TMDS_shift_blue[0]};
endmodule

////////////////////////////////////////////////////////////////////////
module TMDS_encoder(
	input clk,
	input [7:0] VD,  // video data (red, green or blue)
	input [1:0] CD,  // control data
	input VDE,  // video data enable, to choose between CD (when VDE=0) and VD (when VDE=1)
	output reg [9:0] TMDS = 0
);

wire [3:0] Nb1s = VD[0] + VD[1] + VD[2] + VD[3] + VD[4] + VD[5] + VD[6] + VD[7];
wire XNOR = (Nb1s>4'd4) || (Nb1s==4'd4 && VD[0]==1'b0);
wire [8:0] q_m = {~XNOR, q_m[6:0] ^ VD[7:1] ^ {7{XNOR}}, VD[0]};

reg [3:0] balance_acc = 0;
wire [3:0] balance = q_m[0] + q_m[1] + q_m[2] + q_m[3] + q_m[4] + q_m[5] + q_m[6] + q_m[7] - 4'd4;
wire balance_sign_eq = (balance[3] == balance_acc[3]);
wire invert_q_m = (balance==0 || balance_acc==0) ? ~q_m[8] : balance_sign_eq;
wire [3:0] balance_acc_inc = balance - ({q_m[8] ^ ~balance_sign_eq} & ~(balance==0 || balance_acc==0));
wire [3:0] balance_acc_new = invert_q_m ? balance_acc-balance_acc_inc : balance_acc+balance_acc_inc;
wire [9:0] TMDS_data = {invert_q_m, q_m[8], q_m[7:0] ^ {8{invert_q_m}}};
wire [9:0] TMDS_code = CD[1] ? (CD[0] ? 10'b1010101011 : 10'b0101010100) : (CD[0] ? 10'b0010101011 : 10'b1101010100);

always @(posedge clk) TMDS <= VDE ? TMDS_data : TMDS_code;
always @(posedge clk) balance_acc <= VDE ? balance_acc_new : 4'h0;
endmodule

////////////////////////////////////////////////////////////////////////