{-# LANGUAGE DeriveGeneric #-}

module Types
  (
    NodeEndPoint(..)
  , Config(..)
  , Parameters(..)
  , StopMessage(..)
  , receiverName
  ) where

import           Data.Binary                  (Binary)
import           Data.Char                    (isDigit)
import           Data.Typeable                (Typeable)
import           Data.Word                    (Word32)
import           GHC.Generics                 (Generic)
import           Text.ParserCombinators.ReadP

type Host         = String
type Port         = String
data NodeEndPoint = NodeEndPoint { getHost :: Host
                                 , getPort :: Port
                                 }

instance Show NodeEndPoint where
  show (NodeEndPoint host port) = host ++ ":" ++ port

instance Read NodeEndPoint where
  readsPrec _ = readP_to_S
                $ NodeEndPoint <$> munch1 (/= ':') <* get <*> munch1 isDigit

data Config = Config { sendPeriod  :: Int
                     , gracePeriod :: Int
                     , msgSeed     :: Word32
                     , nodeConf    :: FilePath
                     }

data Parameters = RunParams Config
                | TestParams Config NodeEndPoint

data StopMessage = StopMessage deriving (Typeable, Generic)
instance Binary StopMessage

receiverName :: String
receiverName = "receiver"
