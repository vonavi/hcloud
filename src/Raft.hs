{-# LANGUAGE LambdaCase #-}

module Raft
  (
    initRaft
  ) where

import           Control.Concurrent.Chan        (Chan)
import           Control.Concurrent.MVar.Lifted (newMVar, readMVar)
import           Control.Distributed.Process    (NodeId, Process, getSelfPid,
                                                 register)
import           Control.Monad                  (forever)
import           Data.Word                      (Word32)

import           Raft.Candidate                 (candidate)
import           Raft.Follower                  (follower)
import           Raft.Leader                    (leader)
import           Raft.Types

initRaft :: [NodeId] -> Word32 -> Chan String -> Process ()
initRaft peers seed logs = do
  mx <- newMVar ServerState { currTerm    = 0
                            , votedFor    = Nothing
                            , currRole    = Follower
                            , currLog     = []
                            , commitIndex = 0
                            , lastApplied = 0
                            , nextIndex   = zip peers $ repeat 1
                            , matchIndex  = zip peers $ repeat 0
                            , initSeed    = Xorshift32 seed
                            , raftLogger  = logs
                            }
  getSelfPid >>= register raftServerName
  forever $ currRole <$> readMVar mx >>= \case
    Leader    -> leader mx peers
    Candidate -> candidate mx peers
    Follower  -> follower mx
