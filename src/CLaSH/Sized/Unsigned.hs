{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

{-# OPTIONS_GHC -fno-warn-missing-methods #-}

module CLaSH.Sized.Unsigned
  ( Unsigned
  , resizeU
  )
where

import Data.Bits
import Data.Default
import Language.Haskell.TH
import Language.Haskell.TH.Syntax(Lift(..))
import GHC.TypeLits

import CLaSH.Bit
import CLaSH.Class.BitVector
import CLaSH.Promoted.Nat
import CLaSH.Sized.Vector

-- | Arbitrary precision unsigned integer represented by @n@ bits
newtype Unsigned (n :: Nat) = U Integer

instance Eq (Unsigned n) where
  (==) = eqU

{-# NOINLINE eqU #-}
eqU :: (Unsigned n) -> (Unsigned n) -> Bool
(U n) `eqU` (U m) = n == m

instance Ord (Unsigned n) where
  (<)  = ltU
  (>=) = geU
  (>)  = gtU
  (<=) = leU

ltU,geU,gtU,leU :: Unsigned n -> Unsigned n -> Bool
{-# NOINLINE ltU #-}
ltU (U n) (U m) = n < m
{-# NOINLINE geU #-}
geU (U n) (U m) = n >= m
{-# NOINLINE gtU #-}
gtU (U n) (U m) = n > m
{-# NOINLINE leU #-}
leU (U n) (U m) = n <= m

instance KnownNat n => Enum (Unsigned n) where
  succ           = plusU (fromIntegerU 1)
  pred           = minU (fromIntegerU 1)
  toEnum         = fromIntegerU . toInteger
  fromEnum       = fromEnum . toIntegerU

instance KnownNat n => Bounded (Unsigned n) where
  minBound = fromIntegerU 0
  maxBound = maxBoundU

{-# NOINLINE maxBoundU #-}
maxBoundU :: forall n . KnownNat n => Unsigned n
maxBoundU = U $ (2 ^ fromSNat (snat :: SNat n)) - 1

instance KnownNat n => Num (Unsigned n) where
  (+)         = plusU
  (-)         = minU
  (*)         = timesU
  negate      = id
  abs         = id
  signum      = signumU
  fromInteger = fromIntegerU

plusU,minU,timesU :: KnownNat n => Unsigned n -> Unsigned n -> Unsigned n
{-# NOINLINE plusU #-}
plusU (U a) (U b) = fromIntegerU_inlineable $ a + b

{-# NOINLINE minU #-}
minU (U a) (U b) = fromIntegerU_inlineable $ a - b

{-# NOINLINE timesU #-}
timesU (U a) (U b) = fromIntegerU_inlineable $ a * b

{-# NOINLINE signumU #-}
signumU :: Unsigned n -> Unsigned n
signumU (U 0) = (U 0)
signumU (U _) = (U 1)

fromIntegerU,fromIntegerU_inlineable :: forall n . KnownNat n => Integer -> Unsigned (n :: Nat)
{-# NOINLINE fromIntegerU #-}
fromIntegerU = fromIntegerU_inlineable
{-# INLINABLE fromIntegerU_inlineable #-}
fromIntegerU_inlineable i = U $ i `mod` (2 ^ fromSNat (snat :: SNat n))

instance KnownNat n => Real (Unsigned n) where
  toRational = toRational . toIntegerU

instance KnownNat n => Integral (Unsigned n) where
  quot      = quotU
  rem       = remU
  div       = quotU
  mod       = modU
  quotRem   = quotRemU
  divMod    = divModU
  toInteger = toIntegerU

quotU,remU,modU :: KnownNat n => Unsigned n -> Unsigned n -> Unsigned n
{-# NOINLINE quotU #-}
quotU = (fst.) . quotRemU_inlineable
{-# NOINLINE remU #-}
remU = (snd.) . quotRemU_inlineable
{-# NOINLINE modU #-}
(U a) `modU` (U b) = fromIntegerU_inlineable (a `mod` b)

quotRemU,divModU :: KnownNat n => Unsigned n -> Unsigned n -> (Unsigned n, Unsigned n)
quotRemU n d = (n `quotU` d,n `remU` d)
divModU n d  = (n `quotU` d,n `modU` d)

{-# INLINEABLE quotRemU_inlineable #-}
quotRemU_inlineable :: KnownNat n => Unsigned n -> Unsigned n -> (Unsigned n, Unsigned n)
(U a) `quotRemU_inlineable` (U b) = let (a',b') = a `quotRem` b
                                    in (fromIntegerU_inlineable a', fromIntegerU_inlineable b')

{-# NOINLINE toIntegerU #-}
toIntegerU :: Unsigned n -> Integer
toIntegerU (U n) = n

instance KnownNat n => Bits (Unsigned n) where
  (.&.)          = andU
  (.|.)          = orU
  xor            = xorU
  complement     = complementU
  bit            = bitU
  testBit        = testBitU
  bitSizeMaybe   = Just . finiteBitSizeU
  isSigned       = const False
  shiftL         = shiftLU
  shiftR         = shiftRU
  rotateL        = rotateLU
  rotateR        = rotateRU
  popCount       = popCountU

andU,orU,xorU :: KnownNat n => Unsigned n -> Unsigned n -> Unsigned n
{-# NOINLINE andU #-}
(U a) `andU` (U b) = fromIntegerU_inlineable (a .&. b)
{-# NOINLINE orU #-}
(U a) `orU` (U b)  = fromIntegerU_inlineable (a .|. b)
{-# NOINLINE xorU #-}
(U a) `xorU` (U b) = fromIntegerU_inlineable (xor a b)

{-# NOINLINE complementU #-}
complementU :: KnownNat n => Unsigned n -> Unsigned n
complementU = fromBitVector . vmap complement . toBitVector

{-# NOINLINE bitU #-}
bitU :: KnownNat n => Int -> Unsigned n
bitU = fromIntegerU_inlineable . bit

{-# NOINLINE testBitU #-}
testBitU :: Unsigned n -> Int -> Bool
testBitU (U n) i = testBit n i

shiftLU,shiftRU,rotateLU,rotateRU :: KnownNat n => Unsigned n -> Int -> Unsigned n
{-# NOINLINE shiftLU #-}
shiftLU _ b | b < 0  = error "'shiftL'{Unsigned} undefined for negative numbers"
shiftLU (U n) b      = fromIntegerU_inlineable (shiftL n b)
{-# NOINLINE shiftRU #-}
shiftRU _ b | b < 0  = error "'shiftR'{Unsigned} undefined for negative numbers"
shiftRU (U n) b      = fromIntegerU_inlineable (shiftR n b)
{-# NOINLINE rotateLU #-}
rotateLU _ b | b < 0 = error "'shiftL'{Unsigned} undefined for negative numbers"
rotateLU n b         = let b' = b `mod` finiteBitSizeU n
                       in shiftL n b' .|. shiftR n (finiteBitSizeU n - b')
{-# NOINLINE rotateRU #-}
rotateRU _ b | b < 0 = error "'shiftR'{Unsigned} undefined for negative numbers"
rotateRU n b         = let b' = b `mod` finiteBitSizeU n
                       in shiftR n b' .|. shiftL n (finiteBitSizeU n - b')

{-# NOINLINE popCountU #-}
popCountU :: Unsigned n -> Int
popCountU (U n) = popCount n

instance KnownNat n => FiniteBits (Unsigned n) where
  finiteBitSize  = finiteBitSizeU

{-# NOINLINE finiteBitSizeU #-}
finiteBitSizeU :: forall n . KnownNat n => Unsigned n -> Int
finiteBitSizeU _ = fromInteger $ fromSNat (snat :: SNat n)

instance forall n . KnownNat n => Lift (Unsigned n) where
  lift (U i) = sigE [| fromIntegerU i |] (decUnsigned $ fromSNat (snat :: (SNat n)))

decUnsigned :: Integer -> TypeQ
decUnsigned n = appT (conT ''Unsigned) (litT $ numTyLit n)

instance Show (Unsigned n) where
  show (U n) = show n

instance KnownNat n => Default (Unsigned n) where
  def = fromIntegerU 0

instance BitVector (Unsigned n) where
  type BitSize (Unsigned n) = n
  toBV   = toBitVector
  fromBV = fromBitVector

{-# NOINLINE toBitVector #-}
toBitVector :: KnownNat n => Unsigned n -> Vec n Bit
toBitVector (U m) = vreverse $ vmap (\x -> if odd x then H else L) $ viterateI (`div` 2) m

{-# NOINLINE fromBitVector #-}
fromBitVector :: KnownNat n => Vec n Bit -> Unsigned n
fromBitVector = fromBitList . reverse . toList

{-# INLINABLE fromBitList #-}
fromBitList :: KnownNat n => [Bit] -> Unsigned n
fromBitList l = fromIntegerU_inlineable
              $ sum [ n
                    | (n,b) <- zip (iterate (*2) 1) l
                    , b == H
                    ]

{-# NOINLINE resizeU #-}
-- | A resize operation that is zero-extends on extension, and wraps on truncation.
--
-- Increasing the size of the number extends with zeros to the left.
-- Truncating a number of length N to a length L just removes the left
-- (most significant) N-L bits.
--
resizeU :: KnownNat m => Unsigned n -> Unsigned m
resizeU (U n) = fromIntegerU_inlineable n
