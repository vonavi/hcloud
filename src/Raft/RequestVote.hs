{-# LANGUAGE ScopedTypeVariables #-}

module Raft.RequestVote
  (
    responseVote
  , collectVotes
  ) where

import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (Process, match, receiveWait)

import           Raft.Types
import           Raft.Utils                     (updCurrentTerm)

responseVote :: RequestVoteReq -> ServerState -> RequestVoteRes
responseVote req st = RequestVoteRes { vresTerm    = currTerm st
                                     , voteGranted = granted
                                     }
  where granted
          | vreqTerm req < currTerm st = False
          | otherwise                  =
              case votedFor st of
                Nothing     -> True
                Just candId -> candId == vreqCandidateId req

collectVotes :: MVar ServerState -> Int -> Process ()
collectVotes mx 0 = modifyMVar_ mx $ \st -> return st { currRole = Leader }
collectVotes mx n =
  receiveWait
  [ -- If election timeout elapses: start new election
    match $ \(_ :: RemindTimeout) -> return ()

  , match $ \(res :: RequestVoteRes) -> do
      term <- currTerm <$> readMVar mx
      case () of
        _ | vresTerm res > term -> do
              updCurrentTerm mx (vresTerm res)
              modifyMVar_ mx $ \st -> return st { currRole = Follower }
        _ | voteGranted res    -> collectVotes mx (pred n)
        _                      -> collectVotes mx n
  ]
