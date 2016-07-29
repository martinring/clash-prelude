{-|
Copyright   :  (C) 2015-2016, University of Twente
License     :  BSD2 (see the file LICENSE)
Maintainer  :  Christiaan Baaij <christiaan.baaij@gmail.com>

Synchronizer circuits for safe clock domain crossings
-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MagicHash             #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

{-# LANGUAGE Safe #-}

{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
{-# OPTIONS_HADDOCK show-extensions #-}

module CLaSH.Prelude.Synchronizer
  ( -- * Bit-synchronizers
    dualFlipFlopSynchronizer
    -- * Word-synchronizers
  , asyncFIFOSynchronizer
  )
where

import Data.Bits                   (complement, shiftR, xor)
import GHC.TypeLits                (type (+))

import CLaSH.Class.BitPack         (boolToBV)
import CLaSH.Prelude.BitIndex      (slice)
import CLaSH.Prelude.Mealy         (mealyB#)
import CLaSH.Prelude.RAM           (asyncRam#)
import CLaSH.Promoted.Nat          (SNat, pow2SNat, subSNat)
import CLaSH.Promoted.Nat.Literals (d0, d1, d2)
import CLaSH.Signal                (Clock,Reset,Signal,(.&&.), not1)
import CLaSH.Signal.Explicit       (register#, unsafeSynchronizer)
import CLaSH.Sized.BitVector       (BitVector, (++#))

-- * Dual flip-flop synchronizer

-- | Synchroniser based on two sequentially connected flip-flops.
--
--  * __NB__: This synchroniser can be used for __bit__-synchronization.
--
--  * __NB__: Although this synchroniser does reduce metastability, it does
--  not guarantee the proper synchronisation of a whole __word__. For
--  example, given that the output is sampled twice as fast as the input is
--  running, and we have two samples in the input stream that look like:
--
--      @[0111,1000]@
--
--      But the circuit driving the input stream has a longer propagation delay
--      on __msb__ compared to the __lsb__s. What can happen is an output stream
--      that looks like this:
--
--      @[0111,0111,0000,1000]@
--
--      Where the level-change of the __msb__ was not captured, but the level
--      change of the __lsb__s were.
--
--      If you want to have /safe/ __word__-synchronisation use
--      'asyncFIFOSynchronizer'.
dualFlipFlopSynchronizer :: Reset res2 dom2
                         -> Clock clk1 dom1 -- ^ 'Clock' to which the incoming
                                            -- data is synchronised
                         -> Clock clk2 dom2 -- ^ 'Clock' to which the outgoing
                                            -- data is synchronised

                         -> a               -- ^ Initial value of the two
                                            -- synchronisation registers
                         -> Signal dom1 a   -- ^ Incoming data
                         -> Signal dom2 a   -- ^ Outgoing, synchronised, data
dualFlipFlopSynchronizer res clk1 clk2 i = register# res clk2 i
                                         . register# res clk2 i
                                         . unsafeSynchronizer clk1 clk2

---- * Asynchronous FIFO synchronizer

fifoMem :: _
        => Clock wclk wdom
        -> Clock rclk rdom
        -> SNat addrSize
        -> Signal wdom (BitVector addrSize)
        -> Signal rdom (BitVector addrSize)
        -> Signal wdom Bool
        -> Signal wdom Bool
        -> Signal wdom a
        -> Signal rdom a
fifoMem wclk rclk addrSize waddr raddr winc wfull wdata =
  asyncRam# wclk rclk
            (pow2SNat addrSize)
            waddr raddr
            (winc .&&. not1 wfull)
            wdata

ptrCompareT :: _
            => SNat (addrSize + 1)
            -> (BitVector (addrSize + 2) -> BitVector (addrSize + 2) -> Bool)
            -> (BitVector (addrSize + 2), BitVector (addrSize + 2), Bool)
            -> (BitVector (addrSize + 2), Bool)
            -> ((BitVector (addrSize + 2), BitVector (addrSize + 2), Bool)
               ,(Bool, BitVector (addrSize + 1), BitVector (addrSize + 2)))
ptrCompareT addrSize flagGen (bin,ptr,flag) (s_ptr,inc) = ((bin',ptr',flag')
                                                          ,(flag,addr,ptr))
  where
    -- GRAYSTYLE2 pointer
    bin' = bin + boolToBV (inc && not flag)
    ptr' = (bin' `shiftR` 1) `xor` bin'
    addr = slice (addrSize `subSNat` d1) d0 bin

    flag' = flagGen ptr' s_ptr

-- FIFO full: when next pntr == synchonized {~wptr[addrSize:addrSize-1],wptr[addrSize-1:0]}
isFull :: _
       => SNat (2 + addrSize)
       -> BitVector ((2 + addrSize) + 1)
       -> BitVector ((2 + addrSize) + 1)
       -> Bool
isFull addrSize ptr s_ptr =
  ptr == (complement (slice addrSize (addrSize `subSNat` d1) s_ptr) ++#
         slice (addrSize `subSNat` d2) d0 s_ptr)

-- | Synchroniser implemented as a FIFO around an asynchronous RAM. Based on the
-- design described in "CLaSH.Tutorial#multiclock", which is itself based on the
-- design described in <http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_FIFO1.pdf>.
--
-- __NB__: This synchroniser can be used for __word__-synchronization.
asyncFIFOSynchronizer :: _
                      => SNat (addrSize + 2) -- ^ Size of the internally used
                                             -- addresses, the FIFO contains
                                             -- @2^addrSize@ elements.
                      -> Reset res wdom
                      -> Reset res rdom
                      -> Clock wclk wdom     -- ^ 'Clock' to which the write port
                                             -- is synchronised
                      -> Clock rclk rdom     -- ^ 'Clock' to which the read port
                                             -- is synchronised
                      -> Signal wdom a       -- ^ Element to insert
                      -> Signal wdom Bool    -- ^ Write request
                      -> Signal rdom Bool    -- ^ Read request
                      -> (Signal rdom a, Signal rdom Bool, Signal wdom Bool)
                      -- ^ (Oldest element in the FIFO, @empty@ flag, @full@ flag)
asyncFIFOSynchronizer addrSize wres rres wclk rclk wdata winc rinc = (rdata,rempty,wfull)
  where
    s_rptr = dualFlipFlopSynchronizer wres rclk wclk 0 rptr
    s_wptr = dualFlipFlopSynchronizer rres wclk rclk 0 wptr

    rdata = fifoMem wclk rclk addrSize waddr raddr winc wfull wdata

    (rempty,raddr,rptr) = mealyB# rres rclk (ptrCompareT addrSize (==)) (0,0,True)
                                  (s_wptr,rinc)

    (wfull,waddr,wptr)  = mealyB# wres wclk (ptrCompareT addrSize (isFull addrSize))
                                  (0,0,False) (s_rptr,winc)
