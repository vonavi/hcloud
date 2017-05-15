{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Follower
  (
    follower
  ) where

import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (Process, exit, match,
                                                 nsendRemote, receiveWait)

import           Raft.Types
import           Raft.Utils                     (randomElectionTimeout,
                                                 remindTimeout, updCurrentTerm)

follower :: MVar ServerState -> Process ()
follower mx = do
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindTimeout eTime

  -- Communicate if the election timer is not elapsed
  respondToServers
  exit reminder ()
    where
      respondToServers =
        receiveWait
        [ -- If election timeout elapses without receiving
          -- AppendEntries RPC form current leader or granting vote to
          -- candidate: convert to candidate.
          match $ \(_ :: RemindTimeout) ->
            modifyMVar_ mx $ \st -> return st { currRole = Candidate }

        , match $ \(req :: AppendEntriesReq) -> do
            updCurrentTerm mx (areqTerm req)
            appendEntries mx req

        , match $ \(req :: RequestVoteReq) -> do
            updCurrentTerm mx (vreqTerm req)

            response <- responseVote req <$> readMVar mx
            let candId = vreqCandidateId req
            nsendRemote candId raftServerName response
            if voteGranted response
              then modifyMVar_ mx $ \st -> return st { votedFor = Just candId }
              else respondToServers
        ]

appendEntries :: MVar ServerState -> AppendEntriesReq -> Process ()
appendEntries mx req = do
  st <- readMVar mx
  let term       = currTerm st
      idx        = prevLogIndex req
      oldLog     = dropWhile ((> idx) . logIndex) $ currLog st
      entries    = areqEntries req
      result res = AppendEntriesRes { aresTerm    = term
                                    , aresSuccess = res
                                    }
  case () of
    _ | areqTerm req < term -> reply $ result False
    _ | idx == 0            -> do
          reply $ result True
          modifyMVar_ mx $ return . updCommits . setLog entries
    _ | (e : _) <- oldLog
      , logIndex e == idx   ->
          if logTerm e == prevLogTerm req
          then do reply $ result True
                  modifyMVar_ mx
                    $ return . updCommits . setLog (entries ++ oldLog)
          else do reply $ result False
                  modifyMVar_ mx $ \s -> return s { currLog = tail oldLog }
    _                       -> reply $ result False
  where
    reply = nsendRemote (leaderId req) raftServerName

    setLog entries st = st { currLog = entries }

    updCommits st = st { commitIndex = n }
      where n = case currLog st of
                  []      -> 0
                  (e : _) -> min (leaderCommit req) (logIndex e)

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
