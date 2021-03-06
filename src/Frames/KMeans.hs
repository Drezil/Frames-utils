{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE QuasiQuotes               #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE PolyKinds                 #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE AllowAmbiguousTypes       #-}
module Frames.KMeans
  ( --kMeans
--    kMeansWithClusters -- this one returns the centroid and the list of clustered rows
    kMeansOne
  , kMeansOneWithClusters
  , kMeansOneWCReduce
  , clusteredRows -- turn the output of the above into one set of labeled rows
  , IsCentroid
  , ClusterId
  , MarkLabel
  , forgyCentroids
  , partitionCentroids
  , kMeansPPCentroids
  , weighted2DRecord
-- * re-exports
  , euclidSq
  , l1dist
  , linfdist
  )
where

import qualified Frames.Utils                  as FU
import qualified Frames.Transform              as FT
import qualified Frames.MapReduce              as MR
import qualified Math.Rescale                  as MR
import qualified Math.KMeans                   as MK
import           Math.KMeans                    ( Weighted(..)
                                                , Cluster(..)
                                                , Clusters(..)
                                                , Centroids(..)
                                                , Distance
                                                , euclidSq
                                                , l1dist
                                                , linfdist
                                                )

import qualified Control.Monad.Freer           as FR
import qualified Control.Monad.Freer.Logger    as Log

import qualified Control.Foldl                 as FL
import qualified Data.List                     as List
import qualified Data.Map                      as M
import           Data.Maybe                     ( catMaybes )
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.Vinyl                    as V
import qualified Data.Vinyl.Curry              as V
--import qualified Data.Vinyl.Functor            as V
import qualified Data.Vinyl.TypeLevel          as V
import           Frames                         ( (&:) )
import qualified Frames                        as F
import qualified Frames.Melt                   as F
import qualified Data.Vector                   as V
import qualified Data.Vector.Unboxed           as U
import           Data.Random                   as R


-- k-means
-- use the weights when computing the centroid location
-- sometimes we get fewer than we expect.

-- compute some initial random locations using the (assumed uncorrelated) distribution of inputs
forgyCentroids
  :: forall x y w f m
   . ( F.AllConstrained (FU.RealFieldOf '[x, y, w]) '[x, y, w]
     , Foldable f
     , Functor f
     , R.MonadRandom m
     )
  => Int -- number of clusters
  -> f (F.Record '[x, y, w])
  -> m [U.Vector Double]
forgyCentroids n dataRows = MK.forgyCentroids n $ fmap toDblVec dataRows
 where
  toDblVec r = U.fromList
    [(realToFrac $ F.rgetField @x r), (realToFrac $ F.rgetField @y r)]


-- partition the initial points into n clusters and then take the centroid of each
partitionCentroids
  :: forall x y w f
   . ( F.AllConstrained (FU.RealFieldOf '[x, y, w]) '[x, y, w]
     , Foldable f
     , Show (V.Snd w)
     )
  => Int
  -> f (F.Record '[x, y, w])
  -> [U.Vector Double]
partitionCentroids = MK.partitionCentroids (weighted2DRecord @x @y @w)

-- Choose first from input at random
-- Now, until you have enough,
-- compute the minimum distance of every point to any of the current centroids
-- choose a new one by using those minimum distances as probabilities
-- NB: no already chosen center can be chosen since it has distance 0 from an existing one
-- should this factor in weights?  E.g., make pts with higher weights more likely?
kMeansPPCentroids
  :: forall x y w f m
   . ( R.MonadRandom m
     , F.AllConstrained (FU.RealFieldOf '[x, y, w]) '[x, y, w]
     , Foldable f
     , Show (V.Snd w)
     )
  => Distance
  -> Int
  -> f (F.Record '[x, y, w])
  -> m [U.Vector Double]
kMeansPPCentroids distF k dataRows = MK.kMeansPPCentroids distF k pts
 where
  pts = FL.fold
    (FL.Fold
      (\l r ->
        U.fromList
            [realToFrac $ F.rgetField @x r, realToFrac $ F.rgetField @y r]
          : l
      )
      []
      id
    )
    dataRows

weighted2DRecord
  :: forall x y w rs
   . (FU.RealFieldOf rs x, FU.RealFieldOf rs y, FU.RealFieldOf rs w)
  => Weighted (F.Record rs) (V.Snd w)
weighted2DRecord =
  let getX = realToFrac . F.rgetField @x
      getY = realToFrac . F.rgetField @y
      makeV r = U.fromList [getX r, getY r]
  in  Weighted 2 makeV (F.rgetField @w)

type WithScaledCols rs x y = rs V.++ [x, y]
type WithScaled rs x y = F.Record (WithScaledCols rs x y)

kMeansOne
  :: forall x y w f effs scaledX scaledY
   . ( F.AllConstrained (FU.CFieldOf Real '[x, y, w]) '[x, y, w]
     , FU.TField Double scaledX
     , FU.TField Double scaledY
     , Foldable f
     , Functor f
     , Log.LogWithPrefixes effs
     , Show (V.Snd w)
     )
  => FL.Fold (F.Record '[x, w]) (MR.ScaleAndUnscale (V.Snd x))
  -> FL.Fold (F.Record '[y, w]) (MR.ScaleAndUnscale (V.Snd y))
  -> Int
  -> (  Int
     -> f (F.Record '[scaledX, scaledY, w])
     -> FR.Eff effs [U.Vector Double]
     )  -- initial centroids, monadic because may need randomness
  -> Weighted (F.Record '[scaledX, scaledY, w]) (V.Snd w)
  -> Distance
  -> f (F.Record '[x, y, w])
  -> FR.Eff effs [(V.Snd x, V.Snd y, V.Snd w)]
kMeansOne sunXF sunYF numClusters makeInitial weighted distance dataRows =
  Log.wrapPrefix "KMeansOne" $ do
    let (sunX, sunY) = FL.fold
          ((,) <$> FL.premap F.rcast sunXF <*> FL.premap F.rcast sunYF)
          dataRows
        scaledRows = fmap
          (V.runcurryX
            (\x y w -> (MR.from sunX) x &: (MR.from sunY) y &: w &: V.RNil)
          )
          dataRows
    initial <- makeInitial numClusters scaledRows
    let initialCentroids = Centroids $ V.fromList $ initial
    (Clusters clusters) <-
      fst <$> MK.weightedKMeans initialCentroids weighted distance scaledRows
    let fix :: (U.Vector Double, V.Snd w) -> (V.Snd x, V.Snd y, V.Snd w)
        fix (v, wgt) =
          ((MR.backTo sunX) (v U.! 0), (MR.backTo sunY) (v U.! 1), wgt)
    return $ catMaybes $ V.toList $ fmap
      (fmap fix . MK.centroid weighted . members)
      clusters -- we drop empty clusters ??

kMeansOneWithClusters
  :: forall x y w rs f effs scaledX scaledY
   . ( F.AllConstrained (FU.CFieldOf Real '[x, y, w]) '[x, y, w]
     , Foldable f
     , Functor f
     , FU.TField Double scaledX
     , FU.TField Double scaledY
     , F.ElemOf rs x
     , F.ElemOf rs y
     , F.ElemOf rs w
     , '[scaledX, scaledY, w] F.⊆ WithScaledCols rs scaledX scaledY
     , rs F.⊆ WithScaledCols rs scaledX scaledY
     , Eq (WithScaled rs scaledX scaledY)
     , V.RMap (rs V.++ '[scaledX, scaledY])
     , V.ReifyConstraint Show F.ElField (rs V.++ '[scaledX, scaledY])
     , V.RecordToList (rs V.++ '[scaledX, scaledY])
     , Show (V.Snd w)
     , Log.LogWithPrefixes effs
     )
  => FL.Fold (F.Record '[x, w]) (MR.ScaleAndUnscale (V.Snd x))
  -> FL.Fold (F.Record '[y, w]) (MR.ScaleAndUnscale (V.Snd y))
  -> Int
  -> Int
  -> (  Int
     -> f (F.Record '[scaledX, scaledY, w])
     -> FR.Eff effs [U.Vector Double]
     )  -- initial centroids, monadic because may need randomness
  -> Weighted (WithScaled rs scaledX scaledY) (V.Snd w)
  -> Distance
  -> f (F.Record rs)
  -> FR.Eff
       effs
       [((V.Snd x, V.Snd y, V.Snd w), [F.Record rs])]
kMeansOneWithClusters sunXF sunYF numClusters numTries makeInitial weighted distance dataRows
  = Log.wrapPrefix "kMeansOneWithClusters" $ do
    let (sunX, sunY) = FL.fold
          ((,) <$> FL.premap F.rcast sunXF <*> FL.premap F.rcast sunYF)
          (fmap (F.rcast @'[x, y, w]) dataRows)
        addX = FT.recordSingleton @scaledX . MR.from sunX . F.rgetField @x
        addY = FT.recordSingleton @scaledY . MR.from sunY . F.rgetField @y
        addXY r = addX r F.<+> addY r
        plusScaled = fmap (FT.mutate addXY) dataRows
    initials <- mapM
      (const $ fmap (Centroids . V.fromList) $ makeInitial numClusters $ fmap
        F.rcast
        plusScaled
      )
      (V.replicate numTries ()) -- here we can throw away the other cols
  --  let initialCentroids = Centroids $ V.fromList $ initial
    tries <- mapM (\cs -> MK.weightedKMeans cs weighted distance plusScaled)
                  initials -- here we can't
    let costs = fmap (MK.kMeansCostWeighted distance weighted . fst) tries
    Log.logLE Log.Diagnostic $ "Costs: " <> (T.pack $ show costs)
    let
      (Clusters clusters, iters) = tries V.! (V.minIndex costs)
      fix :: (U.Vector Double, V.Snd w) -> (V.Snd x, V.Snd y, V.Snd w)
      fix (v, wgt) =
        ((MR.backTo sunX) (v U.! 0), (MR.backTo sunY) (v U.! 1), wgt)
      clusterOut (Cluster m) = case List.length m of
        0 -> Nothing
        _ -> fmap (, fmap (F.rcast @rs) m) (fix <$> MK.centroid weighted m)
      allClusters = V.toList $ fmap clusterOut clusters
    let result       = catMaybes allClusters
        nullClusters = List.length allClusters - List.length result
    Log.logLE Log.Diagnostic
      $  "Required "
      <> (T.pack $ show iters)
      <> " iterations to converge."
    if (nullClusters > 0)
      then
        Log.logLE Log.Warning
        $  (T.pack $ show nullClusters)
        <> " null clusters dropped."
      else Log.logLE Log.Diagnostic "All clusters have at least one member."
    return result

-- as a reduce for mapReduce
kMeansOneWCReduce
  :: forall ks x y w rs f effs scaledX scaledY
   . ( F.AllConstrained (FU.CFieldOf Real '[x, y, w]) '[x, y, w]
     , Foldable f
     , Functor f
     , FU.TField Double scaledX
     , FU.TField Double scaledY
     , F.ElemOf rs x
     , F.ElemOf rs y
     , F.ElemOf rs w
     , '[scaledX, scaledY, w] F.⊆ WithScaledCols rs scaledX scaledY
     , rs F.⊆ WithScaledCols rs scaledX scaledY
     , Eq (WithScaled rs scaledX scaledY)
     , V.RMap (rs V.++ '[scaledX, scaledY])
     , V.ReifyConstraint Show F.ElField (rs V.++ '[scaledX, scaledY])
     , V.RecordToList (rs V.++ '[scaledX, scaledY])
     , Show (V.Snd w)
     , Log.LogWithPrefixes effs
     )
  => Int
  -> Int
  -> (  Int
     -> f (F.Record '[scaledX, scaledY, w])
     -> FR.Eff effs [U.Vector Double]
     )  -- initial centroids, monadic because may need randomness
  -> Distance
  -> Weighted (WithScaled rs scaledX scaledY) (V.Snd w)
  -> FL.Fold (F.Record '[x, w]) (MR.ScaleAndUnscale (V.Snd x))
  -> FL.Fold
       (F.Record '[y, w])
       (MR.ScaleAndUnscale (V.Snd y))
  -> MR.ReduceM
       (FR.Eff effs)
       (F.Record ks)
       f
       (F.Record rs)
       ( M.Map
           (F.Record ks)
           [ ( (V.Snd x, V.Snd y, V.Snd w)
             , [F.Record rs]
             )
           ]
       )
kMeansOneWCReduce numClusters numTries makeInitial distance weighted sunX sunY
  = MR.ReduceM $ \k rows -> sequence $ M.singleton
    k
    (kMeansOneWithClusters @x @y @w sunX
                                    sunY
                                    numClusters
                                    numTries
                                    makeInitial
                                    weighted
                                    distance
                                    rows
    )

type IsCentroid = "is_centroid" F.:-> Bool
type ClusterId = "cluster_id" F.:-> Int
type MarkLabel = "mark_label" F.:-> Text

type ClusteredRow ks x y w = F.Record (ks V.++ [IsCentroid, ClusterId, MarkLabel] V.++ [x,y,w])

clusteredRows
  :: forall x y w ks rs
   . ( FU.RealFieldOf rs x
     , FU.RealFieldOf rs y
     , FU.RealFieldOf rs w
     , ClusteredRow
         ks
         x
         y
         w
         ~
         F.Record
         (ks V.++ '[IsCentroid, ClusterId, MarkLabel, x, y, w])
     )
  => (F.Record rs -> Text) -- label for each row
  -> M.Map (F.Record ks) [((V.Snd x, V.Snd y, V.Snd w), [F.Record rs])]
  -> [ClusteredRow ks x y w]
clusteredRows labelF m
  = let
      makeXYW :: (V.Snd x, V.Snd y, V.Snd w) -> F.Record '[x, y, w]
      makeXYW (x, y, w) = x &: y &: w &: V.RNil
      idAndLabel
        :: Bool -> Int -> Text -> F.Record '[IsCentroid, ClusterId, MarkLabel]
      idAndLabel ic cId l = ic &: cId &: l &: V.RNil
      doCentroid
        :: F.Record ks
        -> Int
        -> (V.Snd x, V.Snd y, V.Snd w)
        -> ClusteredRow ks x y w
      doCentroid k cId xyw = k F.<+> (idAndLabel True cId "") F.<+> makeXYW xyw
      doClusteredRow
        :: F.Record ks -> Int -> F.Record rs -> ClusteredRow ks x y w
      doClusteredRow k cId xs =
        k
          F.<+> (idAndLabel False cId (labelF xs))
          F.<+> (F.rcast @'[x, y, w] xs)
      doCluster
        :: Int
        -> F.Record ks
        -> ((V.Snd x, V.Snd y, V.Snd w), [F.Record rs])
        -> [ClusteredRow ks x y w]
      doCluster cId k (ctrd, rows) =
        doCentroid k cId ctrd : (fmap (doClusteredRow k cId) rows)
      doListOfClusters
        :: F.Record ks
        -> [((V.Snd x, V.Snd y, V.Snd w), [F.Record rs])]
        -> [ClusteredRow ks x y w]
      doListOfClusters k l =
        List.concat
          $ fmap (\(cId, cluster) -> doCluster cId k cluster)
          $ List.zip [1 ..] l
    in
      List.concat $ fmap (\(k, loc) -> doListOfClusters k loc) $ M.toList m


