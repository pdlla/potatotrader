module Potato.Trader.Exchanges.Bilaxy.Aeson (
  BilaxyResponse(..),
  Ticker(..),
  BalanceData(..),
  BalanceDataMap(..),
  sortBalanceData,
  MarketOrder(..),
  MarketDepth(..),
  OrderStatus(..),
  toOrderState,
  OrderInfo(..),
  TradeExecResult(..),
  RateLimit(..),
)
where

import           Control.Monad             (foldM)
import           Data.Aeson
import           Data.Aeson.Types
import qualified Data.Map                  as M
import           Data.Maybe
import           Data.Text                 (Text)
import           Data.Time.Clock
import           Data.Vector               ((!))
import           Debug.Trace               (trace)
import           GHC.Generics

import qualified Potato.Trader.Types as T

lookupMany :: (FromJSON a) => Object -> [Text] -> Parser a
lookupMany v x = do
  let
    foldfn :: (FromJSON a) => Maybe a -> Text -> Parser (Maybe a)
    foldfn b s = case b of
      Nothing -> v .:? s
      found   -> return found
  found <- foldM foldfn Nothing x
  case found of
    Nothing -> error $ "found none of: " ++ show x
    Just r  -> return r


data BilaxyResponse a = BilaxyResponse {
  code     :: Int
  , brData :: a
} deriving (Show)

instance (FromJSON a) => FromJSON (BilaxyResponse a) where
  parseJSON = withObject "BilaxyResponse" $ \v -> do
    fCode :: String <- v .: "code"
    fData :: a <- v .: "data"
    return $ BilaxyResponse (read fCode) fData

data Ticker = Ticker {
  t_high   :: Double
  , t_low  :: Double
  , t_buy  :: Double
  , t_sell :: Double
  , t_last :: Double
  , t_vol  :: Double
} deriving (Show)

instance FromJSON Ticker where
  parseJSON = withObject "Ticker" $ \v -> do
    high :: String <- v .: "high"
    low :: String  <- v .: "low"
    buy :: String <- v .: "buy"
    sell :: String <- v .: "sell"
    fLast :: String <- v .: "last"
    vol :: String <- v .: "vol"
    return $ Ticker (read high) (read low) (read buy) (read sell) (read fLast) (read vol)


data BalanceData = BalanceData {
  symbol    :: Int
  , balance :: Double
  , name    :: String
  , frozen  :: Double
} deriving (Generic, Show)

type BalanceDataMap = M.Map String BalanceData

sortBalanceData :: [BalanceData] -> BalanceDataMap
sortBalanceData = foldl (\m bd -> M.insert (name bd) bd m) M.empty

instance FromJSON BalanceData where
  parseJSON = withObject "BalanceData" $ \v -> do
    fSymbol :: Int <- v .: "symbol"
    fBalance :: String <- v .: "balance"
    fName :: String <- v .: "name"
    fFrozen :: String <- v .: "frozen"
    return $ BalanceData fSymbol (read fBalance) fName (read fFrozen)

data MarketOrder = MarketOrder {
  price    :: Double
  , volume :: Double
  , total  :: Double
} deriving (Generic, Show)

instance FromJSON MarketOrder where
  parseJSON = withArray "MarketOrder" $ \v' -> do
    let v = fmap parseJSON v'
    MarketOrder <$> (v ! 0) <*> (v ! 1) <*> (v ! 2)

instance ToJSON MarketOrder where
  toEncoding (MarketOrder p v t) = toEncoding [p,v,t]

data MarketDepth = MarketDepth {
  asks   :: [MarketOrder]
  , bids :: [MarketOrder]
} deriving (Generic, Show)

instance FromJSON MarketDepth
instance ToJSON MarketDepth

data OrderStatus = NotTradedYet | TradedPartly | TradedCompletely | Cancelled deriving (Eq, Show)
instance FromJSON OrderStatus where
  parseJSON = withScientific "OrderStatus" $ \n -> return $ case n of
    1 -> NotTradedYet
    2 -> TradedPartly
    3 -> TradedCompletely
    4 -> Cancelled
    _ -> error $ "unknown status " ++ show n

toOrderState :: OrderStatus -> T.OrderState
toOrderState NotTradedYet     = T.Pending
toOrderState TradedPartly     = T.PartiallyExecuted
toOrderState TradedCompletely = T.Executed
toOrderState Cancelled        = T.Cancelled

-- e.g. for Bilaxy TT/USDT pair, TT is the security token, USDT is the base token
-- price is in USDT
-- amount refers to USDT, count refers to TT
data OrderInfo = OrderInfo {
  oi_datetime      :: ()
  , oi_amount      :: Double -- amount of base token to sell/buy
  , oi_price       :: Double
  , oi_count       :: Double -- count in security tokens to buy/sell
  , oi_symbol      :: Int
  , oi_id          :: Int
  , oi_left_amount :: Double -- amount of order that is unexecuted
  , oi_left_count  :: Double -- amount of base tokens that is unexecuted
  , oi_type        :: T.OrderType
  , oi_status      :: OrderStatus
} deriving (Generic, Show)

instance FromJSON OrderInfo where
  parseJSON = withObject "OrderInfo" $ \v -> do
    -- TODO fix serialization
    --fDatetime :: UTCTime <- v .: "datetime"
    fAmount :: String <- v .: "amount"
    fPrice :: String <- v .: "price"
    fCount :: String <- v .: "count"
    fId :: Int <- v .: "id"
    fLeft_amount :: String <- v .: "left_amount"
    fLeft_count :: String <- v .: "left_count"
    fType :: String <- v .: "type"
    -- TODO make instance FromJSON T.OrderType
    fStatus :: OrderStatus <- v .: "status"
    fSymbol :: Int <- lookupMany v ["symbo", "symbol"] -- typo in API
    return $ OrderInfo {
      --oi_datetime = fDatetime
      oi_datetime = ()
      , oi_amount = read fAmount
      , oi_price = read fPrice
      , oi_count = read fCount
      , oi_symbol = fSymbol
      , oi_id = fId
      , oi_left_amount = read fLeft_amount
      , oi_left_count = read fLeft_count
      , oi_type = if fType == "sell" then T.Sell else T.Buy
      , oi_status = fStatus
    }

data TradeExecResult = TradeExecResult {
  ter_resultCode :: Int
  , ter_id       :: Int
} deriving (Show)

instance FromJSON TradeExecResult where
  parseJSON = withObject "TradeExecResult" $ \v -> do
    fResultCode :: Int <- v .: "resultCode"
    fId :: Int <- v .: "id"
    return $ TradeExecResult fResultCode fId

-- TODO parse interval into units of time
data RateLimit = RateLimit {
  interval    :: String
  , max_times :: Int
} deriving (Show, Generic)

instance FromJSON RateLimit
