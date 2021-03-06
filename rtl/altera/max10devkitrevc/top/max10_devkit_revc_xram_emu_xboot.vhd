-- AUTHOR=EMARD
-- LICENSE=BSD

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use ieee.math_real.all; -- to calculate log2 bit size

use work.f32c_pack.all;
use work.boot_block_pack.all;
use work.boot_sio_mi32el.all;
use work.boot_sio_mi32eb.all;
use work.boot_sio_rv32el.all;
use work.boot_rom_mi32el.all;

entity max10_devkit_revc_xram is
    generic
    (
	-- ISA: either ARCH_MI32 or ARCH_RV32
	C_arch: integer := ARCH_MI32;
	C_debug: boolean := false;
        C_mult_enable: boolean := true;
        C_regfile_synchronous_read: boolean := false; -- false: disabled, true: enabled but doesn't help for MAX10
        --C_mul_acc: boolean := false;    -- MI32 only
        --C_mul_reg: boolean := false;    -- MI32 only
        --C_branch_likely: boolean := false;
        --C_sign_extend: boolean := false;
        --C_ll_sc: boolean := false;
        --C_PC_mask: std_logic_vector(31 downto 0) := x"00ffffff"; -- 1MB
        --C_exceptions: boolean := false;

        -- COP0 options
        --C_cop0_count: boolean := false;
        --C_cop0_compare: boolean := false;
        --C_cop0_config: boolean := false;

        -- CPU core configuration options
        --C_branch_prediction: boolean := false;
        --C_full_shifter: boolean := false;
        --C_result_forwarding: boolean := false;
        --C_load_aligner: boolean := false;

        -- Negatively influences timing closure, hence disabled
        --C_movn_movz: boolean := false;
        
        -- altera vendor-specific "dual image" config
        -- where BRAM initialization is done using on-chip flash
        C_altera_dual_config: boolean := false;

	-- Main clock: 25/77/100 MHz
	C_clk_freq: integer := 100;

	-- SoC configuration options
	C_bram_size: integer := 0; -- BRAM disabled
	C_bram_const_init: boolean := false; -- MAX10 cannot preload bootloader using VHDL constant intializer
	C_boot_write_protect: boolean := false; -- leave boot block writeable
	C_xboot_rom: boolean := true; -- bootloader initializes XRAM with external DMA
        C_boot_rom_data_bits: integer := 32; -- number of bits in output from bootrom_emu
        C_icache_size: integer := 0;
        C_dcache_size: integer := 0;
        C_cached_addr_bits: integer := 20; -- lower address bits than C_cached_addr_bits are cached
        C_xram_base: std_logic_vector(31 downto 28) := x"0"; -- XRAM (acram/sram emu) at address 0 (instead of disabled BRAM)
        C_xram_emu_kb: integer := 128; -- KB XRAM emu size (power of 2, MAX 32 here)
        C_sram: boolean := false; -- enable either C_acram or C_sram, not both
        C_sram_refresh: boolean := false; -- sram_emu doesn't need that
        C_sram_wait_cycles: integer := 3; -- >= 3 works
        C_sram_pipelined_read: boolean := false; -- normally use false here (true only for some SRAM chips)
        C_acram: boolean := true; -- enable either C_acram or C_sram, not both
        C_acram_wait_cycles: integer := 4; -- >= 4 works (other boards work with >= 3)

        C_hdmi_out: boolean := false;
        C_dvid_ddr: boolean := false;

        C_video_mode: integer := 1; -- 0:640x360, 1:640x480, 2:800x480, 3:800x600, 5:1024x768

        C_vgahdmi: boolean := true; -- simple VGA bitmap with compositing
        C_vgahdmi_cache_size: integer := 0; -- KB (0 to disable, 2,4,8,16,32 to enable)
        -- normally this should be  actual bits per pixel
        C_vgahdmi_fifo_data_width: integer range 8 to 32 := 8;
        -- width of FIFO address space -> size of fifo
        -- for 8bpp compositing use 11 -> 2048 bytes

	C_sio: integer := 1;
	C_gpio: integer := 16;
	C_timer: boolean := true; -- needs simple out of 32 elements ?
	C_simple_in: integer := 1;
	C_simple_out: integer := 32
    );
    port
    (
	clk_25_max10: in std_logic;
	uart_tx: out std_logic;
	uart_rx: in std_logic;
	user_led: out std_logic_vector(4 downto 0);
	user_pb: in std_logic_vector(3 downto 0); -- pushbuttons
	user_dipsw: in std_logic_vector(4 downto 0);
	-- ADV7513 video chip
        hdmi_sda: inout std_logic;
        hdmi_scl: inout std_logic;
        hdmi_tx_clk: out std_logic;
        hdmi_tx_int: inout std_logic;
        hdmi_tx_de: out std_logic;
        hdmi_tx_hs: out std_logic;
        hdmi_tx_vs: out std_logic;
        --hdmi_tx_spdif: out std_logic;
        --hdmi_tx_mclk: out std_logic;
        --hdmi_tx_i2s: out std_logic_vector(3 downto 0);
        --hdmi_tx_sclk: out std_logic;
        --hdmi_tx_lrclk: out std_logic;
        hdmi_tx_d: out std_logic_vector(23 downto 0)
    );
