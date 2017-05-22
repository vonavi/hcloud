module Types
  (
    NodeEndPoint(..)
  , Config(..)
  , Parameters(..)
  , Connection
  , NodeConfig(..)
  ) where

import           Control.Distributed.Process      (NodeId, ProcessId)
import           Control.Distributed.Process.Node (LocalNode)
import           Data.Char                        (isDigit)
import qualified Data.Map.Strict                  as M
import           Data.Word                        (Word32)
import           Network.Transport                (Transport)
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

-- | Configuration of cluster
data Config = Config { sendPeriod  :: {-# UNPACK #-} !Int
                       -- ^ sending period, in seconds
                     , gracePeriod :: {-# UNPACK #-} !Int
                       -- ^ grace period, in seconds
                     , msgSeed     :: {-# UNPACK #-} !Word32
                       -- ^ seed value for PRNG
                     , nodeConf    :: FilePath
                       -- ^ configuration file with nodes
                     }

-- | Parameters of command targets
data Parameters = RunParams Config
                | TestParams Config

-- | Information to close a connection
type Connection = (ProcessId, LocalNode, Transport)
-- | Cluster's information to be used in test target
data NodeConfig = NodeConfig
                  { stopEpts  :: [NodeEndPoint]
                    -- ^ disconnected node endpoints
                  , startEpts :: [NodeEndPoint]
                    -- ^ connected node endpoints
                  , allNodes  :: [NodeId]
                    -- ^ all cluster's nodes
                  , nodeMap   :: M.Map NodeId Connection
                    -- ^ map connection information to nodes
                  , fileMap   :: M.Map NodeId FilePath
                    -- ^ map session files to nodes
                  }
