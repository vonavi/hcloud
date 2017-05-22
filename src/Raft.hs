{-# LANGUAGE LambdaCase #-}

module Raft
  (
    initRaft
  ) where

import           Control.Concurrent.MVar.Lifted (newMVar, readMVar)
import           Control.Distributed.Process    (NodeId (..), Process,
                                                 getSelfPid, register)
import           Control.Monad                  (forever)
import qualified Data.Map.Strict                as M
import           Network.Transport              (EndPointAddress (..))

import           Raft.Candidate                 (candidate)
import           Raft.Follower                  (follower)
import           Raft.Leader                    (leader)
import           Raft.Types
import           Raft.Utils                     (registerMailbox,
                                                 restoreSession)

initRaft :: RaftParams -> Process ()
initRaft params = do
  session <- restoreSession $ raftFile params
  let peers = raftPeers params
  mx <- newMVar ServerState { currTerm    = sessTerm session
                            , votedFor    = NodeId . EndPointAddress
                                            <$> sessVotedFor session
                            , currRole    = Follower
                            , currVec     = sessVec session
                            , commitIndex = sessCommitIdx session
                            , lastApplied = sessLastApplied session
                            , nextIndex   = M.empty
                            , matchIndex  = M.fromList $ zip peers (repeat 0)
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
