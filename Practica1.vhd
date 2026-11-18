library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity Practica1 is
    port (
        -- Reloj de 50 MHz integrado en la tarjeta (Pin P11)
        MAX10_CLK1_50 : in std_logic;
          
        KEY : in std_logic;
        
        -- Switches de modo visual (Barra/Punto y Pelota/Burbuja)
        SW0 : in std_logic;
        SW1 : in std_logic;
        
        -- Nuevos switches para selección de eje (Prioridad: SW2 > SW3 > SW4)
        SW2 : in std_logic; -- Modo Eje X (Asignar pin en Pin Planner, ej. D12)
        SW3 : in std_logic; -- Modo Eje Y (Asignar pin en Pin Planner, ej. C12)
        SW4 : in std_logic; -- Modo Eje Z (Asignar pin en Pin Planner, ej. A12)

        -- Conexiones al acelerómetro
        GSENSOR_CS_N : out std_logic;                   -- PIN AB16
        GSENSOR_SCLK : out std_logic;                   -- PIN AB15
        GSENSOR_SDI  : inout std_logic;                 -- PIN V11
        GSENSOR_INT  : in std_logic_vector(2 downto 1); -- PIN Y14 y Y13

        LEDR : out std_logic_vector(9 downto 0)
    );
end entity Practica1;

architecture funcionamiento of Practica1 is

    component accel_spi is
        port (
            clk           : in    std_logic;
            reset         : in    std_logic;
            address       : in    std_logic;
            byteenable    : in    std_logic;
            read          : in    std_logic;
            write         : in    std_logic;
            writedata     : in    std_logic_vector(7 downto 0);
            readdata      : out   std_logic_vector(7 downto 0);
            waitrequest   : out   std_logic;
            irq           : out   std_logic;
            I2C_SDAT      : inout std_logic;
            I2C_SCLK      : out   std_logic;
            G_SENSOR_CS_N : out   std_logic;
            G_SENSOR_INT  : in    std_logic
        );
    end component;

    -- Máquina de estados ampliada para leer los 3 ejes (X, Y, Z)
    type estado_t is ( 
        ESPERA_INICIAL,
        -- Estados Eje X
        DIRECCION_X_BAJA, LEER_X_BAJA,
        DIRECCION_X_ALTA, LEER_X_ALTA,
        -- Estados Eje Y
        DIRECCION_Y_BAJA, LEER_Y_BAJA,
        DIRECCION_Y_ALTA, LEER_Y_ALTA,
        -- Estados Eje Z
        DIRECCION_Z_BAJA, LEER_Z_BAJA,
        DIRECCION_Z_ALTA, LEER_Z_ALTA
    );

    signal estado   : estado_t := ESPERA_INICIAL;
    signal contador : integer range 0 to 5000000 := 0;

    -- Señales para comunicarnos con accel_spi
    signal direccion      : std_logic;
    signal lectura        : std_logic;
    signal escritura      : std_logic;
    signal dato_escritura : std_logic_vector(7 downto 0);
    signal dato_lectura   : std_logic_vector(7 downto 0);
    signal esperar        : std_logic;

    -- Registros temporales para bytes bajos y valores completos de 16 bits con signo
    signal x_bajo : std_logic_vector(7 downto 0) := (others => '0');
    signal y_bajo : std_logic_vector(7 downto 0) := (others => '0');
    signal z_bajo : std_logic_vector(7 downto 0) := (others => '0');

    signal x : signed(15 downto 0) := (others => '0');
    signal y : signed(15 downto 0) := (others => '0');
    signal z : signed(15 downto 0) := (others => '0');

    -- Señal que almacena el eje seleccionado según la prioridad X > Y > Z
    signal eje_activo : signed(15 downto 0) := (others => '0');

    -- Valor absoluto y nivel de inclinación
    signal magnitud : integer range 0 to 32767 := 0;
    signal nivel    : integer range 0 to 4 := 0; 

