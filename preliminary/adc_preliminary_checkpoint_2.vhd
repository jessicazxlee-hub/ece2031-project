library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ADC_PERIPHERAL is
    generic (
        CLK_DIV         : positive := 2;
        CONV_HIGH_CLKS  : positive := 1;
        CONV_WAIT_CLKS  : positive := 80;
        ACQ_HOLD_CLKS   : positive := 4
    );
    port (
        -- SCOMP bus
        CLOCK       : in    std_logic;
        RESETN      : in    std_logic;
        IO_READ     : in    std_logic;
        IO_WRITE    : in    std_logic;
        IO_ADDR     : in    std_logic_vector(10 downto 0);
        IO_DATA     : inout std_logic_vector(15 downto 0);

        -- LTC2308 pins
        ADC_SCK     : out   std_logic;
        ADC_CONVST  : out   std_logic;
        ADC_SDI     : out   std_logic;
        ADC_SDO     : in    std_logic
    );
end entity ADC_PERIPHERAL;

architecture rtl of ADC_PERIPHERAL is

    --------------------------------------------------------------------
    -- Register map
    --------------------------------------------------------------------
    constant ADC_CTRL_ADDR    : integer := 16#0C0#; -- &HC0
    constant ADC_STATUS_ADDR  : integer := 16#0C1#; -- &HC1
    constant ADC_DATA_ADDR    : integer := 16#0C2#; -- &HC2
    constant ADC_CHANNEL_ADDR : integer := 16#0C3#; -- &HC3

    --------------------------------------------------------------------
    -- State machine
    --------------------------------------------------------------------
    type state_type is (IDLE, CONV_HIGH, CONV_WAIT, SHIFT, ACQ_HOLD, DONE);
    signal state : state_type := IDLE;

    --------------------------------------------------------------------
    -- Programmer-visible registers
    --------------------------------------------------------------------
    signal channel_reg     : std_logic_vector(2 downto 0) := "000";
    signal ready_reg       : std_logic := '0';
    signal busy_reg        : std_logic := '0';
    signal data_reg        : std_logic_vector(11 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- Internal flags
    --------------------------------------------------------------------
    signal start_req       : std_logic := '0';
    signal clear_ready_req : std_logic := '0';
    signal primed_reg      : std_logic := '0';

    --------------------------------------------------------------------
    -- Address decode
    --------------------------------------------------------------------
    signal addr_u          : integer range 0 to 2047;
    signal wr_ctrl_sel     : std_logic;
    signal wr_chan_sel     : std_logic;
    signal rd_status_sel   : std_logic;
    signal rd_data_sel     : std_logic;
    signal rd_chan_sel     : std_logic;
    signal read_hit        : std_logic;

    --------------------------------------------------------------------
    -- Read data
    --------------------------------------------------------------------
    signal read_data       : std_logic_vector(15 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- SPI/LTC2308 signals
    --------------------------------------------------------------------
    signal din6            : std_logic_vector(5 downto 0);
    signal tx_reg          : std_logic_vector(11 downto 0) := (others => '0');
    signal rx_reg          : std_logic_vector(11 downto 0) := (others => '0');
    signal sdi_reg         : std_logic := '0';
    signal sclk_int        : std_logic := '0';
    signal convst_reg      : std_logic := '0';

    signal clk_cnt         : integer range 0 to CLK_DIV - 1 := 0;
    signal conv_high_cnt   : integer range 0 to CONV_HIGH_CLKS - 1 := 0;
    signal conv_wait_cnt   : integer range 0 to CONV_WAIT_CLKS - 1 := 0;
    signal acq_hold_cnt    : integer range 0 to ACQ_HOLD_CLKS - 1 := 0;
    signal bit_cnt         : integer range 0 to 11 := 0;

    signal sclk_rise_evt   : std_logic;
    signal sclk_fall_evt   : std_logic;

begin

    --------------------------------------------------------------------
    -- External outputs
    --------------------------------------------------------------------
    ADC_SCK    <= sclk_int;
    ADC_CONVST <= convst_reg;
    ADC_SDI    <= sdi_reg;

    --------------------------------------------------------------------
    -- LTC2308 DIN command
    -- S/D=1 single-ended
    -- O/S,S1,S0 = channel_reg
    -- UNI=1 unipolar
    -- SLP=0 nap mode
    --------------------------------------------------------------------
    din6 <= '1' & channel_reg & '1' & '0';

    --------------------------------------------------------------------
    -- Address decode
    --------------------------------------------------------------------
    addr_u        <= to_integer(unsigned(IO_ADDR));

    wr_ctrl_sel   <= '1' when (IO_WRITE = '1' and addr_u = ADC_CTRL_ADDR)    else '0';
    wr_chan_sel   <= '1' when (IO_WRITE = '1' and addr_u = ADC_CHANNEL_ADDR) else '0';

    rd_status_sel <= '1' when (IO_READ  = '1' and addr_u = ADC_STATUS_ADDR)  else '0';
    rd_data_sel   <= '1' when (IO_READ  = '1' and addr_u = ADC_DATA_ADDR)    else '0';
    rd_chan_sel   <= '1' when (IO_READ  = '1' and addr_u = ADC_CHANNEL_ADDR) else '0';

    read_hit      <= rd_status_sel or rd_data_sel or rd_chan_sel;

    --------------------------------------------------------------------
    -- SCK edge flags
    --------------------------------------------------------------------
    sclk_rise_evt <= '1'
        when (state = SHIFT and clk_cnt = CLK_DIV - 1 and sclk_int = '0')
        else '0';

    sclk_fall_evt <= '1'
        when (state = SHIFT and clk_cnt = CLK_DIV - 1 and sclk_int = '1')
        else '0';

    --------------------------------------------------------------------
    -- Read mux
    --------------------------------------------------------------------
    process(ready_reg, busy_reg, data_reg, channel_reg, rd_status_sel, rd_data_sel, rd_chan_sel)
    begin
        read_data <= (others => '0');

        if rd_status_sel = '1' then
            -- bit0 = READY, bit1 = BUSY
            read_data <= (15 downto 2 => '0') & busy_reg & ready_reg;
        elsif rd_data_sel = '1' then
            -- bit11:0 = SAMPLE
            read_data <= (15 downto 12 => '0') & data_reg;
        elsif rd_chan_sel = '1' then
            -- bits 4:2 = CHANNEL
            read_data <= (15 downto 5 => '0') & channel_reg & "00";
        end if;
    end process;

    --------------------------------------------------------------------
    -- Drive SCOMP IO bus only during matching reads
    --------------------------------------------------------------------
    IO_DATA <= read_data when read_hit = '1' else (others => 'Z');

    --------------------------------------------------------------------
    -- 0) Bus interface
    --------------------------------------------------------------------
    process(CLOCK, RESETN)
    begin
        if RESETN = '0' then
            channel_reg     <= "000";
            start_req       <= '0';
            clear_ready_req <= '0';

        elsif rising_edge(CLOCK) then
            clear_ready_req <= '0';

            if state = CONV_HIGH then
                start_req <= '0';
            end if;

            if wr_ctrl_sel = '1' then
                if IO_DATA(0) = '1' then
                    start_req <= '1';
                end if;

                if IO_DATA(1) = '1' then
                    clear_ready_req <= '1';
                end if;
            end if;

            if wr_chan_sel = '1' then
                channel_reg <= IO_DATA(4 downto 2);
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 1) Control process
    --------------------------------------------------------------------
    process(CLOCK, RESETN)
    begin
        if RESETN = '0' then
            state         <= IDLE;
            ready_reg     <= '0';
            busy_reg      <= '0';
            convst_reg    <= '0';
            conv_high_cnt <= 0;
            conv_wait_cnt <= 0;
            acq_hold_cnt  <= 0;
            bit_cnt       <= 0;

        elsif rising_edge(CLOCK) then

            if clear_ready_req = '1' then
                ready_reg <= '0';
            end if;

            case state is
                when IDLE =>
                    busy_reg   <= '0';
                    convst_reg <= '0';

                    if start_req = '1' then
                        busy_reg      <= '1';
                        convst_reg    <= '1';
                        conv_high_cnt <= CONV_HIGH_CLKS - 1;
                        state         <= CONV_HIGH;
                    end if;

                when CONV_HIGH =>
                    busy_reg   <= '1';
                    convst_reg <= '1';

                    if conv_high_cnt = 0 then
                        convst_reg    <= '0';
                        conv_wait_cnt <= CONV_WAIT_CLKS - 1;
                        state         <= CONV_WAIT;
                    else
                        conv_high_cnt <= conv_high_cnt - 1;
                    end if;

                when CONV_WAIT =>
                    busy_reg   <= '1';
                    convst_reg <= '0';

                    if conv_wait_cnt = 0 then
                        bit_cnt <= 0;
                        state   <= SHIFT;
                    else
                        conv_wait_cnt <= conv_wait_cnt - 1;
                    end if;

                when SHIFT =>
                    busy_reg   <= '1';
                    convst_reg <= '0';

                    if sclk_rise_evt = '1' then
                        if bit_cnt = 11 then
                            acq_hold_cnt <= ACQ_HOLD_CLKS - 1;
                            state        <= ACQ_HOLD;
                        else
                            bit_cnt <= bit_cnt + 1;
                        end if;
                    end if;

                when ACQ_HOLD =>
                    busy_reg   <= '1';
                    convst_reg <= '0';

                    if acq_hold_cnt = 0 then
                        if primed_reg = '1' then
                            ready_reg <= '1';
                        end if;
                        state <= DONE;
                    else
                        acq_hold_cnt <= acq_hold_cnt - 1;
                    end if;

                when DONE =>
                    busy_reg   <= '0';
                    convst_reg <= '0';
                    state      <= IDLE;
            end case;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 2) SCK generation
    --------------------------------------------------------------------
    process(CLOCK, RESETN)
    begin
        if RESETN = '0' then
            clk_cnt  <= 0;
            sclk_int <= '0';

        elsif rising_edge(CLOCK) then
            if state = SHIFT then
                if clk_cnt = CLK_DIV - 1 then
                    clk_cnt  <= 0;
                    sclk_int <= not sclk_int;
                else
                    clk_cnt <= clk_cnt + 1;
                end if;
            else
                clk_cnt  <= 0;
                sclk_int <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 3) SPI datapath
    --------------------------------------------------------------------
    process(CLOCK, RESETN)
    begin
        if RESETN = '0' then
            tx_reg     <= (others => '0');
            rx_reg     <= (others => '0');
            data_reg   <= (others => '0');
            sdi_reg    <= '0';
            primed_reg <= '0';

        elsif rising_edge(CLOCK) then
            case state is
                when IDLE =>
                    if start_req = '1' then
                        tx_reg  <= din6 & "000000";
                        rx_reg  <= (others => '0');
                        sdi_reg <= din6(5);
                    end if;

                when SHIFT =>
                    if sclk_fall_evt = '1' then
                        tx_reg  <= tx_reg(10 downto 0) & '0';
                        sdi_reg <= tx_reg(10);
                    end if;

                    if sclk_rise_evt = '1' then
                        rx_reg <= rx_reg(10 downto 0) & ADC_SDO;
                    end if;

                when ACQ_HOLD =>
                    data_reg <= rx_reg;
                    if primed_reg = '0' then
                        primed_reg <= '1';
                    end if;

                when others =>
                    null;
            end case;
        end if;
    end process;

end architecture rtl;