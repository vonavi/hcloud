{-# LANGUAGE LambdaCase #-}

module Raft
  (
    initRaft
  ) where

import           Control.Distributed.Process (NodeId, Process, getSelfNode,
                                              getSelfPid, register)
import           Control.Monad               (forever)
import           Control.Monad.Trans.Class   (lift)
import           Control.Monad.Trans.State   (evalStateT, get)

import           Raft.Roles
import           Raft.Types

initRaft :: [NodeId] -> Process ()
initRaft peers = do
  node <- getSelfNode
  let initState = ServerState { currTerm = 0
                              , votedFor = Nothing
                              , currRole = FollowerOf node
                              }
  flip evalStateT initState $ do
    lift $ getSelfPid >>= register raftServerName
    forever $ (currRole <$> get) >>= \case FollowerOf _ -> follower
                                           Candidate    -> candidate peers
                                           Leader       -> leader peers
