{-# LANGUAGE AllowAmbiguousTypes  #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}


module Potato.Trader.Arbitrage (
  CtxPair,
  ExchangePairT,
  ArbitrageParams(..),
  ArbitrageLogs,
  ArbitrageConstraints,
  arbitrage,
  lifte1,
  lifte2,

  -- exported for testing
  searchMax
) where

import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.Writer.Lazy
import           Control.Parallel.Strategies
import           Data.Proxy
import qualified Data.Text                   as T
import           Data.Time.Clock
import           Potato.Trader.Helpers
import           Potato.Trader.Types

import           Debug.Trace


type CtxSingle e = (ExchangeData e, ExchangeAccount e)

-- | context tuple for operations on two exchanges in the same monad
-- newtype wrapper needed to avoid duplicate instances
type CtxPair e1 e2 = (CtxSingle e1, CtxSingle e2)

-- | logging type for arbitrage
-- TODO
data ArbitrageLogs = ArbitrageLogs deriving (Show)
instance Semigroup ArbitrageLogs where
  (<>) = const
instance Monoid ArbitrageLogs where
  mempty = ArbitrageLogs

--tellShow :: (Show a, MonadWriter [T.Text] m) => a -> m ()
--tellShow x = tell [T.pack (show x)]

tellString :: (MonadWriter [T.Text] m) => String -> m ()
tellString s = tell [T.pack s]

-- TODO figure out type signature
-- using this type signature creates ambiguous type var error.. don't entirely understand why because CtxSingle e1/e2 should always tuples inside of CtxPair e1 e2
--lifte1 :: forall e1 e2 m a. (Exchange e1, Exchange e2) => ExchangeT e1 m a -> ExchangePairT e1 e2 m a

-- | lift a reader action on r to a reader action on (r,b)
-- this matches the type `ExchangeT e1 m a -> ExchangePairT e1 e2 m a`
lifte1 :: ReaderT r m a -> ReaderT (r, b) m a
lifte1 a = ReaderT $ \(c1,_) -> runReaderT a c1

-- | lift a reader action on r to a reader action on (b,r)
-- this matches the type `ExchangeT e2 m a -> ExchangePairT e1 e2 m a`
lifte2 :: ReaderT r m a -> ReaderT (b, r) m a
lifte2 a = ReaderT $ \(_,c2) -> runReaderT a c2

-- | monad type used for arbitrage which allows operating on two exchanges at the same time
type ExchangePairT e1 e2 m = ReaderT (CtxPair e1 e2) m

-- can't remember why this is split into two
-- | constraint kind needed for arbitrage operations
type ArbitrageConstraints t1 t2 e1 e2 m = (ExchangePair t1 t2 e1, ExchangePair t1 t2 e2, MonadExchange m)
type ArbitrageConstraints_ t1 t2 e1 e2 m = (ArbitrageConstraints t1 t2 e1 e2 m, MonadWriter [T.Text] (ExchangePairT e1 e2 m))

data ArbitrageParams t1 t2 = ArbitrageParams {
  dryRun            :: Bool -- if true, does not actually send transactions
  , minProfitAmount :: (Amount t1, Amount t2) -- only arbitrage if profit is >= minProfitAmount
}

-- | check for arbitrage opportunities and submits orders if profitable
-- returns orders submitted or Nothing if no arbitrage was possible
-- throws if any query operation fails
-- does not attempt to do any recovery on failure so it's possible that one arbtriage order went through and the other did not
--
-- arbitrage only profits in t1, to profit on t2, call arbitrage using 'ReverseExchangePair'
-- note it's a little strange, because by convention, t1 is the security and t2 is the stable currency and you usually want to profit on the stable currency
--
-- arbitrage terminology
-- * b_tiek - balance in ti tokens on ek
-- * titjek in_tiek - exchange rate ti:tj on ek as a function of ti input tokens on ek (amount of tj obtained from selling ti for tj on ek)
--  e.g. t1t2e1 in_t1e1 - exchange rate of t1:t2 on e1 as a function of t1 input tokens on e1 (amount of t2 obtained from selling t1 on e1)
--  N.B that t1t2ek and t2t1ek are usually different due to market spread or whatever is going on in uniswap
-- * profit_tiek - profit in ti tokens on exchange ek (after arbitrage with el and ek)
--  e.g. profit_t1e2 - profit in t1 tokens on exchange e2
--
arbitrage :: forall t1 t2 e1 e2 m. (ArbitrageConstraints_ t1 t2 e1 e2 m)
  => Proxy (t1, t2, e1, e2)
  -> ArbitrageParams t1 t2
  -> ExchangePairT e1 e2 m (Maybe (Amount t1, Order t1 t2 e1, Order t1 t2 e2)) -- ^ returns tuple of profit and arbitrage orders if made, Nothing otherwise
arbitrage _ params = do

  startTime <- liftIO getCurrentTime
  tellString $ "BEGIN ARBITRAGE: " ++ show startTime

  -- query and cancel all orders
  qncresult <- try $ do
    let
      pe1 = Proxy :: Proxy (t1,t2,e1)
      pe2 = Proxy :: Proxy (t1,t2,e2)
    lifte1 (cancelAllOrders pe1)
    lifte2 (cancelAllOrders pe2)
  case qncresult of
    Left (SomeException e) -> tellString $ "exception when cancelling orders: " ++ show e
    Right _                -> return ()

  -- query balances
  gbresult <- try $ do
    t1e1 <- lifte1 $ getBalance (Proxy :: Proxy (t1, e1))
    t2e1 <- lifte1 $ getBalance (Proxy :: Proxy (t2, e1))
    t1e2 <- lifte2 $ getBalance (Proxy :: Proxy (t1, e2))
    t2e2 <- lifte2 $ getBalance (Proxy :: Proxy (t2, e2))
    return (t1e1, t2e1, t1e2, t2e2)
  (b_t1e1, b_t2e1, b_t1e2, b_t2e2) <- case gbresult of
    Left (SomeException e) -> do
      tellString $ "exception when querying balances: " ++ show e
      throwM e
      --return (0,0,0,0)
    Right r                -> return r

  tellString $ "BALANCES: " ++ show (b_t1e1, b_t2e1, b_t1e2, b_t2e2)
  --trace ("BALANCES: " ++ show (b_t1e1, b_t2e1, b_t1e2, b_t2e2)) $ return ()

  -- query exchange rate
  erresult <- try $ do
    exchRate1 <- lifte1 $ getExchangeRate (Proxy :: Proxy (t1,t2,e1)) True
    exchRate2 <- lifte2 $ getExchangeRate (Proxy :: Proxy (t1,t2,e2)) True
    return (exchRate1, exchRate2)
  (exchRate1, exchRate2) <- case erresult of
    Left (SomeException e) -> do
      tellString $ "exception when querying exchange rate: " ++ show e
      throwM e
    Right r                -> return r

  let
    dontSendOrder = dryRun params
    (mint1p,_) = minProfitAmount params
    sellt1_e1 = sellt1 exchRate1
    buyt1_e1 = buyt1 exchRate1
    sellt1_e2 = sellt1 exchRate2
    buyt1_e2 = buyt1 exchRate2
    tokenOrderStr = tokenName (Proxy :: Proxy t1) ++ ":" ++ tokenName (Proxy :: Proxy t2) ++ ":" ++ tokenName (Proxy :: Proxy t1)
    e1toe2Str = exchangeName (Proxy :: Proxy e1) ++ " to " ++ exchangeName (Proxy :: Proxy e2)
    e2toe1Str = exchangeName (Proxy :: Proxy e2) ++ " to " ++ exchangeName (Proxy :: Proxy e1)

  rOrders <- case profit_t1 (Proxy :: Proxy (t1,t2,e1,e2)) (b_t1e1, b_t2e1) (b_t1e2, b_t2e2) sellt1_e1 buyt1_e1 sellt1_e2 buyt1_e2 of
    Left (in_t1e2, out_profit_t1e1) -> if out_profit_t1e1 < mint1p then tellString "NO ARBITRAGE" >> return Nothing else do
      let
        out_t2e2 = sellt1_e2 in_t1e2
        in_t2e1 = out_t2e2
        out_t1e1 = buyt1_e1 in_t2e1
      tellString $ "RAN PROFIT " ++ tokenOrderStr ++ " " ++ e2toe1Str ++ ": " ++ show (in_t1e2, out_t2e2, out_t1e1)
      tellString $ "ACTUAL PROFIT: " ++ show out_profit_t1e1

      if dontSendOrder then return Nothing else do
        -- buy t1 on e1
        eo1 <- lifte1 $ order (Proxy :: Proxy (t1,t2,e1)) Flexible Buy out_t1e1 in_t2e1
        -- sell t1 on e2
        eo2 <- lifte2 $ order (Proxy :: Proxy (t1,t2,e2)) Flexible Sell in_t1e2 out_t2e2
        return $ Just (out_profit_t1e1, eo1, eo2)

    Right (in_t1e1, out_profit_t1e2) -> if out_profit_t1e2 < mint1p then tellString "NO ARBITRAGE" >> return Nothing else do
      let
        out_t2e1 = sellt1_e1 in_t1e1
        in_t2e2 = out_t2e1
        out_t1e2 = buyt1_e2 in_t2e2
      tellString $ "RAN PROFIT " ++ tokenOrderStr ++ " " ++ e1toe2Str ++ ": " ++ show (in_t1e1, out_t2e1, out_t1e2)
      tellString $ "ACTUAL PROFIT: " ++ show out_profit_t1e2

      if dontSendOrder then return Nothing else do
        -- sell t1 on e1
        eo1 <- lifte1 $ order (Proxy :: Proxy (t1,t2,e1)) Flexible Sell in_t1e1 out_t2e1
        -- buy t1 on e2
        eo2 <- lifte2 $ order (Proxy :: Proxy (t1,t2,e2)) Flexible Buy out_t1e2 in_t2e2
        return $ Just (out_profit_t1e2, eo1, eo2)

  endTime <- liftIO getCurrentTime
  tellString $ "END ARBITRAGE: " ++ show endTime
  return rOrders




-- |
profit_t1 ::
  forall t1 t2 e1 e2. (Token t1, Token t2)
  => Proxy (t1,t2,e1,e2) -- ^ proxy to help make "type bindings" in function name explicit. Note that there is no need fo constraints on e1 and e2.
  -> (Amount t1, Amount t2) -- ^ e1 balances
  -> (Amount t1, Amount t2) -- ^ e2 balances
  -> (Amount t1 -> Amount t2) -- ^ sellt1_e1
  -> (Amount t2 -> Amount t1) -- ^ buyt1_e1
  -> (Amount t1 -> Amount t2) -- ^ sellt1_e2
  -> (Amount t2 -> Amount t1) -- ^ buyt1_e2
  -> Either (Amount t1, Amount t1) (Amount t1, Amount t1) -- ^ amount of t1 to arbitrage and profit (Left means profit_t1e1 in_t1e2 and Right means on profit_t1e2 in_t1e1)
profit_t1 _ (b_t1e1, b_t2e1) (b_t1e2, b_t2e2) sellt1_e1 buyt1_e1 sellt1_e2 buyt1_e2 = r where

  -- construct profit functions
  profit_t1e1 = profit_tiek (Proxy :: Proxy (t1,t2,e1,e2)) sellt1_e2 buyt1_e1 b_t2e1
  profit_t1e2 = profit_tiek (Proxy :: Proxy (t1,t2,e2,e1)) sellt1_e1 buyt1_e2 b_t2e2


  -- always profit on t1 for now
  --domain = [Amount (floor (x/10.0 * fromIntegral b_t1e1)) | x <- [1.0..10.0::Double]]
  --pairs = zip (map domain) (map (. profit_t1e2) domain)
  --res = trace (show pairs) $ [100,50,10,10]
  res = [100,50,10,10]
  --res = []
  re1@(in_t1e2, out_t1e1) = searchMax res (0,b_t1e2) profit_t1e1
  re2@(in_t1e1, out_t1e2) = searchMax res (0,b_t1e1) profit_t1e2
  r = trace ("PROFITS: " ++ show (in_t1e2, out_t1e1, in_t1e1, out_t1e2)) $
    if out_t1e1 > out_t1e2 then Left re1 else Right re2

  -- TODO figure out conditions for profitting on t2 instead of t1 (to maximize arbitrage potential before more liquidity is needed in one exchange or the other)
  --profit_t2e2 = profit_tiek (Proxy :: Proxy (t2,t1,e2,e1)) buyt1_e1 sellt1_e2
  --profit_t2e1 = profit_tiek (Proxy :: Proxy (t2,t1,e1,e2)) buyt1_e2 sellt1_e1
  --this in incorrect, it's exchange specific
  --fi = fromIntegral
  --do_t1 = fi b_t1e1 / fi b_t1e2 > fi b_t2e1 / fi b_t2e2
  --arbitrage to profit in t2
  --pt2e1 = searchMax res (0,b_t2e2) profit_t2e1
  --pt2e2 = searchMax res (0,b_t2e1) profit_t2e2
  --if pt2e1 > pt2e2 then Left pt2e1 else Right pt2e2

-- |
-- profit in ti tokens on exchange ek (after arbitrage ti->tj on el and tj->ti on ek)
profit_tiek ::
  forall ti tj ek el.
  Proxy (ti, tj, el, ek) -- ^ proxy to help make "type bindings" in function name explicit. Note that there is no need fo constraints on e1 and e2.
  -> (Amount ti -> Amount tj) -- ^ sellti_el
  -> (Amount tj -> Amount ti) -- ^ buyti_ek
  -> Amount tj -- ^ amount of tj tokens we have to spend on ek
  -> Amount ti -- ^ ti tokens to sell on el
  -> Amount ti -- ^ profit in ti on ek
profit_tiek _ sellti_el buyti_ek max_in_tjek in_tiel = final where
  --ti:tj exchange ratio for input amount in_tiel on exchange el
  --in this case, we are selling ti on el
  titjel in_tiel' = makeRatio in_tiel' (sellti_el in_tiel')
  --1/tj:ti exchange ratio for input amount tiek_in on exchange ek
  -- in this case, we are buying ti on ek
  one_over_tjtiek in_tjek' = makeRatio (buyti_ek (min max_in_tjek in_tjek')) in_tjek'
  final = in_tiel /$:$ titjel in_tiel *$:$ one_over_tjtiek (sellti_el in_tiel) - in_tiel

-- TODO improve this to search multiple possible local maxima
-- | find the maximum of a function numerically
searchMax :: (Show a, Show b,  NFData b, Integral a, Ord b) =>
  [Int] -- ^ search resolution for each iteration
  -> (a,a) -- ^ search domain
  ->  (a->b) -- ^ function to search
  -> (a,b) -- ^ max value pair of the function we searched
searchMax [] (mn,mx) f = if f mn > f mx then (mn, f mn) else (mx, f mx)
searchMax (n':ns) (mn,mx) f = r where
  -- first split the domain including boundary points
  step' = (mx-mn) `div` fromIntegral n'
  (n,step) = if step' == 0 then (length range, 1) else (n',step') where
    range = [mn..mx]
  pts = [mn+step*fromIntegral i | i<-[0..n]]
  -- compute values in parallel
  vals = parMap rdeepseq f pts
  -- find the maximum value
  (_,maxp) = foldl1 (\(m,mp) (x,p) -> if x > m then (x,p) else (m,mp)) (zip vals pts)
  -- construct the new search domain and recurse
  back = max mn (maxp-step)
  front = min mx (maxp+step)
  r = if step == 1 then (maxp, f maxp) else searchMax ns (back, front) f
