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
import           System.Random               (mkStdGen)

import           Raft.Roles
import           Raft.Types

initRaft :: [NodeId] -> Int -> Process ()
initRaft peers seed =
  flip evalStateT raftInitState $ do
    lift $ getSelfPid >>= register raftServerName
    forever $ (currRole <$> get) >>= \case Follower  -> follower
                                           Candidate -> candidate peers
                                           Leader    -> leader peers
      where raftInitState = ServerState { currTerm    = 0
                                        , votedFor    = Nothing
                                        , currRole    = Follower
                                        , currLog     = []
                                        , commitIndex = 0
                                        , lastApplied = 0
                                        , nextIndex   = zip peers $ repeat 1
                                        , matchIndex  = zip peers $ repeat 0
                                        , currStdGen  = mkStdGen seed
                                        }
