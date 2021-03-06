{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
import           Criterion.Main
import           Criterion
import qualified Weigh                         as W

import           Control.MapReduce             as MR
import           Control.MapReduce.Engines.GroupBy
                                               as MRG
import           Data.Function                  ( on )
import           Data.Text                     as T
import           Data.List                     as L
import           Data.Foldable                 as F
import           Data.Functor.Identity          ( Identity(Identity)
                                                , runIdentity
                                                )
import           Data.Sequence                 as Seq
import           Data.Maybe                     ( catMaybes )
import           System.Random                  ( randomRs
                                                , newStdGen
                                                )

import qualified Data.HashMap.Lazy             as HML
import qualified Data.HashMap.Strict           as HMS
import qualified Data.Map                      as ML
import qualified Data.Map.Strict               as MS

createPairData :: Int -> IO [(Char, Int)]
createPairData n = do
  g <- newStdGen
  let randLabels = L.take n $ randomRs ('A', 'Z') g
      randInts   = L.take n $ randomRs (1, 100) g
  return $ L.zip randLabels randInts
--      makePair k = (toEnum $ fromEnum 'A' + k `mod` 26, k `mod` 31)
--  in  L.unfoldr (\m -> if m > n then Nothing else Just (makePair m, m + 1)) 0

promote :: (Char, Int) -> (Char, [Int])
promote (k, x) = (k, [x])

justSort :: [(Char, Int)] -> [(Char, Int)]
justSort = L.sortBy (compare `on` fst)

listViaStrictMap :: [(Char, Int)] -> [(Char, [Int])]
listViaStrictMap = MS.toList . MS.fromListWith (<>) . fmap promote
{-# INLINE listViaStrictMap #-}

listViaLazyMap :: [(Char, Int)] -> [(Char, [Int])]
listViaLazyMap = ML.toList . ML.fromListWith (<>) . fmap promote
{-# INLINE listViaLazyMap #-}

listViaStrictHashMap :: [(Char, Int)] -> [(Char, [Int])]
listViaStrictHashMap = HMS.toList . HMS.fromListWith (<>) . fmap promote
{-# INLINE listViaStrictHashMap #-}

listViaLazyHashMap :: [(Char, Int)] -> [(Char, [Int])]
listViaLazyHashMap = HML.toList . HML.fromListWith (<>) . fmap promote
{-# INLINE listViaLazyHashMap #-}

groupSum :: [(Char, [Int])] -> ML.Map Char Int
groupSum = ML.fromList . fmap (\(k, ln) -> (k, L.sum ln))

check reference toCheck = do
  let
    refGS = groupSum reference
    checkOne (name, gl) =
      let gs = groupSum gl
      in
        if refGS == gs
          then putStrLn (name ++ " good.")
          else putStrLn
            (name ++ " different!\n ref=\n" ++ show refGS ++ "\n" ++ show gs)
  mapM_ checkOne toCheck

toTry :: [(String, [(Char, Int)] -> [(Char, [Int])])]
toTry =
  [ ( "strict map"
    , listViaStrictMap
    )
{-    
    , ("lazy map"                 , listViaLazyMap)
    , ("strict hash map"          , listViaStrictHashMap)
    , ("lazy hash map"            , listViaLazyHashMap)
    , ("TVL general merge"        , MRG.groupByTVL)
    , ("List.sort + fold to group", MRG.groupByHR)
    , ("recursion-schemes, naive insert + group", MRG.groupByNaiveInsert)

  , ("recursion-schemes, naive bubble + group", MRG.groupByNaiveBubble)
-}
  , ("recursion-schemes, foo (grouping version)", MRG.groupByFoo)
  , ( "recursion-schemes, naive insert (grouping swap version)"
    , MRG.groupByNaiveInsert'
    )
--  , ( "recursion-schemes, naive insert (grouping swap version, DList)"
--    , unDList . MRG.groupByNaiveInsert'
--    )
  , ( "recursion-schemes, naive bubble (grouping swap version)"
    , MRG.groupByNaiveBubble'
    )
--  , ( "recursion-schemes, naive bubble (grouping swap version, DList)"
--    , unDList . MRG.groupByNaiveBubble'
--    )
{-
    , ("recursion-schemes, insert (fold of grouping apo)"   , MRG.groupByInsert)
-}
  , ("recursion-schemes, bubble (unfold of grouping para)", MRG.groupByBubble)
{-    
    , ( "recursion-schemes, insert (fold of grouping apo, swop version)"
      , MTG.groupByInsert'
      )
    , ( "recursion-schemes, bubble (unfold of grouping para, swop version)"
      , MRG.groupByBubble'
      )
    , ( "recursion-schemes, hylo (grouping unfold to Tree, fold to list)"
      , MRG.groupByTree1
      )
    , ( "recursion-schemes, naive insert + group + internal x -> [x]"
      , MRG.groupByNaiveInsert2
      )
-}
  ]

benchAll dat toTry = defaultMain
  [ bgroup (show (L.length dat) ++ " of [(Char, Int)]")
           (fmap (\(n, f) -> (bench n $ nf f dat)) toTry)
  ]

checkAll dat toTry =
  check (listViaStrictMap dat) (fmap (\(k, f) -> (k, f dat)) toTry)

{- This is hanging...
weighAll dat toTry = W.mainWith $ mapM_ (\(n, f) -> W.func n f dat) toTry
-}

main :: IO ()
main = do
  dat <- createPairData 50000
  checkAll dat toTry
  putStrLn ""
  benchAll dat toTry
