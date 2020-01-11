{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TypeFamilies    #-}

module Exchanges.Bilaxy.Exchange (
  Bilaxy(..),
  BilaxyCtx,
  BilaxyOrderDetails(..)
) where

import           Control.Exception
import           Control.Monad.IO.Class
import           Data.List              (mapAccumL)
import           Data.Proxy
import qualified Exchanges.Bilaxy.Aeson as BA
import           Exchanges.Bilaxy.Query
import           Types


class (Token t1, Token t2) => RealBilaxyPair t1 t2 where
  getPairId :: Proxy t1 -> Proxy t2 -> Int

instance RealBilaxyPair TT USDT where
  getPairId _ _ = 151

-- | Bilaxy exchange type
data Bilaxy

-- | `ExchangeCtx Bilaxy` types
type BilaxyAccount = ()
type BilaxyCache = ()
type BilaxyCtx = (BilaxyCache, BilaxyAccount)

instance Exchange Bilaxy where
  exchangeName _ = "Bilaxy"
  type ExchangePairId Bilaxy = Int
  type ExchangeCache Bilaxy = BilaxyCache
  type ExchangeAccount Bilaxy = BilaxyAccount

-- | Bilaxy exchange type where trading pairs are flipped
data BilaxyFlip

instance Exchange BilaxyFlip where
  exchangeName _ = "Bilaxy (flipped pairs)"
  type ExchangePairId BilaxyFlip = Int
  type ExchangeCache BilaxyFlip = BilaxyCache
  type ExchangeAccount BilaxyFlip = BilaxyAccount

-- | exchange helper method for getting balance
getBalanceHelper :: forall t e m. (MonadExchange m, ExchangeToken t e) => Proxy (t,e) -> ExchangeT e m (Amount t)
getBalanceHelper p = do
  b <- liftIO $ getBalanceOf $ symbol p
  return . Amount . floor $ fromIntegral (decimals (Proxy :: Proxy t)) * b

-- | Token types
instance ExchangeToken TT Bilaxy where
  getBalance = getBalanceHelper

instance ExchangeToken USDT Bilaxy where
  getBalance = getBalanceHelper

instance ExchangeToken TT BilaxyFlip where
  getBalance = getBalanceHelper

instance ExchangeToken USDT BilaxyFlip where
  getBalance = getBalanceHelper

-- | `Order t1 t2 Bilaxy` type
data BilaxyOrderDetails = BilaxyOrderDetails {
  orderId :: Int
} deriving (Show)

-- | ExchangePair helper methods for generating ExchangeRate functions
-- exported for testing purposes

-- | takes a list of market order bids for t1 (in base denomination)
-- (people trying to buy t1 using t2)
-- and creates the sellt1 function that shows how much t2 can be obtained from selling a given quantity t1
make_sellt1 :: [(Amount t2, Amount t1)] -> Amount t1 -> Amount t2
make_sellt1 bids (Amount t1) = Amount r where
  myFunc :: Integer -> (Amount t2, Amount t1) -> (Integer, Integer)
  myFunc remainingt1 (Amount price, Amount volume) = (remainingt1-paidt1, boughtt2) where
    boughtt2 = min (remainingt1 * price) volume
    paidt1 = boughtt2 `div` price
  (remaining, boughtt2Array) = mapAccumL myFunc t1 bids
  -- TODO log a warning if remaining > 0 (means we bought the whole market and had some left over)
  boughtt2Executed = takeWhile (> 0) boughtt2Array
  r = sum boughtt2Executed

-- TODO extra test this one...
-- | takes a list of market order asks for t1 (in base denomination)
-- (people trying to sell t2 for t1)
-- and creates the buyt1 function that shows how much t1 can be bought for a given quantity of t2
make_buyt1 :: [(Amount t2, Amount t1)] -> Amount t2 -> Amount t1
make_buyt1 bids (Amount t2) = Amount r where
  myFunc :: Integer -> (Amount t2, Amount t1) -> (Integer, Integer)
  myFunc remainingt2 (Amount price, Amount volume) = (remainingt2-paidt2, boughtt1) where
    boughtt1 = min (remainingt2 * price) volume
    paidt2 = boughtt1 `div` price
  (remaining, boughtt1Array) = mapAccumL myFunc t2 bids
  -- TODO log a warning if remaining > 0 (means we bought the whole market and had some left over)
  boughtt1Executed = takeWhile (> 0) boughtt1Array
  r = sum boughtt1Executed

type BilaxyExchangePairConstraints t1 t2 = (RealBilaxyPair t1 t2, ExchangeToken t1 Bilaxy, ExchangeToken t2 Bilaxy)
instance BilaxyExchangePairConstraints t1 t2 => ExchangePair t1 t2 Bilaxy where
  pairId _ = getPairId (Proxy :: Proxy t1) (Proxy :: Proxy t2)

  -- TODO finish... Could include exchange pair id but it's encoded in the type so idk :\
  type Order t1 t2 Bilaxy = BilaxyOrderDetails

  getStatus _ (BilaxyOrderDetails oid) = do
    v <- liftIO $ try (getOrderInfo oid)
    case v of
      Left (SomeException _) -> return $ OrderStatus Missing
      Right oi               -> return . OrderStatus . BA.toOrderState . BA.oi_status $ oi

  canCancel _ _ = True

  cancel _ (BilaxyOrderDetails oid) = do
    v <- liftIO $ try (cancelOrder oid)
    case v of
      Left (SomeException _) -> return False
      Right oi               -> return True

  getOrders _ = do
    orders <- liftIO $ getOrderList $ pairId (Proxy :: Proxy (t1,t2,Bilaxy))
    return $ map (BilaxyOrderDetails . BA.oi_id) orders

  order _ ot (Amount t1) (Amount t2) = do
    let
      t1proxy = Proxy :: Proxy t1
      t2proxy = Proxy :: Proxy t2
      pproxy = Proxy :: Proxy (t1, t2, Bilaxy)
      amount_t1 = fromIntegral t1 / fromIntegral (decimals t1proxy)
      amount_t2 = fromIntegral t2 / fromIntegral (decimals t2proxy)
      price_t2 = amount_t2 / amount_t1
      pair = pairId pproxy
    v <- liftIO $ try (postOrder pair amount_t1 amount_t2 ot)
    case v of
      Left (SomeException e) -> do
        liftIO $ print e
        return undefined
      Right oid              -> return $ BilaxyOrderDetails oid

  getExchangeRate pproxy = do
    let
      pair = pairId pproxy
    depth <- liftIO $ getDepth pair
    let
      t1d = fromInteger $ decimals (Proxy :: Proxy t1)
      t2d = fromInteger $ decimals (Proxy :: Proxy t2)
      fixDecimals = map (\(BA.MarketOrder p v _) -> (Amount . ceiling $ p*t2d :: Amount t2, Amount . floor $ v*t1d :: Amount t1))
      -- price is always in t2, volume in t1
      -- asks are people trying to sell t2 for t1
      asks = fixDecimals $ BA.asks depth
      -- bids are people trying to buy t2 with t1
      bids = fixDecimals $ BA.bids depth
    let
      buyt1 (Amount t2) = Amount $ 0
      variance = undefined
    return $ ExchangeRate (make_sellt1 bids) (make_buyt1 asks) variance

flipProxy :: Proxy (t1, t2, BilaxyFlip) -> Proxy (t2, t1, Bilaxy)
flipProxy _ = Proxy

-- current implementation depends on ExchangePair t2 t1 Bilaxy and hence extra constraints
type BilaxyFlipExchangePairConstraints t1 t2 = (
  RealBilaxyPair t2 t1,
  ExchangeToken t1 BilaxyFlip,
  ExchangeToken t2 BilaxyFlip,
  ExchangeToken t1 Bilaxy,
  ExchangeToken t2 Bilaxy
  )

-- |
-- UNTESTED
instance (BilaxyFlipExchangePairConstraints t1 t2) => ExchangePair t1 t2 BilaxyFlip where
  -- uses same pairId as unflipped version
  pairId _ = getPairId (Proxy :: Proxy t2) (Proxy :: Proxy t1)

  type Order t1 t2 BilaxyFlip = BilaxyOrderDetails

  getStatus p = getStatus (flipProxy p)

  canCancel p = canCancel (flipProxy p)

  cancel p = cancel (flipProxy p)

  -- Note that this returns Bilaxy (not flip) orders too
  getOrders _ = do
    orders <- liftIO $ getOrderList $ pairId (Proxy :: Proxy (t1, t2, BilaxyFlip))
    return $ map (BilaxyOrderDetails . BA.oi_id) orders

  order _ ot (Amount t1) (Amount t2) = do
    let
      t1proxy = Proxy :: Proxy t1
      t2proxy = Proxy :: Proxy t2
      pproxy = Proxy :: Proxy (t2, t1, Bilaxy)
      amount_t1 = fromIntegral t1 / fromIntegral (decimals t1proxy)
      amount_t2 = fromIntegral t2 / fromIntegral (decimals t2proxy)
      price_t2 = amount_t2 / amount_t1
      pair = pairId pproxy
      ot' = if ot == Buy then Sell else Buy
    v <- liftIO $ try (postOrder pair amount_t2 amount_t1 ot)
    case v of
      Left (SomeException e) -> do
        liftIO $ print e
        return undefined
      Right oid              -> return $ BilaxyOrderDetails oid

  -- TODO test, not totally sure it's correct...
  getExchangeRate _ = do
    er <- getExchangeRate (Proxy :: Proxy (t2,t1,Bilaxy))
    return $ ExchangeRate (buyt1 er) (sellt1 er) (flip $ variance er)
