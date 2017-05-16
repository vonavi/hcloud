module Types
  (
    NodeEndPoint(..)
  , Config(..)
  , Parameters(..)
  , NodeConfig(..)
  , receiverName
  ) where

import           Control.Distributed.Process      (NodeId)
import           Control.Distributed.Process.Node (LocalNode)
import           Data.Char                        (isDigit)
import qualified Data.Map.Strict                  as M
import           Data.Word                        (Word32)
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
                | TestParams Config

data NodeConfig = NodeConfig { stopEpts  :: [NodeEndPoint]
                             , startEpts :: [NodeEndPoint]
                             , allNodes  :: [NodeId]
                             , nodeMap   :: M.Map NodeId LocalNode
                             }

receiverName :: String
receiverName = "receiver"
