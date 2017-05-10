module Types
  (
    NodeEndPoint(..)
  , Config(..)
  , Parameters(..)
  ) where

import           Data.Char                    (isDigit)
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
                     , msgSeed     :: Int
                     , nodeConf    :: FilePath
                     }

data Parameters = RunParams Config
                | TestParams Config NodeEndPoint