end;

architecture Behavioral of max10_devkit_revc_xram is
  -- useful for conversion from KB to number of address bits
  function ceil_log2(x: integer)
      return integer is
  begin
      return integer(ceil((log2(real(x)-1.0E-6))-1.0E-6)); -- 256 -> 8, 257 -> 9
  end ceil_log2;

  signal clk: std_logic;
  signal clk_pixel, clk_pixel_shift: std_logic;
  signal S_reset: std_logic := '0';
  signal xdma_addr: std_logic_vector(29 downto 2) := ('0', others => '0'); -- preload address 0x00000000 XRAM
  signal xdma_strobe: std_logic := '0';
  signal xdma_data_ready: std_logic;
  signal xdma_write: std_logic := '0';
  signal xdma_byte_sel: std_logic_vector(3 downto 0) := (others => '1');
  signal xdma_data_in: std_logic_vector(31 downto 0) := (others => '-');
  -- signals for ROM emulation
  signal S_rom_reset, S_rom_next_data: std_logic;
  signal S_rom_data: std_logic_vector(C_boot_rom_data_bits-1 downto 0);
  signal S_rom_valid: std_logic;
  signal ram_en             : std_logic;
  signal ram_byte_we        : std_logic_vector(3 downto 0) := (others => '0');
  signal ram_address        : std_logic_vector(31 downto 0) := (others => '0');
  signal ram_data_write     : std_logic_vector(31 downto 0) := (others => '0');
  signal ram_data_read      : std_logic_vector(31 downto 0) := (others => '0');
  signal ram_ready          : std_logic := '1';
  signal sram_a: std_logic_vector(19 downto 0) := (others => '0');
  signal sram_d: std_logic_vector(15 downto 0);
  signal sram_wel, sram_lbl, sram_ubl: std_logic;
  signal S_hdmi_pd0, S_hdmi_pd1, S_hdmi_pd2: std_logic_vector(9 downto 0);
  signal tx_in: std_logic_vector(29 downto 0);
  signal tmds_d: std_logic_vector(3 downto 0);
  signal R_blinky: std_logic_vector(25 downto 0);
  signal S_uart_break: std_logic;
  signal S_vga_blank: std_logic;
  signal S_vga_hsync, S_vga_vsync: std_logic;
