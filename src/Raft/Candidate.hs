{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Candidate
  (
    candidate
  ) where

import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (NodeId, Process, exit,
                                                 getSelfNode, match,
                                                 nsendRemote, receiveWait)
import           Control.Monad                  (void)
import           Data.Foldable                  (forM_)

import           Raft.Types
import           Raft.Utils                     (incCurrentTerm,
                                                 randomElectionTimeout,
                                                 remindTimeout, syncWithTerm)

candidate :: MVar ServerState -> [NodeId] -> Process ()
candidate mx peers = do
  term     <- incCurrentTerm mx
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindTimeout eTime ElectionTimeout

  -- Send RequestVote RPCs to all other servers
  node <- getSelfNode
  forM_ peers $ \p -> nsendRemote p raftServerName
                      RequestVoteReq { vreqTerm        = term
                                     , vreqCandidateId = node
                                     }

  collectVotes mx $ (length peers + 1) `div` 2
  exit reminder ()

collectVotes :: MVar ServerState -> Int -> Process ()
collectVotes mx 0 = modifyMVar_ mx $ \st -> return st { currRole = Leader }
collectVotes mx n =
  receiveWait
  [ -- If election timeout elapses: start new election
    match $ \(_ :: RemindTimeout) -> return ()

  , match $ \(res :: RequestVoteRes) -> do
      term <- currTerm <$> readMVar mx
      case () of
        _ | vresTerm res > term  -> void $ syncWithTerm mx (vresTerm res)
        _ | vresTerm res == term
          , voteGranted res      -> collectVotes mx (pred n)
        _                        -> collectVotes mx n
  ]
