{-# LANGUAGE LambdaCase #-}

module Raft
  (
    initRaft
  ) where

import           Control.Concurrent.MVar.Lifted (newMVar, readMVar)
import           Control.Distributed.Process    (Process, getSelfPid, register)
import           Control.Monad                  (forever)
import qualified Data.Vector.Unboxed            as U

import           Raft.Candidate                 (candidate)
import           Raft.Follower                  (follower)
import           Raft.Leader                    (leader)
import           Raft.Types
import           Raft.Utils                     (registerMailbox)

initRaft :: RaftParams -> Process ()
initRaft params = do
  let peers = raftPeers params
  mx <- newMVar ServerState { currTerm    = 0
                            , votedFor    = Nothing
                            , currRole    = Follower
                            , currVec     = LogVector U.empty
                            , commitIndex = 0
                            , lastApplied = 0
                            , nextIndex   = zip peers $ repeat 1
                            , matchIndex  = zip peers $ repeat 0
                            , initSeed    = Xorshift32 $ raftSeed params
                            , selfLogger  = raftLogger params
                            }
  registerMailbox mx (raftMailbox params)
  getSelfPid >>= register raftServerName
  forever $ currRole <$> readMVar mx >>= \case
    Leader    -> leader mx peers
    Candidate -> candidate mx peers
    Follower  -> follower mx
