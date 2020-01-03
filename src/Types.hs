{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies               #-}

module Types (
  Amount(..),
  Liquidity(..),
  OrderType(..),

  Token(..),
  Exchange(..),
  ExchangeToken(..),
  ExchangePair(..),
  OrderState(..),
  OrderStatus(..),
  Order,

  TT(..),
  ETH(..),
  USDT(..)
) where

import           Data.Proxy
import           Data.Solidity.Prim.Address (Address)

newtype Amount t = Amount Integer deriving (Eq, Ord, Num, Show, Read, Enum, Real, Integral)
data Liquidity t1 t2 = Liquidity (Amount t1) (Amount t2)
data OrderType = Buy | Sell deriving (Show)


class Token t where
  tokenName :: Proxy t -> String

class Exchange e where
  exchangeName :: Proxy e -> String
  data ExchangePairId e :: *
  -- TODO something like this? However, we either need to use mutable cache (doable since everything we need it for is IO) or have all types return the cache as well
  -- data ExchangeCache :: *
  -- TODO generalize account access to the exchange
  -- data ExchangeAccount e :: *

class (Token t, Exchange e) => ExchangeToken t e where
  -- TODO probably don't need this, it's encapsulated by getBalance
  -- symbol of token on the exchange
  symbol :: Proxy (t,e) -> String
  symbol _ = tokenName (Proxy :: Proxy t)
  -- TODO probably don't need this, it's encapsulated by getBalance
  -- multiply by this to normalize
  decimals :: Proxy (t,e) -> Integer
  decimals _ = 1
  -- get balance (normalized)
  getBalance :: Proxy (t,e) -> IO (Amount t)


data OrderState = Pending | PartiallyExecuted | Executed | Cancelled | Missing deriving (Show)
data OrderStatus = OrderStatus {
  orderState :: OrderState
}

-- maybe simpler way to do type level exchange pairs
class (ExchangeToken t1 e, ExchangeToken t2 e) => ExchangePair t1 t2 e where
  pairName :: Proxy (t1,t2,e) -> String
  pairName _ =
    exchangeName (Proxy :: Proxy e) ++ " "
    ++ tokenName (Proxy :: Proxy t1) ++ ":"
    ++ tokenName (Proxy :: Proxy t2)

  -- | pairID returns a String identifier
  pairId :: Proxy (t1,t2,e) -> ExchangePairId e

  -- | liquidity returns your respective balance in the two tokens
  -- TODO is this the right name for it?
  liquidity :: Proxy (t1,t2,e) -> IO (Liquidity t1 t2)
  liquidity _ = do
    b1 <- getBalance (Proxy :: Proxy (t1, e))
    b2 <- getBalance (Proxy :: Proxy (t2, e))
    return $ Liquidity b1 b2

  data Order t1 t2 e :: *
  -- | order buys t1 for t2 tokens OR sells t1 for t2 tokens
  order :: OrderType -> Amount t1 -> Amount t2 -> IO (Order t1 t2 e)
  getStatus :: Order t1 t2 e -> IO OrderStatus
  canCancel :: Order t1 t2 e -> Bool -- or is this a method of OrderStatus?
  cancel :: Order t1 t2 e -> IO Bool
  cancel = undefined







-- TODO maybe move to a diff file
-- tokens
data TT
data ETH
data USDT

instance Token TT where
  tokenName _ = "TT"

instance Token ETH where
  tokenName _ = "ETH"

instance Token USDT where
  tokenName _ = "USDT"




-- below is a WIP, lots of typing issues go away
{-
class (Token t1, Token t2) => ExchangePair t1 t2 e where
  getLiquidity :: e -> IO (Liquidity t1 t2)

data TokenExchange t1 t2 where
  TokenExchange :: (ExchangeToken t1 e1, ExchangeToken t2 e2) => TokenExchange t1 t2

instance (ExchangeToken t1 e1, ExchangeToken t2 e2) => ExchangePair t1 t2 (TokenExchange t1 t2) where
  getLiquidity :: TokenExchange t1 t2 -> IO (Liquidity t1 t2)
  getLiquidity _ = do
    b1 <- getBalance (Proxy :: Proxy (t1, e1))
    b2 <- getBalance (Proxy :: Proxy (t2, e2))
    return $ Liquidity b1 b2


data ExchangeExchange t1 t2 t3 where
  ExchangeExchange :: (ExchangePair t1 t2 e12, ExchangePair t2 t3 e23) => e12 -> e23 -> ExchangeExchange t1 t2 t3

-- broken due to GADTs not carrying scope on their type variables
-- (so the t1 t2 t3 in "data ExchangeExchange t1 t2 t3" do not match the t1 t2 t3 in th ctor)
instance (Token t1, Token t2, Token t3) => ExchangePair t1 t3 (ExchangeExchange t1 t2 t3) where
  -- this is hard because need to query exchange rate to convert t2 balance into liquidity
  -- for now, ignore t2 balance
  getLiquidity :: ExchangeExchange t1 t2 t3 -> IO (Liquidity t1 t3)
  getLiquidity (ExchangeExchange e12 e23) = do
    Liquidity l1 _ <- getLiquidity e12
    Liquidity _ l3 <- getLiquidity e23
    return $ Liquidity l1 l3
-}
