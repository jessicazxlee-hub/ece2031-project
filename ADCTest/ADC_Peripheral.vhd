library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ADC_Peripheral is
    port (
        clk      : in  std_logic;
        resetn   : in  std_logic;

        -- SCOMP I/O interface
        io_addr  : in  std_logic_vector(10 downto 0);
        io_data  : in  std_logic_vector(15 downto 0);
        io_write : in  std_logic;
        io_read  : in  std_logic;
        io_q     : out std_logic_vector(15 downto 0);

        -- Physical ADC pins
        adc_sclk : out std_logic;
        adc_conv : out std_logic;
        adc_mosi : out std_logic;
        adc_miso : in  std_logic
    );
end entity ADC_Peripheral;

architecture rtl of ADC_Peripheral is

    -- ========= Address constants =========
    constant ADDR_ADC_CTRL   : std_logic_vector(10 downto 0) := "00011000000"; -- 0xC0
    constant ADDR_ADC_STATUS : std_logic_vector(10 downto 0) := "00011000001"; -- 0xC1
    constant ADDR_ADC_DATA   : std_logic_vector(10 downto 0) := "00011000010"; -- 0xC2
    constant ADDR_CHAN_INFO  : std_logic_vector(10 downto 0) := "00011000011"; -- 0xC3

    -- ========= Internal registers =========
    signal channel_reg      : std_logic_vector(2 downto 0) := (others => '0');
    signal last_channel_reg : std_logic_vector(2 downto 0) := (others => '0');
    signal data_reg         : std_logic_vector(11 downto 0) := (others => '0');
    signal ready_reg        : std_logic := '0';

    -- one-clock pulse into ADC controller
    signal start_pulse      : std_logic := '0';

    -- ADC controller outputs
    signal adc_busy         : std_logic;
    signal adc_rx_data      : std_logic_vector(11 downto 0);

    -- used to detect busy falling edge
    signal busy_d           : std_logic := '0';

begin

    --------------------------------------------------------------------
    -- Instantiate your existing ADC controller
    --------------------------------------------------------------------
    U_ADC_CTRL : entity work.LTC2308_ctrl
        generic map (
            CLK_DIV => 1
        )
        port map (
            clk     => clk,
            nrst    => resetn,
            start   => start_pulse,
            rx_data => adc_rx_data,
            busy    => adc_busy,
            sclk    => adc_sclk,
            conv    => adc_conv,
            mosi    => adc_mosi,
            miso    => adc_miso
        );

    --------------------------------------------------------------------
    -- Write/control process
    --------------------------------------------------------------------
    process(clk, resetn)
    begin
        if resetn = '0' then
            channel_reg      <= (others => '0');
            last_channel_reg <= (others => '0');
            data_reg         <= (others => '0');
            ready_reg        <= '0';
            start_pulse      <= '0';
            busy_d           <= '0';

        elsif rising_edge(clk) then
            -- default: pulse is only high for one clock
            start_pulse <= '0';

            -- save previous busy for edge detect
            busy_d <= adc_busy;

            ----------------------------------------------------------------
            -- detect conversion complete
            -- busy: 1 -> 0 means new data is ready
            ----------------------------------------------------------------
            if (busy_d = '1' and adc_busy = '0') then
                data_reg         <= adc_rx_data;
                ready_reg        <= '1';
                last_channel_reg <= channel_reg;
            end if;

            -- Handle writes to ADC_CTRL
            --
            -- Register bit mapping:
            -- io_data(4 downto 2) = channel
            -- io_data(1)          = clear_ready
            -- io_data(0)          = start
            ----------------------------------------------------------------
            if io_write = '1' and io_addr = ADDR_ADC_CTRL then
                channel_reg <= io_data(4 downto 2);

                if io_data(1) = '1' then
                    ready_reg <= '0';
                end if;

                if io_data(0) = '1' and adc_busy = '0' then
                    start_pulse <= '1';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Read mux
    --------------------------------------------------------------------
    process(all)
    begin
        io_q <= (others => '0');

        if io_read = '1' then
            case io_addr is
                when ADDR_ADC_STATUS =>
                    -- bit1 = busy, bit0 = ready
                    io_q(1) <= adc_busy;
                    io_q(0) <= ready_reg;

                when ADDR_ADC_DATA =>
                    io_q(11 downto 0) <= data_reg;

                when ADDR_CHAN_INFO =>
                    io_q(2 downto 0) <= last_channel_reg;

                when others =>
                    io_q <= (others => '0');
            end case;
        end if;
    end process;

end architecture rtl;
