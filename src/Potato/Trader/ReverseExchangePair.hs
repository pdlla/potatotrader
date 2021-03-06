-- TODO THIS FILE IS UNTESTED

{-# LANGUAGE TypeFamilies #-}

module Potato.Trader.ReverseExchangePair (
  ReverseExchangePair(..),
  ReverseOrder(..)
) where

import           Data.Proxy
import           Data.Tuple          (swap)
import           Potato.Trader.Types

data ReverseExchangePair t2 t1 e = ReverseExchangePair

instance (Exchange e) => Exchange (ReverseExchangePair t2 t1 e) where
  exchangeName _ = exchangeName (Proxy :: Proxy e)
  type ExchangePairId (ReverseExchangePair t2 t1 e) = ExchangePairId e
  type ExchangeData (ReverseExchangePair t2 t1 e) = ExchangeData e
  type ExchangeAccount (ReverseExchangePair t2 t1 e) = ExchangeAccount e

instance (ExchangeToken t1 e) => ExchangeToken t1 (ReverseExchangePair t2 t1 e) where
  symbol _ = symbol (Proxy :: Proxy (t1,e))
  getBalance _ = getBalance (Proxy :: Proxy (t1,e))

instance (ExchangeToken t2 e) => ExchangeToken t2 (ReverseExchangePair t2 t1 e) where
  symbol _ = symbol (Proxy :: Proxy (t2,e))
  getBalance _ = getBalance (Proxy :: Proxy (t2,e))

-- | wrapper to indicate order type is reversed
newtype ReverseOrder a = ReverseOrder a

flipOrderType :: OrderType -> OrderType
flipOrderType ot = if ot == Buy then Sell else Buy

instance (ExchangePair t1 t2 e) => ExchangePair t2 t1 (ReverseExchangePair t2 t1 e) where
  pairName _ = pairName (Proxy :: Proxy (t1,t2,e))
  pairId _ = pairId (Proxy :: Proxy (t1,t2,e))
  liquidity _ = do
    Liquidity t1 t2 <- liquidity (Proxy :: Proxy (t1,t2,e))
    return $ Liquidity t2 t1
  getExchangeRate _ isFee = do
    ExchangeRate sellt1' buyt1' variance' <- getExchangeRate (Proxy :: Proxy (t1,t2,e)) isFee
    return $ ExchangeRate buyt1' sellt1' (flip variance')
  type Order t2 t1 (ReverseExchangePair t2 t1 e) = ReverseOrder (Order t1 t2 e)
  getOrders _ = fmap ReverseOrder <$> getOrders (Proxy :: Proxy (t1,t2,e))
  -- | converts buy/sell orders into sell/buy orders in the original exchange
  -- TODO check work
  order :: (MonadExchange m) => Proxy (t2,t1,ReverseExchangePair t2 t1 e) -> OrderFlex -> OrderType -> Amount t2 -> Amount t1 -> ExchangeT e m (ReverseOrder (Order t1 t2 e))
  order _ ofl ot t2 t1 = ReverseOrder <$> order (Proxy :: Proxy (t1,t2,e)) ofl nt t1 t2 where
    nt = flipOrderType ot
  -- TODO pretty sure nothing needs to be done to returned OrderStatus but double check...
  getStatus _ (ReverseOrder o) = do
    OrderStatus os ot origA execA <- getStatus (Proxy :: Proxy (t1,t2,e)) o
    return $ OrderStatus os (flipOrderType ot) (swap origA) (swap execA)
  --canCancel _ (ReverseOrder o) = canCancel (Proxy :: Proxy (t1,t2,e)) o
  cancel _ (ReverseOrder o) = cancel (Proxy :: Proxy (t1,t2,e)) o
