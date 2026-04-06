-- Library section to let VHDL know what types / digital logic we use
-- Like JAVA import statements
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ADC_Peripheral is
    port (
        clk      : in  std_logic;
        -- Active-low reset
        resetn   : in  std_logic;

        -- SCOMP I/O interface
        io_addr  : in  std_logic_vector(10 downto 0); -- I/O Address
        io_data  : in  std_logic_vector(15 downto 0); -- 16bit value SCOMP writes to peripheral
        io_write : in  std_logic; -- Comms to do write operation
        io_read  : in  std_logic; -- Comms to do read operation
        io_q     : out std_logic_vector(15 downto 0); -- 16bit value peripheral returns on read

        -- Actual ADC pins
        adc_sclk : out std_logic; --SPI clock sent to the ADC
        adc_conv : out std_logic; -- conversion start control signal
        adc_mosi : out std_logic; -- data sent from peripheral to ADC
        adc_miso : in  std_logic -- data sent from ADC to peripheral
    );
end entity ADC_Peripheral;

architecture rtl of ADC_Peripheral is

    -- Register addresses we determined from register map
    constant ADDR_ADC_CTRL   : std_logic_vector(10 downto 0) := "00011000000"; -- 0xC0, control
    constant ADDR_ADC_STATUS : std_logic_vector(10 downto 0) := "00011000001"; -- 0xC1, status
    constant ADDR_ADC_DATA   : std_logic_vector(10 downto 0) := "00011000010"; -- 0xC2, ADC data
    -- ADC_CHANNEL stores the currently selected channel for the next conversion
    constant ADDR_ADC_CHANNEL  : std_logic_vector(10 downto 0) := "00011000011"; -- 0xC3

    -- Internal storage elements / registers for peripheral
    -- channel_reg stores the current ADC channel selected
    signal channel_reg      : std_logic_vector(2 downto 0) := (others => '0');
    -- data_reg stores the most recent conversion result
    signal data_reg         : std_logic_vector(11 downto 0) := (others => '0');
    -- ready_reg is the flag to let user know new data is available to pull
    signal ready_reg        : std_logic := '0';

    -- start_pulse is a temp one-clock signal to tell ADC ctrller when to convert
    signal start_pulse      : std_logic := '0';

    -- ADC controller outputs
    signal adc_busy         : std_logic; -- if ADC controller is currently busy converting / working
    signal adc_rx_data      : std_logic_vector(11 downto 0); -- the 12bit conversion from the ADC controller

    -- busy_d stores the previous clock's cycle value for adc_busy
    -- detects whenever adc_busy goes from 1-0 to show conversion finishes
    signal busy_d           : std_logic := '0';

begin

    -- Instantiate the provided ADC controller to use
    U_ADC_CTRL : entity work.LTC2308_ctrl
        -- The DE10 clock is too fast, so we divide the clock
        -- The controller counts cycles and toggles SPI to slow down
        generic map (
            CLK_DIV => 1 -- How fast to generate the SPI clock
        )
        -- Port names aligning with the signals in peripheral
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

    -- Process is sequential based on clk or resetn
    process(clk, resetn)
    begin
        -- reset everything to 0
        if resetn = '0' then
            channel_reg      <= (others => '0');
            data_reg         <= (others => '0');
            ready_reg        <= '0';
            start_pulse      <= '0';
            busy_d           <= '0';

        -- On every rising clock edge run behavior as intended
        elsif rising_edge(clk) then
            -- start begins low every clock and high when we want to convert
            start_pulse <= '0';

            -- save previous busy for falling edge detection
            busy_d <= adc_busy;

            -- Shows previously ADC was busy, if now its not then ADC converted 
            if (busy_d = '1' and adc_busy = '0') then
                data_reg         <= adc_rx_data; -- New ADC data stored
                ready_reg        <= '1'; -- flag to show ready
            end if;

            -- Handle writes to ADC_CTRL
            --
            -- Register bit mapping:
            -- io_data(1)          = clear_ready
            -- io_data(0)          = start
            ----------------------------------------------------------------
            if io_write = '1' and io_addr = ADDR_ADC_CTRL then

                if io_data(1) = '1' then
                    ready_reg <= '0'; -- Read the current data
                end if;

                if io_data(0) = '1' and adc_busy = '0' then
                    start_pulse <= '1'; -- Start the cycle
                end if;
            end if;

            if io_write = '1' and io_addr = ADDR_ADC_CHANNEL then
                channel_reg <= io_data(4 downto 2);
            end if;
        end if;
    end process;

    -- Peripheral responds to any signal used inside
    process(all)
    begin
        -- Initialize to 0
        io_q <= (others => '0');

        -- SCOMP performs a read
        if io_read = '1' then
            case io_addr is
                when ADDR_ADC_STATUS =>
                    -- bit1 = busy, bit0 = new data ready
                    io_q(1) <= adc_busy;
                    io_q(0) <= ready_reg;

                -- SCOMP reads register and returns 12bit ADC data
                when ADDR_ADC_DATA =>
                    io_q(11 downto 0) <= data_reg;

                -- SCOMP reads registers and returns channel currently selected
                when ADDR_ADC_CHANNEL =>
                    io_q(4 downto 2) <= channel_reg;

                when others =>
                    io_q <= (others => '0');
            end case;
        end if;
    end process;

end architecture rtl;
