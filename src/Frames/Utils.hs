{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
module Frames.Utils
  ( FType
  , DblX
  , DblY
  , goodDataCount
  , goodDataByKey
  , filterField
  , filterMaybeField
  , CField
  , CFieldOf
  , RealField
  , RealFieldOf
  , TField
  , TFieldOf
  , TwoColData
  , ThreeColData
  , ThreeDTransformable
  , KeyedRecord
  )
where

import qualified Control.MapReduce             as MR
import qualified Control.Foldl                 as FL
import qualified Data.Map                      as M
import           Data.Maybe                     ( isJust
                                                , fromJust
                                                )
import qualified Data.Vinyl                    as V
import qualified Data.Vinyl.TypeLevel          as V
import qualified Data.Vinyl.XRec               as V
import           Frames                         ( (:.) )
import qualified Frames                        as F
import qualified Frames.Melt                   as F
import qualified Frames.InCore                 as FI

-- THe functions below should move.  To MaybeUtils?  What about filterField?
-- returns a map, keyed by F.Record ks, of (number of rows, number of rows with all cols parsed)
-- required TypeApplications for ks
goodDataByKey
  :: forall ks rs
   . (ks F.⊆ rs, Ord (F.Record ks))
  => FL.Fold
       (F.Rec (Maybe F.:. F.ElField) rs)
       (M.Map (F.Record ks) (Int, Int))
goodDataByKey =
  let getKey = F.recMaybe . F.rcast @ks
  in  MR.basicListF @Ord
        MR.noUnpack
        (MR.assign (fromJust . getKey) id)
        (MR.Reduce $ \k -> M.singleton k . FL.fold goodDataCount)

goodDataCount :: FL.Fold (F.Rec (Maybe F.:. F.ElField) rs) (Int, Int)
goodDataCount =
  (,) <$> FL.length <*> FL.prefilter (isJust . F.recMaybe) FL.length

filterField
  :: forall k rs
   . (V.KnownField k, F.ElemOf rs k)
  => (V.Snd k -> Bool)
  -> F.Record rs
  -> Bool
filterField test = test . F.rgetField @k

filterMaybeField
  :: forall k rs
   . (F.ElemOf rs k, V.IsoHKD F.ElField k)
  => (V.HKD F.ElField k -> Bool)
  -> F.Rec (Maybe :. F.ElField) rs
  -> Bool
filterMaybeField test = maybe False test . V.toHKD . F.rget @k


type FType x = V.Snd x

type DblX = "double_x" F.:-> Double
type DblY = "double_y" F.:-> Double

type UseCols ks x y w = ks V.++ '[x,y,w]
type CField c x = (V.KnownField x, c (FType x))
type RealField x = CField Real x -- (V.KnownField x, Real (FType x))

type TField t x = (V.KnownField x, t ~ V.Snd x)


-- This thing is...unfortunate. Is there something built into Frames or Vinyl that would do this?
class (CField c x, F.ElemOf rs x {-x V.∈ rs-}) => CFieldOf c rs x
instance (CField c x, F.ElemOf rs x{- x V.∈ rs -}) => CFieldOf c rs x

class (RealField x, x V.∈ rs) => RealFieldOf rs x
instance (RealField x, x V.∈ rs) => RealFieldOf rs x

class (TField t x, F.ElemOf rs x {-x V.∈ rs-}) => TFieldOf t rs x
instance (TField t x, F.ElemOf rs x{- x V.∈ rs -}) => TFieldOf t rs x



type TwoColData x y = F.AllConstrained (RealFieldOf [x,y]) '[x, y]
type ThreeColData x y z = ([x,z] F.⊆ [x,y,z], [y,z] F.⊆ [x,y,z], [x,y] F.⊆ [x,y,z], F.AllConstrained (RealFieldOf [x,y,z]) '[x, y, z])

type KeyedRecord ks rs = (ks F.⊆ rs, Ord (F.Record ks))

type ThreeDTransformable rs ks x y w = (ThreeColData x y w, FI.RecVec (ks V.++ [x,y,w]),
                                        KeyedRecord ks rs,
                                        ks F.⊆ (ks V.++ [x,y,w]), (ks V.++ [x,y,w]) F.⊆ rs,
                                        F.ElemOf (ks V.++ [x,y,w]) x, F.ElemOf (ks V.++ [x,y,w]) y, F.ElemOf (ks V.++ [x,y,w]) w)