begin

    controlador : accel_spi
        port map (
            clk           => MAX10_CLK1_50,
            reset         => not KEY,
            address       => direccion,
            byteenable    => '1',
            read          => lectura,
            write         => escritura,
            writedata     => dato_escritura,
            readdata      => dato_lectura,
            waitrequest   => esperar,
            irq           => open,
            I2C_SDAT      => GSENSOR_SDI,
            I2C_SCLK      => GSENSOR_SCLK,
            G_SENSOR_CS_N => GSENSOR_CS_N,
            G_SENSOR_INT  => GSENSOR_INT(1)
        );

    -- Selección de registro de dirección ('0') o datos ('1')
    direccion <= '0' when (estado = DIRECCION_X_BAJA or estado = DIRECCION_X_ALTA or
                           estado = DIRECCION_Y_BAJA or estado = DIRECCION_Y_ALTA or
                           estado = DIRECCION_Z_BAJA or estado = DIRECCION_Z_ALTA)
                 else '1';
                 
    -- Solicitud de lectura
    lectura <= '1' when (estado = LEER_X_BAJA or estado = LEER_X_ALTA or
                         estado = LEER_Y_BAJA or estado = LEER_Y_ALTA or
                         estado = LEER_Z_BAJA or estado = LEER_Z_ALTA)
               else '0';

    -- Solicitud de escritura de dirección
    escritura <= '1' when (estado = DIRECCION_X_BAJA or estado = DIRECCION_X_ALTA or
                           estado = DIRECCION_Y_BAJA or estado = DIRECCION_Y_ALTA or
                           estado = DIRECCION_Z_BAJA or estado = DIRECCION_Z_ALTA)
                 else '0';

    -- Direcciones de los registros de datos en el ADXL345
    dato_escritura <= x"32" when estado = DIRECCION_X_BAJA else -- DATAX0
                      x"33" when estado = DIRECCION_X_ALTA else -- DATAX1
                      x"34" when estado = DIRECCION_Y_BAJA else -- DATAY0
                      x"35" when estado = DIRECCION_Y_ALTA else -- DATAY1
                      x"36" when estado = DIRECCION_Z_BAJA else -- DATAZ0
                      x"37" when estado = DIRECCION_Z_ALTA else -- DATAZ1
                      x"00";

    -- Proceso secuencial de lectura continua de X, Y y Z
    process (MAX10_CLK1_50)
    begin
        if rising_edge(MAX10_CLK1_50) then
            if KEY = '0' then
                estado   <= ESPERA_INICIAL;
                contador <= 0;
                x_bajo   <= (others => '0');
                y_bajo   <= (others => '0');
                z_bajo   <= (others => '0');
                x        <= (others => '0');
                y        <= (others => '0');
                z        <= (others => '0');
            else
                case estado is
                    when ESPERA_INICIAL =>
                        if contador = 5000000 - 1 then
                            contador <= 0;
                            estado   <= DIRECCION_X_BAJA;
                        else
                            contador <= contador + 1;
                        end if;

                    -- LECTURA EJE X
                    when DIRECCION_X_BAJA =>
                        if esperar = '0' then estado <= LEER_X_BAJA; end if;

                    when LEER_X_BAJA =>
                        if esperar = '0' then
                            x_bajo <= dato_lectura;
                            estado <= DIRECCION_X_ALTA;
                        end if;

                    when DIRECCION_X_ALTA =>
                        if esperar = '0' then estado <= LEER_X_ALTA; end if;

                    when LEER_X_ALTA =>
                        if esperar = '0' then
                            x      <= signed(dato_lectura & x_bajo);
                            estado <= DIRECCION_Y_BAJA; -- Pasa al eje Y
                        end if;

                    -- LECTURA EJE Y
                    when DIRECCION_Y_BAJA =>
                        if esperar = '0' then estado <= LEER_Y_BAJA; end if;

                    when LEER_Y_BAJA =>
                        if esperar = '0' then
                            y_bajo <= dato_lectura;
                            estado <= DIRECCION_Y_ALTA;
                        end if;

                    when DIRECCION_Y_ALTA =>
                        if esperar = '0' then estado <= LEER_Y_ALTA; end if;

                    when LEER_Y_ALTA =>
                        if esperar = '0' then
                            y      <= signed(dato_lectura & y_bajo);
                            estado <= DIRECCION_Z_BAJA; -- Pasa al eje Z
                        end if;

                    -- LECTURA EJE Z
                    when DIRECCION_Z_BAJA =>
                        if esperar = '0' then estado <= LEER_Z_BAJA; end if;

                    when LEER_Z_BAJA =>
                        if esperar = '0' then
                            z_bajo <= dato_lectura;
                            estado <= DIRECCION_Z_ALTA;
                        end if;

                    when DIRECCION_Z_ALTA =>
                        if esperar = '0' then estado <= LEER_Z_ALTA; end if;

                    when LEER_Z_ALTA =>
                        if esperar = '0' then
                            z      <= signed(dato_lectura & z_bajo);
                            estado <= DIRECCION_X_BAJA; -- Reinicia el ciclo en X
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- Selección del eje con orden de prioridad: X (SW2) > Y (SW3) > Z (SW4)
    eje_activo <= x when SW2 = '1' else
                  y when SW3 = '1' else
                  z when SW4 = '1' else
                  (others => '0');

    -- Cálculo de magnitud y niveles sobre el eje seleccionado
    magnitud <= abs(to_integer(eje_activo));

    nivel <= 4 when magnitud > 176 else
             3 when magnitud > 128 else
             2 when magnitud > 80  else
             1 when magnitud > 32  else
             0;

    -- Control de la tira de LEDs (se apaga si ningún switch de eje está activo)
    process (eje_activo, nivel, SW0, SW1, SW2, SW3, SW4)
    begin
        LEDR <= (others => '0');

        -- Solo muestra movimiento si al menos uno de los switches de eje está encendido
        if (SW2 = '1' or SW3 = '1' or SW4 = '1') then
            if SW0 = '1' then
                -- MODO BARRA
                LEDR(4) <= '1';
                for i in 1 to 4 loop
                    if i <= nivel then
                        if eje_activo < 0 then
                            if SW1 = '1' then
                                LEDR(4 - i) <= '1';
                            else 
                                LEDR(4 + i) <= '1';
                            end if;
                        else
                            if SW1 = '1' then
                                LEDR(4 + i) <= '1';
                            else 
                                LEDR(4 - i) <= '1';
                            end if;
                        end if;
                    end if;
                end loop;
            else
                -- MODO PUNTO
                if nivel = 0 then
                    LEDR(4) <= '1';
                elsif eje_activo < 0 then
                    if SW1 = '1' then
                        LEDR(4 - nivel) <= '1';
                    else
                        LEDR(4 + nivel) <= '1';
                    end if;
                else
                    if SW1 = '1' then
                        LEDR(4 + nivel) <= '1';
                    else
                        LEDR(4 - nivel) <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture funcionamiento;