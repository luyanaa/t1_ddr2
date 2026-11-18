// ========== Copyright Header Begin ==========================================
//
// tb_dimm_smoke.v -- smoke test for dimm_iverilog.v (GPL-2.0, like dimm.v).
// Drives MRS -> EMRS -> ACT -> WRITE(BL2) -> READ and checks read-back.
// GPL-2.0 derivative for the same reason as the model it exercises.
//
// ========== Copyright Header End ============================================
`timescale 1ps/1ps

module tb_dimm_smoke;

   reg [2:0] clk;
   reg [1:0] cs;          // ACTIVE-LOW chip select (T1 convention)
   reg       ras, cas, we;
   reg [2:0] ba;
   reg [16:0] addr;
   reg [7:0]  cs_sel;

   wire [63:0] dataq;
   wire [7:0]  ecc;
   wire [8:0]  dqs, dm_rdqs;

   reg        drv_oe;
   reg        drv_dqs_oe;
   reg        drv_dqs;
   reg [63:0] drv_dq;
   reg [7:0]  drv_ecc;
   assign dataq = drv_oe ? drv_dq : 64'hzzzz_zzzz_zzzz_zzzz;
   assign ecc   = drv_oe ? drv_ecc : 8'hzz;
   // host drives dqs during writes (dqs is inout like dq)
   assign dqs     = drv_dqs_oe ? {9{drv_dqs}} : 9'hzz;
   assign dm_rdqs = drv_dqs_oe ? {9{drv_dqs}} : 9'hzz;

   dimm_iverilog dut (
      .clk(clk), .cs(cs), .ras(ras), .cas(cas), .we(we),
      .ba(ba), .addr(addr), .cs_sel(cs_sel),
      .dataq(dataq), .ecc(ecc), .dqs(dqs), .dm_rdqs(dm_rdqs)
   );

   // 200 MHz = 5000 ps period. dly=400ps inside the model samples commands.
   always #2500 clk[0] = ~clk[0];
   initial clk[2:1] = 2'b00;

   integer errors;
   integer i;

   task cmd(input [2:0] c, input [2:0] b, input [16:0] a);
      begin
         @(negedge clk[0]);
         cs  = 2'b00;                 // assert chip select (active low)
         {ras, cas, we} = c;
         ba  = b; addr = a;
      end
   endtask
   task nop; begin
      @(negedge clk[0]); cs = 2'b11; {ras,cas,we} = 3'b111;
   end endtask

   // WRITE a single-beat command. dataq_d is sampled on dqs edges, so drive
   // the data, pulse dqs once, and let the write_queue drain the entry.
   task wr1(input [2:0] b, input [16:0] a, input [63:0] d0);
      begin
         cmd(3'b100, b, a);            // WRITE
         drv_oe = 1; drv_ecc = 8'h00; drv_dqs_oe = 1;
         drv_dq = d0; drv_dqs = 1'b0;
         nop;                           // command registered
         // give dqs a couple of edges so dataq_d settles on d0 well before
         // the write_queue reaches the entry
         @(negedge clk[0]); drv_dqs = 1'b1;
         @(posedge clk[0]);
         @(negedge clk[0]); drv_dqs = 1'b0;
         @(posedge clk[0]);
         repeat (6) @(negedge clk[0]);  // let the queue drain Write_mem
         drv_oe = 0; drv_dqs_oe = 0;
      end
   endtask

   initial begin
      errors = 0;
      clk = 3'b0; cs = 2'b11; {ras,cas,we} = 3'b111;
      ba = 0; addr = 0; cs_sel = 0;
      drv_oe = 0; drv_dq = 0; drv_ecc = 0;
      drv_dqs_oe = 0; drv_dqs = 0;
      repeat (4) @(negedge clk[0]);

      // MRS (ba=0): BurstLen=1<<addr[2:0]=2 (addr[2:0]=001), CasLat=addr[6:4]=3
      cmd(3'b000, 3'b000, {10'h0,3'b011,1'b0,3'b001}); nop;
      // EMRS (ba=1): AlignLat = addr[5:3] = 0
      cmd(3'b000, 3'b001, 17'h0); nop;
      repeat (4) @(negedge clk[0]);
      if (dut.BurstLen == 2 && dut.CasLat == 3)
        $display("PASS MRS: BurstLen=%0d CasLat=%0d", dut.BurstLen, dut.CasLat);
      else begin
        $display("FAIL MRS: BurstLen=%0d CasLat=%0d", dut.BurstLen, dut.CasLat);
        errors = errors + 1;
      end

      // ACT bank0 row 0x0123
      cmd(3'b011, 3'b000, 17'h0123); nop;

      // WRITE two adjacent columns, one WRITE command each (single-beat
      // timing is unambiguous). Burst READ then returns both.
      wr1(3'b000, 17'h0004, 64'hDEADBEEF_CAFEF00D);
      wr1(3'b000, 17'h0008, 64'h01234567_89ABCDEF);
      if (dut.mem_free >= 2)
        $display("PASS WRITE: mem_free=%0d", dut.mem_free);
      else begin
        $display("FAIL WRITE: mem_free=%0d", dut.mem_free);
        errors = errors + 1;
      end

      // READ same col
      cmd(3'b101, 3'b000, 17'h0004); nop;

      // capture read data as it appears on the bus
      // Read back the first beat of the burst at col4 - the one address the
      // smoke test wrote with certainty. The burst's second entry maps to
      // col5 (ColAddr+n) which was never written, so we only assert beat0.
      wait (dataq !== 64'hzzzz_zzzz_zzzz_zzzz);
      if (dataq === 64'hDEADBEEF_CAFEF00D)
        $display("PASS READ beat0 %h", dataq);
      else begin
        $display("FAIL READ beat0 %h (exp DEADBEEF_CAFEF00D)", dataq);
        errors = errors + 1;
      end
      repeat (4) @(negedge clk[0]);
      // Also verify the second written column is independently readable.
      cmd(3'b101, 3'b000, 17'h0008); nop;
      wait (dataq !== 64'hzzzz_zzzz_zzzz_zzzz);
      if (dataq === 64'h01234567_89ABCDEF)
        $display("PASS READ col8 %h", dataq);
      else begin
        $display("FAIL READ col8 %h (exp 01234567_89ABCDEF)", dataq);
        errors = errors + 1;
      end

      repeat (4) @(negedge clk[0]);
      if (errors == 0) $display("SMOKE_PASS"); else $display("SMOKE_FAIL %0d", errors);
      $finish;
   end

   initial begin
      #1000000;
      $display("TIMEOUT"); $finish;
   end

endmodule
