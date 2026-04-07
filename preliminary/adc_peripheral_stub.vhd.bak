library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ADC_PERIPHERAL_STUB.VHD
--
-- Checkpoint version of an SCOMP peripheral that exposes a simple
-- register-based ADC interface. This version includes a working FSM and
-- a deterministic stub sample generator so the peripheral can be integrated
-- and tested before the real ADC controller is fully connected.
--
-- Programmer-visible register map:
--   0xC0  ADC_CTRL     (write)
--         bit 0 = START
--         bit 1 = CLEAR_READY
--   0xC1  ADC_STATUS   (read)
--         bit 0 = READY
--         bit 1 = BUSY
--   0xC2  ADC_DATA     (read)
--         bits 11:0 = latest 12-bit sample, zero-extended to 16 bits
--   0xC3  ADC_CHANNEL  (read/write)
--         bits 2:0 = channel selection
--
-- Notes:
-- * The real SPI-facing ADC controller can later replace the stub generator.
-- * One LED output is provided so the READY flag can be observed in hardware.

entity ADC_PERIPHERAL_STUB is
    generic (
        CONV_CYCLES : natural := 500000  -- simulated conversion latency
    );
    port (
        CLOCK      : in    std_logic;
        RESETN     : in    std_logic;
        IO_ADDR    : in    std_logic_vector(10 downto 0);
        IO_READ    : in    std_logic;
        IO_WRITE   : in    std_logic;
        IO_DATA    : inout std_logic_vector(15 downto 0);

        -- Optional observation output for checkpoint demos
        READY_LED  : out   std_logic;

        -- Reserved SPI-facing ports for later integration
        ADC_SCLK   : out   std_logic;
        ADC_CONV   : out   std_logic;
        ADC_MOSI   : out   std_logic;
        ADC_MISO   : in    std_logic
    );
end entity ADC_PERIPHERAL_STUB;

architecture rtl of ADC_PERIPHERAL_STUB is

    constant ADDR_CTRL    : std_logic_vector(10 downto 0) := "00011000000"; -- 0x0C0
    constant ADDR_STATUS  : std_logic_vector(10 downto 0) := "00011000001"; -- 0x0C1
    constant ADDR_DATA    : std_logic_vector(10 downto 0) := "00011000010"; -- 0x0C2
    constant ADDR_CHANNEL : std_logic_vector(10 downto 0) := "00011000011"; -- 0x0C3

    type state_type is (IDLE, START_CONVERSION, WAIT_CONVERSION, LATCH_RESULT);
    signal state : state_type := IDLE;

    signal ready_flag    : std_logic := '0';
    signal busy_flag     : std_logic := '0';
    signal channel_reg   : std_logic_vector(2 downto 0) := (others => '0');
    signal data_reg      : std_logic_vector(15 downto 0) := (others => '0');

    signal io_data_out   : std_logic_vector(15 downto 0) := (others => '0');
    signal io_drive_en   : std_logic := '0';

    signal start_req     : std_logic := '0';
    signal conv_counter  : natural range 0 to CONV_CYCLES := 0;

    -- Free-running counter used to generate deterministic fake samples.
    signal sample_seed   : unsigned(11 downto 0) := (others => '0');
    signal sample_next   : unsigned(11 downto 0) := (others => '0');

begin

    --------------------------------------------------------------------
    -- Bidirectional SCOMP data bus
    --------------------------------------------------------------------
    IO_DATA <= io_data_out when io_drive_en = '1' else (others => 'Z');

    --------------------------------------------------------------------
    -- Readback mux
    --------------------------------------------------------------------
    process(IO_ADDR, IO_READ, ready_flag, busy_flag, data_reg, channel_reg)
    begin
        io_drive_en <= '0';
        io_data_out <= (others => '0');

        if IO_READ = '1' then
            case IO_ADDR is
                when ADDR_STATUS =>
                    io_drive_en <= '1';
                    io_data_out(0) <= ready_flag;
                    io_data_out(1) <= busy_flag;

                when ADDR_DATA =>
                    io_drive_en <= '1';
                    io_data_out <= data_reg;

                when ADDR_CHANNEL =>
                    io_drive_en <= '1';
                    io_data_out(2 downto 0) <= channel_reg;

                when others =>
                    null;
            end case;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Write handling and main peripheral FSM
    --------------------------------------------------------------------
    process(CLOCK, RESETN)
        variable mixed_sample : unsigned(11 downto 0);
    begin
        if RESETN = '0' then
            state        <= IDLE;
            ready_flag   <= '0';
            busy_flag    <= '0';
            channel_reg  <= (others => '0');
            data_reg     <= (others => '0');
            start_req    <= '0';
            conv_counter <= 0;
            sample_seed  <= (others => '0');
            sample_next  <= (others => '0');

        elsif rising_edge(CLOCK) then
            -- default: request is a one-cycle pulse into the FSM
            start_req <= '0';

            -- free-running seed so consecutive conversions do not repeat
            sample_seed <= sample_seed + 1;

            -- register writes
            if IO_WRITE = '1' then
                case IO_ADDR is
                    when ADDR_CTRL =>
                        if IO_DATA(1) = '1' then
                            ready_flag <= '0';
                        end if;

                        if (IO_DATA(0) = '1') and (busy_flag = '0') then
                            start_req <= '1';
                        end if;

                    when ADDR_CHANNEL =>
                        if busy_flag = '0' then
                            channel_reg <= IO_DATA(2 downto 0);
                        end if;

                    when others =>
                        null;
                end case;
            end if;

            -- state machine
            case state is
                when IDLE =>
                    busy_flag    <= '0';
                    conv_counter <= 0;

                    if start_req = '1' then
                        ready_flag <= '0';
                        busy_flag  <= '1';
                        state      <= START_CONVERSION;
                    end if;

                when START_CONVERSION =>
                    -- Construct a predictable 12-bit sample pattern that changes
                    -- with time and with the selected channel. This is only a stub.
                    mixed_sample := sample_seed xor
                                    resize(unsigned(channel_reg & channel_reg & channel_reg & channel_reg), 12) xor
                                    to_unsigned(16#155#, 12);
                    sample_next  <= mixed_sample;
                    conv_counter <= CONV_CYCLES;
                    state        <= WAIT_CONVERSION;

                when WAIT_CONVERSION =>
                    if conv_counter = 0 then
                        state <= LATCH_RESULT;
                    else
                        conv_counter <= conv_counter - 1;
                    end if;

                when LATCH_RESULT =>
                    data_reg(11 downto 0)  <= std_logic_vector(sample_next);
                    data_reg(15 downto 12) <= (others => '0');
                    ready_flag             <= '1';
                    busy_flag              <= '0';
                    state                  <= IDLE;

            end case;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Checkpoint/demo outputs
    --------------------------------------------------------------------
    READY_LED <= ready_flag;

    -- These outputs are placeholders in the stub version.
    ADC_SCLK <= '0';
    ADC_CONV <= '0';
    ADC_MOSI <= '0';

end architecture rtl;
