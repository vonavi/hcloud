{-# LANGUAGE LambdaCase #-}

module Raft
  (
    initRaft
  ) where

import           Control.Distributed.Process (NodeId, Process, getSelfPid,
                                              register)
import           Control.Monad               (forever)
import           Control.Monad.Trans.Class   (lift)
import           Control.Monad.Trans.State   (evalStateT, get)

import           Raft.Roles
import           Raft.Types

initRaft :: [NodeId] -> Process ()
initRaft peers = do
  flip evalStateT initState $ do
    lift $ getSelfPid >>= register raftServerName
    forever $ (currRole <$> get) >>= \case Follower  -> follower
                                           Candidate -> candidate peers
                                           Leader    -> leader peers
    where initState = ServerState { currTerm = 0
                                  , votedFor = Nothing
                                  , currRole = Follower
                                  }
