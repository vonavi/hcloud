{-# LANGUAGE ScopedTypeVariables #-}

module Raft.RequestVote
  (
    responseVote
  , collectVotes
  ) where

import           Control.Distributed.Process (Process, match, receiveWait)

import           Raft.Types
import           Raft.Utils                  (updCurrentTerm)

responseVote :: ServerState -> RequestVoteReq -> RequestVoteRes
responseVote st req = RequestVoteRes { vresTerm    = currTerm st
                                     , voteGranted = granted
                                     }
  where granted
          | vreqTerm req < currTerm st = False
          | otherwise                  =
              case votedFor st of
                Nothing     -> True
                Just candId -> candId == vreqCandidateId req

collectVotes :: ServerState -> Int -> Process ServerState
collectVotes st 0 = return st { currRole = Leader }
collectVotes st n =
  receiveWait
  [ match $ \(res :: RequestVoteRes) -> do
      let term = vresTerm res
      case () of
        _ | term > currTerm st -> do
              let newSt = updCurrentTerm term st
              return newSt { currRole = Follower }
        _ | voteGranted res    -> collectVotes st (pred n)
        _                      -> collectVotes st n

    -- If election timeout elapses: start new election
  , match $ \(_ :: RemindTimeout) -> return st
  ]
