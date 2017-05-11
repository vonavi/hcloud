{-# LANGUAGE LambdaCase #-}

module Raft
  (
    initRaft
  ) where

import           Control.Distributed.Process (Process)
import           Control.Monad               (forever)
import           Control.Monad.Trans.State   (StateT, evalStateT, get)

import           Raft.Roles
import           Raft.Types

initRaft :: Process ()
initRaft = flip evalStateT initState . forever $ playRole
  where playRole :: StateT ServerState Process ()
        playRole = (currRole <$> get) >>= \case Follower  -> follower cfg
                                                Candidate -> candidate cfg
                                                Leader    -> leader cfg

        initState = ServerState { currTerm = 0
                                , currRole = Follower
                                }

        cfg = RaftConfig { electionTimeoutMs = 150 -- ms
                         }
