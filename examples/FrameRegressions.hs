{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE QuasiQuotes               #-}
module Main where

import qualified Control.Foldl                as FL
import           Control.Monad.IO.Class (MonadIO (..))
import qualified Data.List                    as List
import           Data.Maybe                   (fromMaybe)
import qualified Data.Map                     as M
import qualified Data.Text                    as T
import qualified Data.Text.IO                 as T
import qualified Data.Text.Lazy               as TL
import qualified Data.Vector.Storable         as V
import qualified Data.Vinyl                   as V
import qualified Frames                       as F

import qualified Numeric.LinearAlgebra        as LA
import           Numeric.LinearAlgebra        (R, Matrix)

import qualified Frames.Regression            as FR
import qualified Frames.VegaLite               as FV
import qualified Html.Blaze.Report            as H
import qualified Text.Blaze.Html5              as H
import qualified Text.Blaze.Html5.Attributes   as HA
import           Text.Blaze.Html              ((!))
import qualified Text.Blaze.Html.Renderer.Text as BH
import qualified Text.Pandoc.Report           as P
import qualified Statistics.Types             as S

import qualified Control.Monad.Freer.Logger   as Log
import qualified Control.Monad.Freer          as FR
import qualified Control.Monad.Freer.PandocMonad as FR
import qualified Control.Monad.Freer.Pandoc as P
import Data.String.Here

templateVars = M.fromList
  [
    ("lang", "English")
  , ("author", "Adam Conner-Sax")
  , ("pagetitle", "Frame Regression Examples")
--  , ("tufte","True")
  ]

regressionNotesMD
  = [here|
## Regression Algorithm Comparison
* To get data for testing we choose xs evenly spaced between -0.5 and 0.5.  Then we compute ys via $y=1 + 2.2x$.  Then we add Gaussian noise to the ys.  We can optionally add Gaussian noise to the observed xs as well (that is, the ys are still calculated from the exact xs but we add noise to the xs before we regress) and add weights to the (x,y) pairs.
* For unweighted data we use ordinary least squares (OLS) and total least square (TLS).
* For weighted data we use weighted least squares (WOLS) and weighted total least squares (WTLS).
* Both TLS and WTLS are computed via the Singular Value Decomposition.
* For each comparison we vary the level of noise on the ys and/or xs, regress, then show the results of each regression in tabular form, a plot of the fits and prediction intervals together with a scatter of the noisy data, and a plot of the coefficients and confidence intervals. The shaded regions in each plot are the "prediction intervals" which take into account the uncertainty of the coefficients as well as the remainining noise in the data.
* The F-stat is computed for each fit via comparision to the model of intercept-only.  So the p-value of the overall fit is the probability that the data are better explained as noise around their (weighted) mean value than by the fit.
|]

main :: IO ()
main = asPandoc
  
asPandoc :: IO ()
asPandoc = do
  let runAllP = FR.runPandocAndLoggingToIO Log.logAll
                . Log.wrapPrefix "Main"
                . fmap BH.renderHtml
  htmlAsTextE <- runAllP $ P.pandocWriterToBlazeDocument (Just "pandoc-templates/minWithVega-pandoc.html") templateVars P.mindocOptionsF $ do
    P.addMarkDown regressionNotesMD
    testMany
  case htmlAsTextE of
    Right htmlAsText -> T.writeFile "examples/html/FrameRegressions.html" $ TL.toStrict  $ htmlAsText
    Left err -> putStrLn $ "pandoc error: " ++ show err

{-
asBlaze :: IO ()
asBlaze = do
  let runAllP = FR.runPandocAndLoggingToIO Log.logAll . Log.wrapPrefix "Main" . blazeToText 
  htmlAsTextE <- runAllP $ do    
    regressionNotesBlaze <- P.markDownTextToBlazeFragment regressionNotesMD
    blaze $ H.makeReportHtml "Frame Regression Examples" $ do
      H.placeTextSection $ regressionNotesBlaze  
    testMany
  case htmlAsTextE of
    Right htmlAsText -> T.writeFile "examples/html/FrameRegressions.html" $ TL.toStrict  $ htmlAsText
    Left err -> putStrLn $ "pandoc error: " ++ show err
-}

-- regression tests

-- build some data for testing
-- uniformly distributed measurements, normally distributed noise.  Separate noise amplitudes for xs and ys
-- also allow building heteroscedastic data

type Y = "y" F.:-> Double
type X = "x" F.:-> Double
--type X2 = "x2" F.:-> Double
type Weight = "weight" F.:-> Double

buildRegressable :: [Double] -> Maybe (LA.Vector R) -> Double -> LA.Vector R -> Double -> IO (LA.Vector R, LA.Matrix R)
buildRegressable variances offsetsM noiseObs coeffs noiseMeas = do
  -- generate random measurements
  let d = LA.size coeffs
      nObs = List.length variances
      xsO = LA.asColumn (LA.fromList (List.replicate nObs 1)) LA.<> LA.asRow (fromMaybe (LA.fromList $ List.replicate (d-1) 0) offsetsM)
--  xs0 <- LA.cmap (\x-> x - 0.5) <$> LA.rand nObs (d-1) -- 0 centered uniformly distributed random numbers
  let xs0 :: Matrix R = LA.asColumn $ LA.fromList $ [-0.5 + (realToFrac i/realToFrac nObs) | i <- [0..(nObs-1)]]
  xNoise <- LA.randn nObs (d-1) -- 0 centered normally (sigma=1) distributed random numbers
  let xsC = 1 LA.||| (xs0 + xsO)
      xsN = 1 LA.||| (xs0 + xsO + LA.scale noiseMeas xNoise)
  let ys0 = xsC LA.<> LA.asColumn coeffs
  yNoise <- fmap (List.head . LA.toColumns) (LA.randn nObs 1) -- 0 centered normally (sigma=1) distributed random numbers
  let ys = ys0 + LA.asColumn (LA.scale noiseObs (V.zipWith (*) yNoise (LA.cmap sqrt (LA.fromList variances))))
  return (List.head (LA.toColumns ys), xsN)

type AllCols = [Y,X,Weight]

makeFrame :: [Double] -> (LA.Vector R, LA.Matrix R) -> IO (F.FrameRec AllCols)
makeFrame vars (ys, xs) = do
  if snd (LA.size xs) /= 2 then error ("Matrix of xs wrong size (" ++ show (LA.size xs) ++ ") for makeFrame") else return ()
  let rows = LA.size ys
      rowIndex = [0..(rows - 1)]
      makeRecord :: Int -> F.Record AllCols
      makeRecord n = ys `LA.atIndex` n F.&: xs `LA.atIndex` (n,1) F.&: vars List.!! n F.&: V.RNil -- skip bias column
  return $ F.toFrame $ makeRecord <$> rowIndex


unweighted :: Int -> [Double]
unweighted n = List.replicate n (1.0)

coneWeighted :: Int -> Double -> Double -> [Double]
coneWeighted n base increment =
  let w0 = [base + (realToFrac i) * increment | i <- [1..n]]
      s = realToFrac n/FL.fold FL.sum w0
  in fmap (*s) w0

showText :: Show a => a -> T.Text
showText = T.pack . show

coeffs :: LA.Vector R = LA.fromList [1.0, 2.2]
offsets :: LA.Vector R = LA.fromList [1]
vars = coneWeighted 100 1 0.1
varListToWeights = LA.cmap (\x -> 1/sqrt x) . LA.fromList
wgts = varListToWeights vars

testRegressions :: ( F.ColumnHeaders '[w]
                   , FR.BoolVal (FR.NonVoidField w)
                   , V.KnownField w
                   , Traversable f
                   , Foldable f
                   , FR.Member P.ToPandoc effs
                   , Log.LogWithPrefixes effs
                   , FR.PandocEffects effs
                   , MonadIO (FR.Eff effs))
                => Double
                -> Double
                -> Bool
                -> Bool
                -> T.Text
                -> f (T.Text, (F.FrameRec AllCols -> FR.Eff effs (FR.FrameRegressionResult Y True '[X] w AllCols)))
                -> FR.Eff effs ()
testRegressions  yNoise xNoise weighted offset vizId keyedFs = do
  let title = "Sy=" <> showText yNoise <> " gaussian noise added to ys & "
               <> "Sx=" <> showText xNoise <> " gaussian noise added to xs"
               <> " (" <> (if weighted then "cone weights" else "unweighted") <> (if offset then ", w/offsets" else "") <> ")"
      vars = if weighted then coneWeighted 100 1 0.1 else unweighted 100
      wgts = varListToWeights vars
      offsetM = if offset then (Just offsets) else Nothing
      doOne dat (key, f) = do
        result <- f dat
        return (key, result)
  frame <- liftIO (buildRegressable vars offsetM yNoise coeffs xNoise >>= makeFrame vars)
  results <- traverse (doOne frame) keyedFs
  let header _ _ = title
  P.addMarkDown $ "\n## " <> title 
  P.addBlaze $ do
    H.div ! HA.style "display: block-inline" $ do
    FR.prettyPrintRegressionResults id results S.cl95 FR.prettyPrintRegressionResultBlaze mempty
    H.placeVisualization (vizId <> "_fits") $ FV.keyedLayeredFrameScatterWithFit title id results S.cl95 frame
    H.placeVisualization (vizId <> "_regresssionCoeffs") $ FV.regressionCoefficientPlotMany id "Parameters" ["intercept","x"] (fmap (\(k,frr) -> (k, FR.regressionResult frr)) results) S.cl95
--  return ()


-- I can't test the weighted and unweighted on the same things because those algos return different types in their results.  Which, maybe, is a good point.
testMany :: ( FR.Member P.ToPandoc effs
            , Log.LogWithPrefixes effs
            , FR.PandocEffects effs
            , MonadIO (FR.Eff effs)) =>  FR.Eff effs ()
testMany = Log.wrapPrefix "Many" $ do
  let toTestUW  =
        [
          ("OLS", FR.ordinaryLeastSquares)
        , ("TLS", FR.totalLeastSquares)
        ]
      toTestW =
        [
          ("WOLS", FR.weightedLeastSquares)
        , ("WTLS", FR.weightedTLS)
        ]
  testRegressions 0.0 0.0 False False "many1" toTestUW
  testRegressions 0.3 0.0 False False "many2" toTestUW
  testRegressions 0.5 0.0 False False "many3" toTestUW
  testRegressions 0.3 0.1 False False "many4" toTestUW
  testRegressions 3 0.0 False False "many9" toTestUW
  testRegressions @Weight 0.3 0.0 True False "many6" toTestW
  testRegressions @Weight 0.5 0.0 True False "many7" toTestW
  testRegressions @Weight 0.3 0.1 True False "many8" toTestW

{-

testRegression :: ( F.ColumnHeaders '[w]
                  , V.KnownField w
                  , FR.Members '[Log.Logger, Blaze] effs
                  , MonadIO (FR.Eff effs))
               => Double
               -> Double
               -> Bool
               -> Bool
               -> T.Text
               -> (F.FrameRec AllCols -> FR.Eff effs (FR.FrameRegressionResult Y True '[X] w AllCols))
               -> FR.Eff effs ()
testRegression yNoise xNoise weighted offset vizId f = do
  let scopeT = "Sy=" <> showText yNoise <> " gaussian noise added to ys & "
               <> "Sx=" <> showText xNoise <> " gaussian noise added to xs"
               <> " (" <> (if weighted then "cone weights" else "unweighted") <> (if offset then ", w/offsets" else "") <> ")"
      vars = if weighted then coneWeighted 100 1 0.1 else unweighted 100
      wgts = varListToWeights vars
      offsetM = if offset then (Just offsets) else Nothing
  frame <- liftIO (buildRegressable vars offsetM yNoise coeffs xNoise >>= makeFrame vars)
  result <- f frame
  let header _ _ = scopeT
  blaze $ FR.prettyPrintRegressionResultBlaze header result S.cl95
  blaze $ H.placeVisualization vizId $ FV.frameScatterWithFit scopeT (Just vizId) result S.cl95 frame
  Log.log Log.Info $ FR.prettyPrintRegressionResult header result S.cl95
  return ()

--const3 f x y z = f x y




testOLS :: Log.Logger (H.HtmlT IO) ()
testOLS =  Log.wrapPrefix "OLS" $ do
  let regress = FR.ordinaryLeastSquares
  htmlLift $ Log.log Log.Info "Ordinary Least Squares"
  testRegression 0 0 False False "OLS1" regress
  testRegression 0.1 0 False False "OLS2" regress
  testRegression 0.5 0 False False "OLS3" regress
--  testRegression 0.1 0 False True "OLS4" regress
  testRegression 0.3 0.3 False False "OLS5" regress
  testRegression 0.3 0 True False "OLS6" regress
  testRegression 0.3 0.3 True False "OLS7" regress

testWOLS :: Log.Logger (H.HtmlT IO) ()
testWOLS =  Log.wrapPrefix "WOLS" $ do
  let regress = FR.weightedLeastSquares
  htmlLift $ Log.log Log.Info "Weighted Ordinary Least Squares"
  testRegression @Weight 0 0 True False "WOLS1" regress
  testRegression @Weight 0.1 0 True False "WOLS2" regress
  testRegression @Weight 0.1 0 False False "WOLS3" regress
  testRegression @Weight 0.3 0 True False "WOLS4" regress
  testRegression @Weight 0.1 0.1 True False "WOL5" regress
--  testRegression @Weight 0.1 0.1 True True "WOLS6" regress
  testRegression @Weight 0.3 0.3 True False "WOLS7" regress

testTLS :: Log.Logger (H.HtmlT IO) ()
testTLS = Log.wrapPrefix "TLS" $ do
  let regress = FR.totalLeastSquares
  htmlLift $ Log.log Log.Info "Total Least Squares"
  testRegression 0 0 False False "TLS1" regress
  testRegression 0.1 0 False False "TLS2" regress
  testRegression 0.5 0 False False "TLS3" regress
--  testRegression 0.1 0 False True "TLS4" regress
  testRegression 0.3 0.3 False False "TLS5" regress
  testRegression 0.3 0 True False "TLS6" regress
  testRegression 0.3 0.3 True False "TLS7" regress

testWTLS :: Log.Logger (H.HtmlT IO) ()
testWTLS =  Log.wrapPrefix "WTLS" $ do
  let regress = FR.weightedTLS
  htmlLift $ Log.log Log.Info "Weighted Total Least Squares"
  testRegression @Weight 0 0 True False "WTLS1" regress
  testRegression @Weight 0.1 0 True False "WTLS2" regress
  testRegression @Weight 0.1 0 False False "WTLS3" regress
  testRegression @Weight 0.3 0 True False "WTLS4" regress
  testRegression @Weight 0.1 0.1 True False "WTLS5" regress
--  testRegression @Weight 0.1 0.1 True True "WTLS6" regress
  testRegression @Weight 0.3 0.3 True False "WTLS7" regress

-}
