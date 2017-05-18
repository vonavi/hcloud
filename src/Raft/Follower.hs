{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Follower
  (
    follower
  ) where

import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (Process, exit, match,
                                                 nsendRemote, receiveWait)
import qualified Data.Vector.Unboxed            as U

import           Raft.Types
import           Raft.Utils                     (randomElectionTimeout,
                                                 remindTimeout, syncWithTerm,
                                                 whenUpdatedTerm)

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
            let term = areqTerm req
            whenUpdatedTerm mx term $
              syncWithTerm mx term >> appendEntries mx req

        , match $ \(req :: RequestVoteReq) -> do
            let term = vreqTerm req
            whenUpdatedTerm mx term $ do
              syncWithTerm mx term

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
  let idx        = prevLogIndex req
      oldLog     = U.dropWhile ((> idx) . logIndex) . getLog $ currVec st
      lastEntry  = U.head oldLog
      entries    = getLog $ areqEntries req
      result res = AppendEntriesRes { aresTerm    = currTerm st
                                    , aresSuccess = res
                                    }
  case () of
    _ | idx == 0
        -> do reply $ result True
              modifyMVar_ mx $ return . updCommits . setLog entries
    _ | not (U.null oldLog)
      , logIndex lastEntry == idx
        -> if logTerm lastEntry == prevLogTerm req
           then do reply $ result True
                   modifyMVar_ mx
                     $ return . updCommits . setLog (entries U.++ oldLog)
           else do reply $ result False
                   modifyMVar_ mx
                     $ \s -> return s { currVec = LogVector (U.tail oldLog) }
    _   -> reply $ result False
  where
    reply = nsendRemote (leaderId req) raftServerName

    setLog entries st = st { currVec = LogVector entries }

    updCommits st = st { commitIndex = n }
      where es = getLog $ currVec st
            n  = if U.null es
                 then 0
                 else min (leaderCommit req) (logIndex $ U.head es)

responseVote :: RequestVoteReq -> ServerState -> RequestVoteRes
responseVote req st = RequestVoteRes { vresTerm    = currTerm st
                                     , voteGranted = granted
                                     }
  where granted = case votedFor st of
                    Nothing     -> True
                    Just candId -> candId == vreqCandidateId req
