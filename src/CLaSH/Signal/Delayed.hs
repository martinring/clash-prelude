{-|
Copyright  :  (C) 2013-2016, University of Twente
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveLift                 #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImplicitParams             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}

{-# LANGUAGE Trustworthy #-}

{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
{-# OPTIONS_HADDOCK show-extensions #-}

module CLaSH.Signal.Delayed
  ( -- * Delay-annotated synchronous signals
    DSignal
  , delayD
  , delayDI
  , feedback
    -- * Signal \<-\> DSignal conversion
  , fromSignal
  , toSignal
    -- * List \<-\> DSignal conversion (not synthesisable)
  , dfromList
    -- ** lazy versions
  , dfromList_lazy
    -- * Experimental
  , unsafeFromSignal
  , antiDelay
  )
where

import Control.DeepSeq            (NFData)
import Data.Bits                  (Bits, FiniteBits)
import Data.Coerce                (coerce)
import Data.Default               (Default(..))
import Control.Applicative        (liftA2)
import GHC.Stack                  (HasCallStack)
import GHC.TypeLits               (KnownNat, Nat, type (+))
import Language.Haskell.TH.Syntax (Lift)
import Prelude                    hiding (head, length, repeat)
import Test.QuickCheck            (Arbitrary, CoArbitrary)

import CLaSH.Class.Num            (ExtendingNum (..), SaturatingNum)
import CLaSH.Promoted.Nat         (SNat)
import CLaSH.Sized.Vector         (Vec, head, length, repeat, shiftInAt0,
                                   singleton)
import CLaSH.Signal               (Signal, Clock, Reset, fromList, fromList_lazy,
                                   register, bundle, unbundle)
import CLaSH.Signal.Explicit      (Domain)

{- $setup
>>> :set -XDataKinds
>>> :set -XTypeOperators
>>> import CLaSH.Prelude
>>> let delay3 = delay (0 :> 0 :> 0 :> Nil)
>>> let delay2 = delayI :: DSignal n Int -> DSignal (n + 2) Int
>>> :{
let mac :: DSignal 0 Int -> DSignal 0 Int -> DSignal 0 Int
    mac x y = feedback (mac' x y)
      where
        mac' :: DSignal 0 Int -> DSignal 0 Int -> DSignal 0 Int
             -> (DSignal 0 Int, DSignal 1 Int)
        mac' a b acc = let acc' = a * b + acc
                       in  (acc, delay (singleton 0) acc')
:}

-}

-- | A synchronized signal with samples of type @a@, synchronized to \"system\"
-- clock (period 1000), that has accumulated @delay@ amount of samples delay
-- along its path.
newtype DSignal (domain :: Domain) (delay :: Nat) a =
    DSignal { -- | Strip a 'DSignal' from its delay information.
              toSignal :: Signal domain a
            }
  deriving (Default,Functor,Applicative,Num,Bounded,Fractional,
            Real,Integral,SaturatingNum,Eq,Ord,Enum,Bits,FiniteBits,Foldable,
            Traversable,Arbitrary,CoArbitrary,Lift)

instance ExtendingNum a b => ExtendingNum (DSignal dom n a) (DSignal dom n b) where
  type AResult (DSignal dom n a) (DSignal dom n b) = DSignal dom n (AResult a b)
  plus  = liftA2 plus
  minus = liftA2 minus
  type MResult (DSignal dom n a) (DSignal dom n b) = DSignal dom n (MResult a b)
  times = liftA2 times

-- | Create a 'DSignal' from a list
--
-- Every element in the list will correspond to a value of the signal for one
-- clock cycle.
--
-- >>> sampleN 2 (dfromList [1,2,3,4,5])
-- [1,2]
--
-- __NB__: This function is not synthesisable
dfromList :: NFData a => [a] -> DSignal dom 0 a
dfromList = coerce . fromList

-- | Create a 'DSignal' from a list
--
-- Every element in the list will correspond to a value of the signal for one
-- clock cycle.
--
-- >>> sampleN 2 (dfromList [1,2,3,4,5])
-- [1,2]
--
-- __NB__: This function is not synthesisable
dfromList_lazy :: [a] -> DSignal dom 0 a
dfromList_lazy = coerce . fromList_lazy

-- | Delay a 'DSignal' for @d@ periods.
--
-- @
-- delay3 :: 'DSignal' n Int -> 'DSignal' (n + 3) Int
-- delay3 = 'delay' (0 ':>' 0 ':>' 0 ':>' 'Nil')
-- @
--
-- >>> sampleN 6 (delay3 (dfromList [1..]))
-- [0,0,0,1,2,3]
delayD :: forall domain res clk a n d .
          (HasCallStack, KnownNat d,
           ?res :: Reset res domain,
           ?clk :: Clock clk domain)
       => Vec d a
       -> DSignal domain n a
       -> DSignal domain (n + d) a
delayD m ds = coerce (delay' (coerce ds))
  where
    delay' :: Signal domain a -> Signal domain a
    delay' s = case length m of
      0 -> s
      _ -> let (r',o) = shiftInAt0 (unbundle r) (singleton s)
               r      = register m (bundle r')
           in  head o

-- | Delay a 'DSignal' for @m@ periods, where @m@ is derived from the context.
--
-- @
-- delay2 :: 'DSignal' n Int -> 'DSignal' (n + 2) Int
-- delay2 = 'delayI'
-- @
--
-- >>> sampleN 6 (delay2 (dfromList [1..]))
-- [0,0,1,2,3,4]
delayDI :: (HasCallStack, Default a, KnownNat d,
            ?res :: Reset res domain,
            ?clk :: Clock clk domain)
        => DSignal domain n a
        -> DSignal domain (n + d) a
delayDI = delayD (repeat def)

-- | Feed the delayed result of a function back to its input:
--
-- @
-- mac :: 'DSignal' 0 Int -> 'DSignal' 0 Int -> 'DSignal' 0 Int
-- mac x y = 'feedback' (mac' x y)
--   where
--     mac' :: 'DSignal' 0 Int -> 'DSignal' 0 Int -> 'DSignal' 0 Int
--          -> ('DSignal' 0 Int, 'DSignal' 1 Int)
--     mac' a b acc = let acc' = a * b + acc
--                    in  (acc, 'delay' ('singleton' 0) acc')
-- @
--
-- >>> sampleN 6 (mac (dfromList [1..]) (dfromList [1..]))
-- [0,1,5,14,30,55]
feedback :: (DSignal dom n a -> (DSignal dom n a,DSignal dom (n + m + 1) a))
         -> DSignal dom n a
feedback f = let (o,r) = f (coerce r) in o

-- | 'Signal's are not delayed
--
-- > sample s == dsample (fromSignal s)
fromSignal :: Signal dom a -> DSignal dom 0 a
fromSignal = coerce

-- | __EXPERIMENTAL__
--
-- __Unsafely__ convert a 'Signal' to /any/ 'DSignal'.
--
-- __NB__: Should only be used to interface with functions specified in terms of
-- 'Signal'.
unsafeFromSignal :: Signal dom a -> DSignal dom n a
unsafeFromSignal = DSignal

-- | __EXPERIMENTAL__
--
-- Access a /delayed/ signal in the present.
--
-- @
-- mac :: 'DSignal' 0 Int -> 'DSignal' 0 Int -> 'DSignal' 0 Int
-- mac x y = acc'
--   where
--     acc' = (x * y) + 'antiDelay' d1 acc
--     acc  = 'delay' ('singleton' 0) acc'
-- @
antiDelay :: SNat d -> DSignal dom (n + d) a -> DSignal dom n a
antiDelay _ = coerce
