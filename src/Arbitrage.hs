{-# LANGUAGE AllowAmbiguousTypes  #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE UndecidableInstances #-}


module Arbitrage (
  CtxPair(..),
  ExchangePairT(..),
  ArbitrageLogs,
  ArbitrageConstraints,
  doArbitrage,

  searchMax -- just for testing
) where

import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.Writer.Lazy
import           Control.Parallel.Strategies
import           Data.Proxy
import           Data.Semigroup
import           Types

import           Debug.Trace


type CtxSingle e = (ExchangeCache e, ExchangeAccount e)

-- | context tuple for operations on two exchanges in the same monad
-- newtype wrapper needed to avoid duplicate instances
type CtxPair e1 e2 = (CtxSingle e1, CtxSingle e2)

-- | constraint kind needed for arbitrage operations
type ArbitrageConstraints t1 t2 e1 e2 m = (
  ExchangePair t1 t2 e1
  , ExchangePair t1 t2 e2
  , MonadExchange m
  )

-- | logging type for arbitrage
data ArbitrageLogs = ArbitrageLogs deriving (Show)

-- TODO
instance Semigroup ArbitrageLogs where
  (<>) = const

instance Monoid ArbitrageLogs where
  mempty = ArbitrageLogs

-- | monad type used for arbitrage which allows operating on two exchanges at the same time
type ExchangePairT e1 e2 m = ReaderT (CtxPair e1 e2) m

-- TODO figure out type signature
-- using this type signature creates ambiguous type var error.. don't entirely understand why because CtxSingle e1/e2 should always tuples inside of CtxPair e1 e2
--lifte1 :: forall e1 e2 m a. (Exchange e1, Exchange e2) => ExchangeT e1 m a -> ExchangePairT e1 e2 m a

-- | lift a reader action on r to a reader action on (r,b)
-- this matches the type `ExchangeT e1 m a -> ExchangePairT e1 e2 m a`
lifte1 :: ReaderT r m a -> ReaderT (r, b) m a
lifte1 a = ReaderT $ \(c1,c2) -> runReaderT a c1

-- | lift a reader action on r to a reader action on (b,r)
-- this matches the type `ExchangeT e2 m a -> ExchangePairT e1 e2 m a`
lifte2 :: ReaderT r m a -> ReaderT (b, r) m a
lifte2 a = ReaderT $ \(c1,c2) -> runReaderT a c2


-- TODO move to a different file
-- | cancels all unexecuted or partially executed orders
cancelAllOrders :: (ExchangePair t1 t2 e, MonadExchange m) => Proxy (t1, t2, e) -> ExchangeT e m ()
cancelAllOrders p = do
  orders <- getOrders p
  mapM_ (cancel p) orders

-- | check for arbitrage opportunities and submits orders if profitable
-- returns orders submitted
doArbitrage :: forall t1 t2 e1 e2 m. (ArbitrageConstraints t1 t2 e1 e2 m, MonadWriter ArbitrageLogs (ExchangePairT e1 e2 m)) =>
  Proxy (t1, t2, e1, e2)
  -> ExchangePairT e1 e2 m ()
doArbitrage _ = do

  -- query and cancel all orders
  qncresult <- try $ do
    let
      pe1 = Proxy :: Proxy (t1,t2,e1)
      pe2 = Proxy :: Proxy (t1,t2,e2)
    lifte1 (cancelAllOrders pe1)
    lifte2 (cancelAllOrders pe2)
  case qncresult of
    -- TODO log and error and restart
    Left (SomeException e) -> return ()
    Right _                -> return ()

  -- query balances
  gbresult <- try $ do
    t1e1 <- lifte1 $ getBalance (Proxy :: Proxy (t1, e1))
    t2e1 <- lifte1 $ getBalance (Proxy :: Proxy (t2, e1))
    t1e2 <- lifte2 $ getBalance (Proxy :: Proxy (t1, e2))
    t2e2 <- lifte2 $ getBalance (Proxy :: Proxy (t2, e2))
    return (t1e1, t2e1, t1e2, t2e2)
  (b_t1e1, b_t2e1, b_t1e2, b_t2e2) <- case gbresult of
    -- TODO log and error and restart
    Left (SomeException e) -> return (0,0,0,0)
    Right r                -> return r

  -- query exchange rate
  erresult <- try $ do
    exchRate1 <- lifte1 $ getExchangeRate (Proxy :: Proxy (t1,t2,e1))
    exchRate2 <- lifte2 $ getExchangeRate (Proxy :: Proxy (t1,t2,e2))
    return (exchRate1, exchRate2)
  (exchRate1, exchRate2) <- case erresult of
    -- TODO log and error and restart
    Left (SomeException e) -> undefined
    Right r                -> return r


  let
  -- construct t1t2e1 t2t1e1 t1t2e2 t2t1e2
    sellt1_e1 = sellt1 exchRate1
    buyt1_e1 = buyt1 exchRate1
    sellt1_e2 = sellt1 exchRate2
    buyt1_e2 = buyt1 exchRate2

    --t1:t2 exchange ratio for input amount in_t1e1 on exchange e1
    --in this case, we are selling t1 on e1
    t1t2e1 in_t1e1 = in_t1e1 / sellt1_e1 in_t1e1

    --t2:t1 exchange ratio for input amount t1e1_in on exchange e1
    -- in this case, we are buying t1 on e1
    t2t1e1 in_t2e1 = buyt1_e1 in_t2e1 / in_t2e1

    --t1:t2 exchange ratio for input amount in_t1e2 on exchange e2
    --in this case, we are selling t1 on e1
    t1t2e2 in_t1e2 = in_t1e2 / sellt1_e2 in_t1e2

    --t2:t1 exchange ratio for input amount t1e2_in on exchange e2
    -- in this case, we are buying t1 on e2
    t2t1e2 in_t2e2 = buyt1_e2 in_t2e2 / in_t2e2




  -- do basic check of exchange rate direction
  -- note we assume `t1t2e1 x > t1t2e2 x` for all `x > 0`

  {-

  -- terminology
  -- * b_tiek - balance in ti tokens on ek
  -- * titjek in_tiek - exchange rate ti:tj on ek as a function of ti input tokens on ek
  --  e.g. t1t2e1 in_t1e1 - exchange rate of t1:t2 on e1 as a function of t1 input tokens on e1
  --  N.B that t1t2ek and t2t1ek are usually different
  -- * profit_tiek - profit in ti tokens on exchange ek (after arbitrage with el and ek)
  --  e.g. profit_t1e2 - profit in t1 tokens on exchange e2



  -- TODO something like this
  --if t1t2e1 > t1t2e2 then
      profit_t2e2 or profit_t1e1
    else
      profit_t1e2 or profit_t2e1

  --  if t1e1/t1e2 > t2e1/t2e2 then profit_t1e2 else profit_t2e1

  -- TODO abstract this in t1 t2 e1 e2 and use in commented line of code above
  -- TODO add tx fees...


    -- profit of t1 on exchange e2 after successful arbitrage
    profit_t1e2 in_t1e1 = 1/(t1t2e1 in_t1e1 * t2t1e2 (sellt1_e1 in_t1e1))

    -- TODO maximize profit heuristically

    -- TODO execute the trades if profit exceeds threshold
    -- add all trades to a list

  -- TODO sleep based on rate limit for api calls
  -}

  return ()




-- |
-- DELETE
profit ::
  (Token t1, Token t2, Exhange e1, Exchange e2)
  => (Amount t1, Amount t2) -- ^ e1 balances
  -> (Amount t1, Amount t2) -- ^ e2 balances
  -> (Amount t1 -> Amount t2) -- ^ sellt1_e1
  -> (Amount t2 -> Amount t1) -- ^ buyt1_e1
  -> (Amount t1 -> Amount t2) -- ^ sellt1_e2
  -> (Amount t2 -> Amount t1) -- ^ buyt1_e2
  ->
profit (b_t1e1, b_t2e1) (b_t1e2, b_t2e2) sellt1_e1 buyt1_e1 sellt1_e2 buyt1_e2 = undefined where
    -- construct t1t2e1 t2t1e1 t1t2e2 t2t1e2
    --t1:t2 exchange ratio for input amount in_t1e1 on exchange e1
    --in this case, we are selling t1 on e1
    t1t2e1 in_t1e1 = fromIntegral in_t1e1 / fromIntegral (sellt1_e1 in_t1e1)
    --t2:t1 exchange ratio for input amount t1e1_in on exchange e1
    -- in this case, we are buying t1 on e1
    t2t1e1 in_t2e1 = fromIntegral (buyt1_e1 in_t2e1) / fromIntegral in_t2e1
    --t1:t2 exchange ratio for input amount in_t1e2 on exchange e2
    --in this case, we are selling t1 on e1
    t1t2e2 in_t1e2 = fromIntegral in_t1e2 / fromIntegral (sellt1_e2 in_t1e2)
    --t2:t1 exchange ratio for input amount t1e2_in on exchange e2
    -- in this case, we are buying t1 on e2
    t2t1e2 in_t2e2 = fromIntegral (buyt1_e2 in_t2e2) / fromIntegral in_t2e2

    profit_t1ek

-- |
profit_t1e2 ::
  (Token t1, Token t2) =>
  Amount t1 -- ^ t1 tokens to sell on e1
  -> (Amount t1 -> Double) -- ^ sellt1_e1
  -> (Amount t2 -> Double) -- ^ buyt1_ek
  -> Amount t1 -- ^ profit in t1 on ek
profit_t1e2 in_t1e1 sellt1_e1 buyt1_e2 = Amount . floor $ 1/(t1t2e1 in_t1e1 * t2t1e2 (sellt1_e1 in_t1e1)) where
  --t1:t2 exchange ratio for input amount in_t1e1 on exchange e1
  --in this case, we are selling t1 on e1
  t1t2e1 in_t1e1' = fromIntegral in_t1e1' / fromIntegral (sellt1_e1 in_t1e1')
  --t2:t1 exchange ratio for input amount t1e2_in on exchange e2
  -- in this case, we are buying t1 on e2
  t2t1e2 in_t2e2' = fromIntegral (buyt1_e2 in_t2e2') / fromIntegral in_t2e2'

-- TODO improve this to search multiple possible local maxima
searchMax :: (Show a, Show b,  NFData b, Integral a, Ord b) =>
  [Int] -- ^ search resolution
  -> (a,a) -- ^ search domain
  ->  (a->b) -- ^ function to search
  -> a -- ^ max value
searchMax [] (mn,mx) f = if f mn > f mx then mn else mx
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
  r = if step == 1 then maxp else searchMax ns (back, front) f


-- | runs profit_t1e2
maximize_profit_t1e2 ::
  (Token t1, Token t2) =>
  Amount t1 -- ^ t1 balance on e1
  -> Amount t2 -- ^ t2 balance on e2
  -> (Amount t1 -> Amount t2) -- ^ sellt1_e1
  -> (Amount t2 -> Amount t1) -- ^ buyt1_e2
  -> (Amount t1, Amount t2) -- ^ amount t1 to sell on e1 and amount t2 to sell on e2
maximize_profit_t1e2 b_t1e1 b_t2e2 sellt1_e1 buyt1_e2 = undefined










-- | runs profit_t1e2 or profit_t2e1
{-profitMix ::
  (Token t1, Token t2, Exchange e1, Exchange e2) =>
  (Amount t1, Amount t2) -- ^ exchange 1 balance
  -> (Amount t1, Amount t2) -- ^ exchange 2 balance
  -> (Amount t1 -> Amount t2) -- ^ sellt1_e1
  -> (Amount t2 -> Amount t1) -- ^ buyt1_e2
  -> (Amount t1, Amount t2) -- ^ amount t1 to sell on e1 and amount t2 to sell on e2
profitMix (b_t1e1, b_t2e1) (b_t1e2, b_t2e2) sellt1_e1 buyt1_e2 =
-}
