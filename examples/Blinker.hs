module Blinker where

import Clash.Prelude
import Clash.Intel.ClockGen
import Clash.Annotations.SynthesisAttributes

data LedMode
  = Rotate
  -- ^ After some period, rotate active led to the left
  | Complement
  -- ^ After some period, turn on all disable LEDs, and vice versa
  deriving (Generic, NFDataX)

-- Define a synthesis domain with a clock with a period of 20000 /ps/. Signal
-- coming from the reset button is low when pressed, and high when not pressed.
createDomain vSystem{vName="Input", vPeriod=20000, vResetPolarity=ActiveLow}

-- Define a synthesis domain with a clock with a period of 50000 /ps/.
createDomain vSystem{vName="Dom50", vPeriod=50000}

{-# ANN topEntity
  (Synthesize
    { t_name   = "blinker"
    , t_inputs = [ PortName "CLOCK_50"
                 , PortName "KEY0"
                 , PortName "KEY1"
                 ]
    , t_output = PortName "LED"
    }) #-}
topEntity
  :: Clock Input
      `Annotate` 'StringAttr "chip_pin" "R8"
      `Annotate` 'StringAttr "altera_attribute" "-name IO_STANDARD \"3.3-V LVTTL\""
  -- ^ Incoming clock
  --
  -- Annotate with attributes to map the argument to the correct pin, with the
  -- correct voltage settings, on the DE0-Nano development kit.
  -> Reset Input
      `Annotate` 'StringAttr "chip_pin" "J15"
      `Annotate` 'StringAttr "altera_attribute" "-name IO_STANDARD \"3.3-V LVTTL\""
  -- ^ Reset signal, straight from KEY0
  -> Signal Dom50 Bit
      `Annotate` 'StringAttr "chip_pin" "E1"
      `Annotate` 'StringAttr "altera_attribute" "-name IO_STANDARD \"3.3-V LVTTL\""
  -- ^ Mode choice, straight from KEY1. See 'LedMode'.
  -> Signal Dom50 (BitVector 8)
      `Annotate` 'StringAttr "chip_pin" "L3, B1, F3, D1, A11, B13, A13, A15"
      `Annotate` 'StringAttr "altera_attribute" "-name IO_STANDARD \"3.3-V LVTTL\""
  -- ^ Output containing 8 bits, corresponding to 8 LEDs
  --
  -- Use comma-seperated list in the "chip_pin" attribute to maps the individual
  -- bits of the result to the correct pins on the DE0-Nano development kit
topEntity clk20 rstBtn modeBtn =
  exposeClockResetEnable
    (mealy blinkerT initialStateBlinkerT (isRising 1 modeBtn))
    clk50
    rst50
    en
 where
  -- | Enable line for subcomponents: we'll keep it always running
  en = enableGen

  -- Start with the first LED turned on, in rotate mode, with the counter on zero
  initialStateBlinkerT = (1, Rotate, 0)

  -- Instantiate a PLL: this stabilizes the incoming clock signal and releases
  -- the reset output when the signal is stable. We're also using it to
  -- transform an incoming clock signal running at 20 MHz to a clock signal
  -- running at 50 MHz. Since the type signature for topEntity already specifies
  -- the domain, we don't need a type signature here.
  (clk50, rst50) = altpllSync clk20 rstBtn

flipMode :: LedMode -> LedMode
flipMode Rotate = Complement
flipMode Complement = Rotate

blinkerT
  :: (BitVector 8, LedMode, Index 16650001)
  -> Bool
  -> ((BitVector 8, LedMode, Index 16650001), BitVector 8)
blinkerT (leds, mode, cntr) key1R = ((leds', mode', cntr'), leds)
  where
    -- clock frequency = 50e6  (50 MHz)
    -- led update rate = 333e-3 (every 333ms)
    cnt_max = 16650000 :: Index 16650001 -- 50e6 * 333e-3

    cntr' | cntr == cnt_max = 0
          | otherwise       = cntr + 1

    mode' | key1R     = flipMode mode
          | otherwise = mode

    leds' | cntr == 0 =
              case mode of
                Rotate -> rotateL leds 1
                Complement -> complement leds
          | otherwise = leds
