{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Follower
  (
    follower
  ) where

import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (Process, exit, getSelfNode,
                                                 match, nsendRemote,
                                                 receiveWait)
import           Control.Monad                  (unless, void, when)
import           Data.Monoid                    ((<>))
import qualified Data.Vector.Unboxed            as U

import           Raft.Types
import           Raft.Utils                     (getLastIndex, getLastTerm,
                                                 getMatchIndex, isTermStale,
                                                 randomElectionTimeout,
                                                 remindTimeout, saveSession,
                                                 syncWithTerm, writeLogger)

follower :: MVar ServerState -> Process ()
follower mx = do
  writeLogger mx "Hi!"
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindTimeout eTime ElectionTimeout

  -- Communicate if the election timer is not elapsed
  respondToServers mx
  exit reminder ()

respondToServers :: MVar ServerState -> Process ()
respondToServers mx =
  receiveWait
  [ match $ \(req :: AppendEntriesReq) -> do
      writeLogger mx $ "received AppendEntriesReq from "
        ++ show (leaderId req) ++ " Term " ++ show (areqTerm req)
      let term = areqTerm req
      void $ syncWithTerm mx term
      unlessStaleTerm term $ do
        success <- appendEntries mx req
        when (success && (not . U.null . getLog $ areqEntries req))
          $ saveSession mx

        st   <- readMVar mx
        node <- getSelfNode
        nsendRemote (leaderId req) raftServerName
          AppendEntriesRes { aresTerm       = currTerm st
                           , aresSuccess    = success
                           , aresFollowerId = node
                           , aresMatchIndex = getMatchIndex $ currVec st
                           }

  , match $ \(req :: RequestVoteReq) -> do
      writeLogger mx $ "received RequestVoteReq from "
        ++ show (vreqCandidateId req) ++ " Term " ++ show (vreqTerm req)
      let term = vreqTerm req
      void $ syncWithTerm mx term
      unlessStaleTerm term $ do
        success <- voteForCandidate mx req
        writeLogger mx
          $ if success
            then "giving a vote for " ++ show (vreqCandidateId req)
            else "giving no vote for " ++ show (vreqCandidateId req)

        stTerm <- currTerm <$> readMVar mx
        nsendRemote (vreqCandidateId req) raftServerName
          RequestVoteRes { vresTerm    = stTerm
                         , voteGranted = success
                         }
        unless success $ respondToServers mx

  , match $ \(res :: AppendEntriesRes) -> do
      writeLogger mx $ "received AppendEntriesRes from "
        ++ show (aresFollowerId res) ++ " Term " ++ show (aresTerm res)
      respondToServers mx

  , match $ \(res :: RequestVoteRes) -> do
      writeLogger mx
        $ "received RequestVoteRes from Term " ++ show (vresTerm res)
      respondToServers mx

    -- If election timeout elapses without receiving AppendEntries RPC
    -- form current leader or granting vote to candidate: convert to
    -- candidate.
  , match $ \(timeout :: RemindTimeout) ->
      case timeout of
        ElectionTimeout -> modifyMVar_ mx
                           $ \st -> return st { currRole = Candidate }
        _               -> respondToServers mx

  ]
  where unlessStaleTerm :: Term -> Process () -> Process ()
        unlessStaleTerm term act = do
          ignore <- isTermStale mx term
          if ignore then respondToServers mx else act

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
  st <- readMVar mx
  let candId    = vreqCandidateId req
      freeVote  = case votedFor st of
                    Nothing -> True
                    Just c  -> c == candId
      stLog     = currVec st
      lastIndex = getLastIndex stLog
      lastTerm  = getLastTerm stLog
      cmpLogs   = compare (lastLogTerm req) lastTerm
                  <> compare (lastLogIndex req) lastIndex
  case () of
    _ | not freeVote  -> return False
    _ | LT <- cmpLogs -> return False
    _                 -> do modifyMVar_ mx
                              $ \s -> return s { votedFor = Just candId }
                            return True
