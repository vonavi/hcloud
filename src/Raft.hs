{-# LANGUAGE LambdaCase #-}

module Raft
  (
    initRaft
  ) where

import           Control.Concurrent.MVar.Lifted (newMVar, readMVar)
import           Control.Distributed.Process    (Process, getSelfPid, register)
import           Control.Monad                  (forever)

import           Raft.Candidate                 (candidate)
import           Raft.Follower                  (follower)
import           Raft.Leader                    (leader)
import           Raft.Types
import           Raft.Utils                     (registerMailbox,
                                                 restoreSession)

initRaft :: RaftParams -> Process ()
initRaft params = do
  (term, voted, logs) <- restoreSession $ raftFile params
  let peers = raftPeers params
  mx <- newMVar ServerState { currTerm    = term
                            , votedFor    = voted
                            , currRole    = Follower
                            , currVec     = logs
                            , commitIndex = 0
                            , lastApplied = 0
                            , nextIndex   = []
                            , matchIndex  = zip peers $ repeat 0
                            , initSeed    = Xorshift32 $ raftSeed params
                            , sessionFile = raftFile params
                            , selfLogger  = raftLogger params
                            }
  registerMailbox mx (raftMailbox params)
  getSelfPid >>= register raftServerName
  forever $ currRole <$> readMVar mx >>= \case
    Leader    -> leader mx peers
    Candidate -> candidate mx peers
    Follower  -> follower mx
