module Raft.Roles
  (
    follower
  , candidate
  , leader
  ) where

import           Control.Concurrent          (threadDelay)
import           Control.Distributed.Process (Process, liftIO, say)
import           Control.Monad.Trans.Class   (lift)
import           Control.Monad.Trans.State   (StateT)

import           Raft.Types

follower :: RaftConfig -> StateT ServerState Process ()
follower _ = lift $ do say "I'm a follower."
                       liftIO $ threadDelay 1000000

candidate :: RaftConfig -> StateT ServerState Process ()
candidate _ = lift $ do say "I'm a candidate."
                        liftIO $ threadDelay 1000000

leader :: RaftConfig -> StateT ServerState Process ()
leader _ = lift $ do say "I'm the leader."
                     liftIO $ threadDelay 1000000
