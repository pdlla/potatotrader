{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TypeFamilies    #-}

module Potato.CryptoTrader.Exchanges.Bilaxy.Exchange (
  RealBilaxyPair(..),
  Bilaxy(..),
  BilaxyCache,
  BilaxyAccount,
  BilaxyCtx,
  BilaxyOrderDetails(..)
) where

import           Control.Exception
import           Control.Monad.IO.Class
import           Data.List                                  (mapAccumL)
import           Data.Proxy
import qualified Potato.CryptoTrader.Exchanges.Bilaxy.Aeson as BA
import           Potato.CryptoTrader.Exchanges.Bilaxy.Query
import           Potato.CryptoTrader.Helpers
import           Potato.CryptoTrader.Types

import           Debug.Trace

-- | class represents a real trading pair on bilaxy exchange
-- (as oppose to derived one i.e. with FlipExchange)
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

-- | `Order t1 t2 Bilaxy` type
data BilaxyOrderDetails = BilaxyOrderDetails {
  orderId :: Int
} deriving (Show)


type BilaxyExchangePairConstraints t1 t2 = (RealBilaxyPair t1 t2, ExchangeToken t1 Bilaxy, ExchangeToken t2 Bilaxy)

getDepthHelper ::
  forall t1 t2 m. (BilaxyExchangePairConstraints t1 t2, MonadExchange m)
  => Proxy (t1, t2, Bilaxy)
  -> m ([(AmountRatio t2 t1, Amount t1)],[(AmountRatio t2 t1, Amount t1)]) -- ^ (asks, bids)
getDepthHelper pproxy = do
  depth <- liftIO $ getDepth (pairId pproxy)
  let
    t1d = fromInteger $ decimals (Proxy :: Proxy t1)
    t2d = fromInteger $ decimals (Proxy :: Proxy t2)
    fixDecimals = map (\(BA.MarketOrder p v _) -> (AmountRatio $ p*t2d/t1d, Amount . floor $ v*t1d :: Amount t1))
    -- asks are people trying to sell t1 for t2
    -- bids are people trying to buy t1 with t2
    -- price is always in t2, volume in t1
    -- in this case t1 is the token being traded, and t2 is the base token
    -- TODO/NOTE I'm unsure if this interpretation is consistent accross all trading pairs. I only checked for TT/USDT
    asks = fixDecimals $ BA.asks depth
    bids = fixDecimals $ BA.bids depth
  return (asks, bids)

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

  order pproxy ot (Amount t1) (Amount t2) = do
    er <- getExchangeRate pproxy
    let
      t1proxy = Proxy :: Proxy t1
      t2proxy = Proxy :: Proxy t2
      pair = pairId pproxy
      pvpairs = case ot of
        -- buying t1 with t2
        Buy  -> undefined
        -- selling t1 for t2
        Sell -> undefined
    v <- undefined
    --v <- liftIO $ try (postOrder pair amount_t1 price_t2 ot)
    case v of
      Left (SomeException e) -> do
        liftIO $ print e
        return undefined
      Right oid              -> return $ BilaxyOrderDetails oid

  getExchangeRate pproxy = do
    (asks, bids) <- getDepthHelper pproxy
    let
      sellt1 = make_sellt1_from_bidst1 bids
      buyt1 = make_buyt1_from_askst1 asks
      variance = undefined
    return $ ExchangeRate sellt1 buyt1 variance
