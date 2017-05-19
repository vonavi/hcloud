{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Follower
  (
    follower
  ) where

import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (Process, exit, match,
                                                 nsendRemote, receiveWait)
import           Control.Monad                  (unless, when)
import qualified Data.Vector.Unboxed            as U

import           Raft.Types
import           Raft.Utils                     (randomElectionTimeout,
                                                 remindTimeout, saveSession,
                                                 syncWithTerm, whenUpdatedTerm)

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
            whenUpdatedTerm mx term $ do
              syncWithTerm mx term
              success <- appendEntries mx req
              saveSession mx
              stTerm <- currTerm <$> readMVar mx
              nsendRemote (leaderId req) raftServerName
                AppendEntriesRes { aresTerm    = stTerm
                                 , aresSuccess = success
                                 }

        , match $ \(req :: RequestVoteReq) -> do
            let term = vreqTerm req
            whenUpdatedTerm mx term $ do
              syncWithTerm mx term
              success <- voteForCandidate mx req
              saveSession mx
              stTerm <- currTerm <$> readMVar mx
              nsendRemote (vreqCandidateId req) raftServerName
                RequestVoteRes { vresTerm    = stTerm
                               , voteGranted = success
                               }
              unless success respondToServers
        ]

appendEntries :: MVar ServerState -> AppendEntriesReq -> Process Bool
appendEntries mx req = do
  st <- readMVar mx
  let idx       = prevLogIndex req
      oldLog    = U.dropWhile ((> idx) . logIndex) . getLog $ currVec st
      lastEntry = U.head oldLog
      entries   = getLog $ areqEntries req
  case () of
    _ | idx == 0
        -> do modifyMVar_ mx $ return . updCommits . setLog entries
              return True
    _ | not (U.null oldLog)
      , logIndex lastEntry == idx
        -> if logTerm lastEntry == prevLogTerm req
           then do modifyMVar_ mx
                     $ return . updCommits . setLog (entries U.++ oldLog)
                   return True
           else do modifyMVar_ mx
                     $ \s -> return s { currVec = LogVector (U.tail oldLog) }
                   return False
    _   -> return False
  where
    setLog entries st = st { currVec = LogVector entries }

    updCommits st = st { commitIndex = n }
      where es = getLog $ currVec st
            n  = if U.null es
                 then 0
                 else min (leaderCommit req) (logIndex $ U.head es)

voteForCandidate :: MVar ServerState -> RequestVoteReq -> Process Bool
voteForCandidate mx req = do
  voted <- votedFor <$> readMVar mx
  let candId  = vreqCandidateId req
      granted = case voted of
                  Nothing -> True
                  Just c  -> c == candId
  when granted . modifyMVar_ mx
    $ \st -> return st { votedFor = Just candId }
  return granted
