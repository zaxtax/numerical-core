{-# LANGUAGE PolyKinds   #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-#  LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-#  LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}


module Numerical.Array.Layout(
  Locality(..)
  ,Format(..)
  ,Row
  ,Column
  ,Direct
  ,Layout(..)
  ,Address(..)
  ,UniformAddressInterval(..)) where



import Numerical.Nat
import Control.Applicative
import Numerical.Array.Address
import Numerical.Array.Locality
import Numerical.Array.Shape as S

import qualified Data.Foldable as F

import Prelude hiding (foldr,foldl,map,scanl,scanr,scanl1,scanr1)

{-|  A major design goal with the Layout module is to
make it easy to define new dense array layouts



-}


--data PrimLay a
--data StaticLay a
--data Lay a


data Direct

data Row

data Column


{-
NB: may need to add some specialization for low rank indexing,
theres 4 choices:
a) INLINE EVERYTHING
b) rewrite rules that take low rank indexing code into specialized versions thereof
c) wait till ghc 7.8.2 to resolve https://ghc.haskell.org/trac/ghc/ticket/8848
    and use SPECIALIZE
d) benchmark and then decide

for now I choose (e), defer benchmarking till everything works :)


a related concern is the interplay of inlining and specialization
https://ghc.haskell.org/trac/ghc/ticket/5928

-}


{-
note also that this is in practice a *dense* only
layout module, though a derived api can interpret those
formats sparsely



-}





data family Format lay (contiguity:: Locality)  (rank :: Nat)