begin
    G_25m_clk: if C_clk_freq = 25 generate
    clkgen_25: entity work.clk_25_25_125p_125n_75_100
    port map(
      inclk0 => clk_25_max10,  --  25 MHz input from board
      c0 => clk_pixel,         --  25.00 MHz
      c1 => open,              -- 125.00 MHz positive
      c2 => open,              -- 125.00 MHz negative
      c3 => open,              --  76.96 MHz
      c4 => open               -- 100.00 MHz
    );
    end generate;

    G_83m_clk: if C_clk_freq = 77 generate
    clkgen_83: entity work.clk_25_25_125p_125n_75_100
    port map(
      inclk0 => clk_25_max10,  --  25 MHz input from board
      c0 => clk_pixel,         --  25.00 MHz
      c1 => open,              -- 125.00 MHz positive
      c2 => open,              -- 125.00 MHz negative
      c3 => clk,               --  76.96 MHz
      c4 => open               -- 100.00 MHz
    );
    end generate;

    G_100m_clk: if C_clk_freq = 100 generate
    clkgen_100: entity work.clk_25_25_125p_125n_75_100
    port map(
      inclk0 => clk_25_max10,  --  25 MHz input from board
      c0 => clk_pixel,         --  25.00 MHz
      c1 => open,              -- 125.00 MHz positive
      c2 => open,              -- 125.00 MHz negative
      c3 => open,              --  76.96 MHz
      c4 => clk                -- 100.00 MHz
    );
    end generate;

    -- generic XRAM glue
    glue_xram: entity work.glue_xram
    generic map (
      C_arch => C_arch,
      C_clk_freq => C_clk_freq,
      C_bram_size => C_bram_size,
      C_regfile_synchronous_read => C_regfile_synchronous_read,
      C_mult_enable => C_mult_enable,
      C_bram_const_init => C_bram_const_init,
      C_boot_write_protect => C_boot_write_protect,
      C_icache_size => C_icache_size,
      C_dcache_size => C_dcache_size,
      C_cached_addr_bits => C_cached_addr_bits,
      C_xdma => C_xboot_rom,
      C_xram_base => C_xram_base,
      C_sram => C_sram,
      C_sram_refresh => C_sram_refresh,
      C_sram_wait_cycles => C_sram_wait_cycles,
      C_sram_pipelined_read => C_sram_pipelined_read,
      C_acram => C_acram,
      C_acram_wait_cycles => C_acram_wait_cycles,
      C_sio => C_sio,
      C_timer => C_timer,
      C_gpio => C_gpio,
      C_simple_in => C_simple_in,
      C_simple_out => C_simple_out,
      -- vga simple bitmap
      C_dvid_ddr => C_dvid_ddr,
      C_vgahdmi => C_vgahdmi,
      C_vgahdmi_mode => C_video_mode,
      C_vgahdmi_cache_size => C_vgahdmi_cache_size,
      C_vgahdmi_fifo_data_width => C_vgahdmi_fifo_data_width,
      C_debug => C_debug
    )
    port map (
      clk => clk,
      clk_pixel => clk_pixel,
      --clk_pixel_shift => clk_pixel_shift,
      reset => S_reset,
      xdma_addr => xdma_addr, xdma_strobe => xdma_strobe,
      xdma_write => '1', xdma_byte_sel => "1111",
      xdma_data_in => xdma_data_in, xdma_data_ready => xdma_data_ready,
      sio_txd(0) => uart_tx, sio_rxd(0) => uart_rx, sio_break(0) => S_uart_break,
      spi_sck => open, spi_ss => open, spi_mosi => open, spi_miso => "",
      acram_en => ram_en,
      acram_addr(29 downto 2) => ram_address(29 downto 2),
      acram_byte_we(3 downto 0) => ram_byte_we(3 downto 0),
      acram_data_rd(31 downto 0) => ram_data_read(31 downto 0),
      acram_data_wr(31 downto 0) => ram_data_write(31 downto 0),
      acram_ready => ram_ready,
      sram_a => sram_a, sram_d => sram_d, sram_wel => sram_wel,
      sram_lbl => sram_lbl, sram_ubl => sram_ubl,
      -- ***** VGA *****
      vga_hsync => S_vga_hsync,
      vga_vsync => S_vga_vsync,
      vga_blank => S_vga_blank,
      vga_r => hdmi_tx_d(23 downto 16),
      vga_g => hdmi_tx_d(15 downto 8),
      vga_b => hdmi_tx_d(7 downto 0),
      -- ***** DVI *****
      --dvi_r => S_hdmi_pd2, dvi_g => S_hdmi_pd1, dvi_b => S_hdmi_pd0,
      gpio => open,
      simple_out(4 downto 0) => user_led,
      simple_out(31 downto 5) => open,
      simple_in(3 downto 0) => user_pb,
      simple_in(8 downto 4) => user_dipsw,
      simple_in(31 downto 9) => (others => '0')
    );
    hdmi_tx_clk <= clk_pixel;
    hdmi_tx_hs <= S_vga_hsync;
    hdmi_tx_vs <= S_vga_vsync;
    hdmi_tx_de <= not S_vga_blank;

    G_acram: if C_acram generate
    acram_emulation: entity work.acram_emu
    generic map
    (
      C_addr_width => 8 + ceil_log2(C_xram_emu_kb)
    )
    port map
    (
      clk => clk,
      acram_a => ram_address(9 + ceil_log2(C_xram_emu_kb) downto 2),
      acram_d_wr => ram_data_write,
      acram_d_rd => ram_data_read,
      acram_byte_we => ram_byte_we,
      acram_en => ram_en
    );
    end generate;

    G_sram: if C_sram generate
    sram_emulation: entity work.sram_emu
    generic map
    (
      C_addr_width => 9 + ceil_log2(C_xram_emu_kb)
    )
    port map
    (
      clk => clk,
      sram_a => sram_a(8 + ceil_log2(C_xram_emu_kb) downto 0),
      sram_d => sram_d, sram_wel => sram_wel,
      sram_lbl => sram_lbl, sram_ubl => sram_ubl
    );
    end generate;

    G_blinky: if true generate
      process(clk)
      begin
        if rising_edge(clk) then
          R_blinky <= R_blinky+1;
        end if;
      end process;
      -- p1(7) <= not R_blinky(R_blinky'high); -- RED LED connected to VCC
    end generate;

    -- generic "differential" output buffering for HDMI clock and video
    --hdmi_output1: entity work.hdmi_out
    --  port map
    --  (
    --    tmds_in_rgb    => tmds_rgb,
    --    tmds_out_rgb_p => hdmi_dp,   -- D2+ red  D1+ green  D0+ blue
    --    tmds_out_rgb_n => hdmi_dn,   -- D2- red  D1- green  D0+ blue
    --    tmds_in_clk    => tmds_clk,
    --    tmds_out_clk_p => hdmi_clkp, -- CLK+ clock
    --    tmds_out_clk_n => hdmi_clkn  -- CLK- clock
    --  );

    -- true differential, vendor-specific
    -- tx_in <= S_HDMI_PD2 & S_HDMI_PD1 & S_HDMI_PD0; -- this would be normal bit order, but
    -- generic serializer follows vendor specific serializer style
    --tx_in <=  S_HDMI_PD2(0) & S_HDMI_PD2(1) & S_HDMI_PD2(2) & S_HDMI_PD2(3) & S_HDMI_PD2(4) & S_HDMI_PD2(5) & S_HDMI_PD2(6) & S_HDMI_PD2(7) & S_HDMI_PD2(8) & S_HDMI_PD2(9) &
    --          S_HDMI_PD1(0) & S_HDMI_PD1(1) & S_HDMI_PD1(2) & S_HDMI_PD1(3) & S_HDMI_PD1(4) & S_HDMI_PD1(5) & S_HDMI_PD1(6) & S_HDMI_PD1(7) & S_HDMI_PD1(8) & S_HDMI_PD1(9) &
    --          S_HDMI_PD0(0) & S_HDMI_PD0(1) & S_HDMI_PD0(2) & S_HDMI_PD0(3) & S_HDMI_PD0(4) & S_HDMI_PD0(5) & S_HDMI_PD0(6) & S_HDMI_PD0(7) & S_HDMI_PD0(8) & S_HDMI_PD0(9);

    --vendorspec_serializer_inst: entity work.serializer
    --PORT MAP
    --(
    --    tx_in => tx_in,
    --    tx_inclock => CLK_PIXEL_SHIFT, -- NOTE: vendor-specific serializer needs CLK_PIXEL x5
    --    tx_syncclock => CLK_PIXEL,
    --    tx_out => tmds_d(2 downto 0)
    --);
    --hdmi_clk <= CLK_PIXEL;
    --hdmi_d   <= tmds_d(2 downto 0);

    -- this module must be present in order for bitstream to load
    -- from onchip flash
    G_altera_dual_config: if C_altera_dual_config generate
    vendorspec_dual_config: entity work.dual_config
    port map
    (
      avmm_rcv_address => "000",         -- avalon.address
      avmm_rcv_read => '0',              --       .read
      avmm_rcv_writedata => x"00000000", --       .writedata
      avmm_rcv_write => '0',             --       .write
      avmm_rcv_readdata => open,         --       .readdata
      clk => clk_pixel,                  --    clk.clk 25.02MHz
      nreset => '1'                      -- nreset.reset_n
    );
    end generate;

    -- preload the f32c bootloader and reset CPU
    -- preloads initially at startup and during each reset of the CPU
    G_xboot_rom: if C_xboot_rom generate
      boot_preload: entity work.boot_preloader
      generic map
      (
	-- ROM data bits
	C_rom_data_bits => C_boot_rom_data_bits, -- bits in the ROM
	-- ROM size in addr bits
	-- SoC configuration options
	C_boot_addr_bits => 8 -- 8: 256x4-byte = 1K bootloader size
      )
      port map
      (
        clk => clk,
        reset_in => S_uart_break, -- input reset rising edge (from serial break) starts DMA preload
        reset_out => S_reset, -- S_reset, 1 during DMA preload (holds CPU in reset state)
        rom_reset => S_rom_reset,
        rom_next_data => S_rom_next_data,
        rom_data => S_rom_data,
        rom_valid => S_rom_valid,
        addr => xdma_addr(9 downto 2), -- must fit bootloader size 1K 10-bit byte address
        data => xdma_data_in, -- comes from register - last read data will stay on the bus
        strobe => xdma_strobe, -- use strobe as strobe and as write signal
        ready => xdma_data_ready -- response from RAM arbiter (write completed)
      );
      bootrom_emu: entity work.bootrom_emu
      generic map
      (
        C_content => boot_sio_mi32el,
        C_data_bits => C_boot_rom_data_bits
      )
      port map
      (
        clk => clk,
        reset => S_rom_reset,
        next_data => S_rom_next_data,
        data => S_rom_data,
        valid => S_rom_valid
      );
    end generate;

    G_i2c_sender: if true generate
    i2c_send: entity work.i2c_sender
      port map
      (
        clk => clk_pixel,
        resend => S_reset,
        sioc => hdmi_scl,
        siod => hdmi_sda
      );
    end generate;

end Behavioral;
