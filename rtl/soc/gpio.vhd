-- EMARD GPIO with interrupts
-- LICENSE=New BSD License

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

entity gpio is
    generic (
        C_addr_bits: integer := 3; -- don't touch: number of address bits for the registers
	C_bits: integer range 2 to 32 := 32  -- number of gpio bits (pins)
    );
    port (
	ce, clk: in std_logic;
	bus_write: in std_logic;
	addr: in std_logic_vector(C_addr_bits-1 downto 0); -- address max 8 registers of 32-bit
	byte_sel: in std_logic_vector(3 downto 0);
	bus_in: in std_logic_vector(31 downto 0);
	bus_out: out std_logic_vector(31 downto 0);
	gpio_irq: out std_logic; -- interrupt request line (active level high)
	gpio_phys: inout std_logic_vector(C_bits-1 downto 0) -- pyhsical gpio pins
    );
end gpio;

architecture arch of gpio is
    constant C_registers: integer := 6; -- total number of gpio registers

    -- normal registers
    -- type gpio_reg_type  is std_logic_vector(C_bits-1 downto 0);
    type gpio_regs_type is array (C_registers-1 downto 0) of std_logic_vector(C_bits-1 downto 0);
    signal R: gpio_regs_type; -- register access from mmapped I/O  R: active register, Rtmp temporary

    -- *** REGISTERS ***
    -- named constants for gpio registers
    -- this improves code readability
    -- and provides flexible register (re)numbering
    constant C_output:     integer   := 0; -- output value
    constant C_direction:  integer   := 1; -- direction 0=input 1=output
    constant C_rising_if:  integer   := 2; -- rising edge interrupt flag
    constant C_rising_ie:  integer   := 3; -- rising edge interrupt enable
    constant C_falling_if: integer   := 4; -- falling edge interrupt flag
    constant C_falling_ie: integer   := 5; -- falling edge interrupt enable
    constant C_input:      integer   := 0; -- input value (overlay at output register value) 

    -- edge detection related registers
    constant C_edge_sync_depth: integer := 3; -- number of shift register stages (default 3) for icp clock synchronization
    type T_edge_sync_shift is array (0 to C_edge_sync_depth-1) of std_logic_vector(C_bits-1 downto 0); -- edge detect synchronizer type
    signal R_edge_sync_shift: T_edge_sync_shift;
    signal R_rising_edge, R_falling_edge: std_logic_vector(C_bits-1 downto 0);

begin
    -- CPU core reads registers
    with addr select
      bus_out <= 
        ext(gpio_phys, 32)
          when conv_std_logic_vector(C_input, C_addr_bits),
        ext(R(conv_integer(addr)),32)
          when others;

    -- CPU core writes registers
    -- and edge interrupt flags handling
    -- interrupt flags can be written only 0, writing 1 is nop -> use and
    writereg_intrflags: for i in 0 to C_bits/8-1 generate
      process(clk)
      begin
        if rising_edge(clk) then
          if byte_sel(i) = '1' then
            if ce = '1' and bus_write = '1' then
              if conv_integer(addr) = C_rising_if 
              or conv_integer(addr) = C_falling_if
              then
                R(conv_integer(addr))(8*i+7 downto 8*i) <= -- only can clear intr. flag, never set
                R(conv_integer(addr))(8*i+7 downto 8*i) and bus_in(8*i+7 downto 8*i);
              else
                R(conv_integer(addr))(8*i+7 downto 8*i) <=  bus_in(8*i+7 downto 8*i);
              end if;
            else
              if conv_integer(addr) = C_rising_if then
                R(conv_integer(addr))(8*i+7 downto 8*i) <= -- only can set intr. flag, never clear
                R(conv_integer(addr))(8*i+7 downto 8*i) or R_rising_edge(8*i+7 downto 8*i);
              end if;
              if conv_integer(addr) = C_falling_if then
                R(conv_integer(addr))(8*i+7 downto 8*i) <= -- only can set intr. flag, never clear
                R(conv_integer(addr))(8*i+7 downto 8*i) or R_falling_edge(8*i+7 downto 8*i);
              end if;
            end if;
          end if;
        end if;
      end process;
    end generate;
    
    -- physical output to pins with 3-state handling
    phys_io: for i in 0 to C_bits-1 generate
      gpio_phys(i) <= R(C_output)(i) when R(C_direction)(i) = '1' else 'Z';
    end generate;

    -- join all interrupt request bits into one bit
    gpio_irq <= '1' when 
                    (  ( R(C_rising_ie)  and R(C_rising_if)  )
                    or ( R(C_falling_ie) and R(C_falling_if) )
                    ) /= x"00000000" else '0';

    -- warning - asynchronous external icp rising edge
    -- should be passed to async->sync filter to match
    -- the input clock and then be processed.
    -- here is theory and schematics about 3-stage shift register
    -- https://www.doulos.com/knowhow/fpga/synchronisation/
    -- here is vhdl implementation of the 3-stage shift register
    -- http://www.bitweenie.com/listings/vhdl-shift-register/
    -- edge detect synchronizer (3-stage shift register)
    process(clk)
    begin
      if rising_edge(clk) then
        R_edge_sync_shift(0) <= gpio_phys;
        R_edge_sync_shift(1) <= R_edge_sync_shift(0);
        R_edge_sync_shift(2) <= R_edge_sync_shift(1);
      end if;
    end process;

    -- difference in 2 last bits of the shift register detect synchronous rising/falling edge
    -- rising edge when at C_edge_sync_depth-1 is 0, and one clock earlier at C_edge_sync_depth-2 is 1
    R_rising_edge <=
         (not R_edge_sync_shift(2))  -- it was 0
     and (    R_edge_sync_shift(1)); -- 1 is coming after 0
    -- falling edge similar, but other reg is not'ed
    R_falling_edge <=
         (    R_edge_sync_shift(2))  -- it was 1
     and (not R_edge_sync_shift(1)); -- 0 is coming after 1
    
end;

-- todo: level interrupts (they are rarely needed)