class Layout lay (contiguity:: Locality) (rank :: Nat)  where

    type Tranposed lay


    transposedLayout ::  (lay ~ Tranposed l2,l2~Tranposed lay)=> Format lay contiguity rank -> Format l2 contiguity rank
    --shapeOf

    basicToAddress :: Format lay contiguity rank -> Shape rank Int -> Address


    basicToIndex :: Format   lay contiguity rank -> Address -> Shape rank Int

    --unchecked
    --nextAddress --- not sure if this should even exist for contiguous ones..
    -- not sure if this is the right model for the valid ops
    --validAddress::Form   lay contiguity rank -> Int -> Either String (Shape rank Int)
    --validIndex ::Form   lay contiguity rank -> Shape rank Int -> Either String Int
    basicNextAddress :: Format   lay contiguity rank -> Address ->  Address
    basicNextAddress =  \form shp ->  basicToAddress form $  (basicNextIndex form  $! basicToIndex form  shp )
    {-# INLINE basicNextAddress #-}

    basicNextIndex :: Format  lay contiguity rank -> Shape rank Int ->(Shape rank Int)
    basicNextIndex  = \form shp ->  basicToIndex form  $  (basicNextAddress form  $! basicToAddress form  shp )
    {-# INLINE  basicNextIndex #-}




    -- one of basicNextAddress and basicNextIndex must always be implemented
    {-# MINIMAL transposedLayout, basicToIndex, basicToAddress, (basicNextIndex | basicNextAddress ) #-}

-----
-----
-----

data instance Format  Direct Contiguous (S Z) =
            FormatDirectContiguous { logicalShapeDirectContiguous :: {-#UNPACK#-} !Int }

instance Layout Direct Contiguous (S Z)   where
    type Tranposed Direct = Direct


    transposedLayout = id

    {-#INLINE basicToAddress#-}
    basicToAddress   (FormatDirectContiguous _) (j :* _ )= Address j

    --basicNextIndex=  undefined -- \ _ x ->  Just $! x + 1
    --note its unchecked!
    {-# INLINE basicToIndex#-}
    basicToIndex =  \ (FormatDirectContiguous _) (Address ix)  -> (ix ) :* Nil

    basicNextAddress = \ _ addr -> addr + 1



data instance Format  Direct Strided (S Z) =
        FormatDirectStrided { logicalShapeDirectStrided :: {-#UNPACK#-}!Int
                    , logicalStrideDirectStrided:: {-#UNPACK#-}!Int}

instance Layout Direct Strided (S Z)   where
    type Tranposed Direct = Direct


    transposedLayout = id

    {-#INLINE basicToAddress#-}
    basicToAddress   = \ (FormatDirectStrided _ strid) (j :* Nil )->  Address (strid * j)

    {-# INLINE basicNextAddress #-}
    basicNextAddress = \ (FormatDirectStrided _ strid) addr ->  addr + Address strid

    {-# INLINE basicNextIndex#-}
    basicNextIndex =  \ _  (i:* Nil ) ->  (i + 1 :* Nil )


    {-# INLINE basicToIndex#-}
    basicToIndex = \ (FormatDirectStrided _ stride) (Address ix)  -> (ix `div` stride ) :* Nil

-----
-----
-----



data instance  Format  Row  Contiguous rank  = FormatRowContiguous {boundsFormRow :: !(Shape rank Int)}
-- strideRow :: Shape rank Int,
instance   (Applicative (Shape rank),F.Foldable (Shape rank), Scannable rank)
    => Layout Row  Contiguous rank where

    type Tranposed Row = Column

    transposedLayout = \(FormatRowContiguous shp) -> FormatColumnContiguous $ reverseShape shp

    {-# INLINE basicToAddress #-}
    basicToAddress = \rs tup -> let !strider =takePrefix $! S.scanr (*) 1 (boundsFormRow rs)
                                in Address $! S.foldl'  (+) 0 $! map2 (*) strider tup
    {-# INLINE basicNextAddress#-}
    basicNextAddress = \_ addr -> addr + 1

    {-# INLINE basicToIndex #-}
    basicToIndex  =   \ rs (Address ix) -> case boundsFormRow rs of
          Nil -> Nil
          (_:*_)->
            let !striderShape  =takePrefix $! S.scanr (*) 1 (boundsFormRow rs)
                in  S.map  fst $!
                            S.scanl1 (\(_,r) strid -> r `quotRem`  strid)
                                (ix,error "impossible remainder access in Row Contiguous basicToIndex") striderShape




-----
-----
data instance  Format  Row  InnerContiguous rank  =
        FormatRowInnerContiguous {boundsFormRowInnerContig :: !(Shape rank Int), strideFormRowInnerContig:: !(Shape rank Int)}
-- strideRow :: Shape rank Int,
instance   (Applicative (Shape rank),F.Foldable (Shape rank), Scannable rank) => Layout Row  InnerContiguous rank where
    type Tranposed Row = Column



    transposedLayout = \(FormatRowInnerContiguous shp stride) ->
        FormatColumnInnerContiguous  (reverseShape shp)  (reverseShape stride)

    {-# INLINE basicToAddress #-}
    basicToAddress = \rs tup ->   Address $! S.foldl'  (+) 0 $! map2 (*) (strideFormRowInnerContig rs ) tup

    {-# INLINE basicNextIndex #-}
    basicNextIndex = \ (FormatRowInnerContiguous shape _) ix ->
        S.map snd $! S.scanl1Zip (\( carry, _ ) ixv shpv   -> divMod (carry + ixv) shpv ) (1,error "nextAddress init value accessed")  ix shape

    {-# INLINE basicToIndex #-}
    basicToIndex  =   \ rs (Address ix) -> case boundsFormRowInnerContig rs of
          Nil -> Nil
          (_:*_)->
              S.map  fst $!
                S.scanl1 (\(_,r) strid -> r `quotRem`  strid)
                    (ix,error "impossible remainder access in Row Contiguous basicToIndex") (strideFormRowInnerContig rs )


---
---
data instance  Format  Row  Strided rank  =
        FormatRowStrided {boundsFormRowStrided:: !(Shape rank Int), strideFormRowStrided:: !(Shape rank Int)}
-- strideRow :: Shape rank Int,
instance  (Applicative (Shape rank),F.Foldable (Shape rank), Scannable rank)=> Layout Row  Strided rank where
    type Tranposed Row = Column



    transposedLayout = \(FormatRowStrided shp stride) ->
        FormatColumnStrided  (reverseShape shp)  (reverseShape stride)

    {-# INLINE basicToAddress #-}
    basicToAddress = \rs tup ->   Address $! S.foldl'  (+) 0 $! map2 (*) (strideFormRowStrided rs ) tup

    {-#INLINE basicNextIndex#-}
    basicNextIndex = \ (FormatRowStrided shape _) ix ->
        S.map snd $! S.scanl1Zip (\( carry, _ ) ixv shpv   -> divMod (carry + ixv) shpv ) (1,error "nextAddress init value accessed")  ix shape

    {-# INLINE basicToIndex #-}
    basicToIndex  =   \ rs (Address ix) -> case boundsFormRowStrided rs of
          Nil -> Nil
          (_:*_)->
              S.map  fst $!
                S.scanl1 (\(_,r) strid -> r `quotRem`  strid)
                    (ix,error "impossible remainder access in Row Contiguous basicToIndex")
                    (strideFormRowStrided rs )

-----
-----
-----

data instance  Format  Column Contiguous rank  = FormatColumnContiguous {boundsColumnContig :: !(Shape rank Int)}
 -- strideRow :: Shape rank Int,
instance  (Applicative (Shape rank),F.Foldable (Shape rank), Scannable rank)=> Layout Column  Contiguous rank where
    type Tranposed Column = Row


    transposedLayout = \(FormatColumnContiguous shp)-> FormatRowContiguous $ reverseShape shp
    {-# INLINE basicToAddress #-}
    basicToAddress    =   \ rs tup -> let !strider =  takeSuffix $! S.scanl (*) 1 (boundsColumnContig rs)
                                in Address $! foldl' (+) 0  $! map2 (*) strider tup
    {-# INLINE basicNextAddress #-}
    basicNextAddress = \ _ addr -> addr + 1

    {-# INLINE  basicToIndex#-}
    basicToIndex  = \ rs (Address ix) -> case boundsColumnContig rs of
          Nil -> Nil
          (_:*_)->
              let !striderShape  =takeSuffix $! S.scanl (*) 1 (boundsColumnContig rs)
                  in S.map  fst  $!
                        S.scanr1 (\ strid (_,r)  -> r `quotRem`  strid)
                            (ix,error "impossible remainder access in Column Contiguous basicToIndex") striderShape




data instance  Format Column InnerContiguous rank  = FormatColumnInnerContiguous {boundsColumnInnerContig :: !(Shape rank Int), strideFormColumnInnerContig:: !(Shape rank Int)}
 -- strideRow :: Shape rank Int,
instance  (Applicative (Shape rank),F.Foldable (Shape rank), Scannable rank)=> Layout Column  InnerContiguous rank where
    type Tranposed Column = Row


    transposedLayout = \(FormatColumnInnerContiguous shp stride)->
         FormatRowInnerContiguous (reverseShape shp) (reverseShape stride)

    {-# INLINE basicToAddress #-}
    basicToAddress    =   \ form tup -> let !strider =   strideFormColumnInnerContig form
                                in Address $! foldl' (+) 0  $! map2 (*) strider tup
    {-#INLINE basicNextIndex #-}
    basicNextIndex = \ (FormatColumnInnerContiguous shape _) ix ->
        S.map snd $! S.scanr1Zip (\ ixv shpv ( carry, _ ) -> divMod (carry + ixv) shpv) (1,error "nextAddress init value accessed")  ix shape


    {-# INLINE  basicToIndex#-}
    basicToIndex  = \ form (Address ix) -> case boundsColumnInnerContig form  of
          Nil -> Nil
          (_:*_)->
              let !striderShape  = strideFormColumnInnerContig form
                  in S.map  fst  $!   S.scanr1 (\ stride (_,r)  -> r `quotRem`  stride)
                        (ix,error "impossible remainder access in Column Contiguous basicToIndex") striderShape


data instance  Format Column Strided rank  = FormatColumnStrided {boundsColumnStrided :: !(Shape rank Int), strideFormColumnStrided:: !(Shape rank Int)}
 -- strideRow :: Shape rank Int,
instance   (Applicative (Shape rank),F.Foldable (Shape rank), Scannable rank)=> Layout Column  Strided rank where
    type Tranposed Column = Row


    transposedLayout = \(FormatColumnStrided shp stride)->
         FormatRowStrided (reverseShape shp) (reverseShape stride)

    {-# INLINE basicToAddress #-}
    basicToAddress    =   \ form tup -> let !strider =   strideFormColumnStrided form
                                in Address $! foldl' (+) 0  $! map2 (*) strider tup
    {-# INLINE basicNextIndex#-}
    basicNextIndex = \ (FormatColumnStrided shape _) ix ->
        S.map snd $! S.scanr1Zip (\ ixv shpv ( carry, _ ) -> divMod (carry + ixv) shpv) (1,error "nextAddress init value accessed")  ix shape

    {-# INLINE  basicToIndex#-}
    basicToIndex  = \ form (Address ix) -> case boundsColumnStrided form  of
          Nil -> Nil
          (_:*_)->
              let !striderShape  = strideFormColumnStrided form
                  in S.map  fst  $!   S.scanr1 (\ stride (_,r)  -> r `quotRem`  stride)
                        (ix,error "impossible remainder access in Column Contiguous basicToIndex") striderShape



{-
*Numerical.Array.Layout> basicToAddress (FormColumn (2 :* 3 :* 7 :* Nil)) (0:* 2 :* 2 :* Nil)
Address 16
*Numerical.Array.Layout> basicToAddress (FormColumn (2 :* 3 :* 7 :* Nil)) (1:* 0 :* 0 :* Nil)
Address 1
*Numerical.Array.Layout> basicToAddress (FormColumn (2 :* 3 :* 7 :* Nil)) (0:* 0 :* 0 :* Nil)
Address 0
*Numerical.Array.Layout> basicToAddress (FormColumn (2 :* 3 :* 7 :* Nil)) (0:* 1 :* 0 :* Nil)
Address 2
*Numerical.Array.Layout> basicToAddress (FormColumn (2 :* 3 :* 7 :* Nil)) (0:* 0 :* 1 :* Nil)



-}


--data Elem ls el  where
--    Point :: Elem '[] el
--    (:#) :: a -> Elem ls el -> Elem (a ': ls) el


{-
    One important invariant about all layouts at all ranks is that for
    any given ints x < y, that the array index for inr

     toIndex shapedLayout (pure x :: Shape rank Int) is strictly less than
     toIndex shapedLayout (pure y :: Shape rank Int).

     more generally

     for rank k tuples,
      xi = x_1 :* ... :* x_k *: Nil  and
      yj = y_1 :* ... :* x_k *: Nil
      such that forall \ell, x_\ell  < y_\ell
    we have that
       toIndex shapedLayout xi <  toIndex  shapedLayout yj


this actually relates to the notion of partial ordering over vectors in convex
geometry!


so roughly: we have layouts that are dense
we have layouts that can be used as tiles (and are dense)

and we have layouts which can can't be tiled, but can have elements which are tiled

So we have

PrimitiveLayouts

Static Layouts

General Layouts (which are a Top level layout over a static layout)

the Layout class tries to abstract over all three cases
(NB: this only makes sense when the "rank" for the inner
and outer layouts have the same rank!)

-}


{- Sized is used as a sort of hack to make it easy to express
   the staticly sized layouts. NB, one trade off is that its only
   possible to express  "cube" shaped blocks, but on the other
   hand blocking sizes are expressible for every single rank!
-}
--data Sized :: * -> * where
    --(:@) :: Nat -> a -> Sized a


{-

per se I don't need the StaticLay, PrimLay, Lay constructors, BUT
I really do like how it makes things a teeny bit simpler.. though I may remove them
-}



--class SimpleDenseLayout lay (rank :: Nat) where
--  type SimpleDenseTranpose lay
--  toIndexSimpleDense :: Shaped rank Int lay -> Shape rank Int -> Int


--class PrimLayout lay (rank :: Nat) where
--    type TranposedPrim lay
--    toIndexPrim :: Shaped rank Int (PrimLay lay) -> Shape rank Int -> Int
--    fromIndexPrim :: Shaped rank Int (PrimLay lay) -> Int -> Shape rank Int


{-
for now we will not deal with nested formats, but this will
be a breaking change i plan for later
-}

{-
what is the law for the Layout class?
forall valid formms
toIndex sd  (fromIndex sd ix)==ix
fromIndex sd (toIndex sd shp)==shp
-}

{-
if   tup1 is strictly less than tup2 (pointwise),
  then any lawful Layout will asign tup1 an index strictly less than that
  asigned to tup2

  transposedLayout . transposedLayout == id



i treat coordinates as being in x:* y :* z :* Nil, which is Fortran style idexing

in row major we'd have for x:* y :* Nil that X is the inner dimension, and y the outter,
by contrast, in column major, y would be the inner most, and x the outter most.




-}


{- In some respects, the Layout type class is a multidimensional
analogue of the Enum type class in Haskell Prelude,
for Dense / Dense Structured matrix formats
but
    a) requires a witness value, the "Form"
    b) needs to handle multivariate structures
    c) has to deal with structure matrices, like triangular, symmetric, etc
    e) I think every layout should have pure 0 be a valid index, at least for "Dense"
    arrays
    f) transposedLayout . transposedLayout == id
    g)

  Form needs to carry the shape / extent of the matrix

-}
{-

-}

--data View = Origin | Slice
{-
i'm really really hoping to not need a View parameter,
but the nature of the addressing logic needs to change when its a slice
vs a deep copy (for certain classes of arrays that I wish to support very easily)

I will be likely adding this the moment benchmarks validate the distinction

on the
-}
