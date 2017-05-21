{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Candidate
  (
    candidate
  ) where

import           Control.Concurrent.MVar.Lifted           (MVar, modifyMVar_,
                                                           readMVar)
import           Control.Distributed.Process              (NodeId, Process,
                                                           exit, forward,
                                                           getSelfNode,
                                                           getSelfPid, match,
                                                           nsendRemote,
                                                           receiveWait,
                                                           spawnLocal,
                                                           wrapMessage)
import           Control.Distributed.Process.Serializable (Serializable)
import           Control.Monad                            (forM_, void)

import           Raft.Types
import           Raft.Utils                               (getLastIndex,
                                                           getLastTerm,
                                                           incCurrentTerm,
                                                           isTermStale,
                                                           randomElectionTimeout,
                                                           remindTimeout,
                                                           syncWithTerm)

candidate :: MVar ServerState -> [NodeId] -> Process ()
candidate mx peers = do
  incCurrentTerm mx
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindTimeout eTime ElectionTimeout

  -- Send RequestVote RPCs to all other servers
  void . spawnLocal . forM_ peers $ sendRequestVote mx

  collectVotes mx $ (length peers + 1) `div` 2
  exit reminder ()

sendRequestVote :: MVar ServerState -> NodeId -> Process ()
sendRequestVote mx peer = do
  st   <- readMVar mx
  node <- getSelfNode
  let stLog = currVec st
  nsendRemote peer raftServerName
    RequestVoteReq { vreqTerm        = currTerm st
                   , vreqCandidateId = node
                   , lastLogIndex    = getLastIndex stLog
                   , lastLogTerm     = getLastTerm stLog
                   }

collectVotes :: MVar ServerState -> Int -> Process ()
collectVotes mx 0 = modifyMVar_ mx $ \st -> return st { currRole = Leader }
collectVotes mx n =
  receiveWait
  [ match $ \(req :: AppendEntriesReq) -> do
      let term = areqTerm req
      unlessStepDown term req . unlessStaleTerm term
        . modifyMVar_ mx $ \st -> return st { currRole = Follower }

  , match $ \(req :: RequestVoteReq) ->
      unlessStepDown (vreqTerm req) req $ collectVotes mx n

  , match $ \(res :: AppendEntriesRes) ->
      unlessStepDown (aresTerm res) res $ collectVotes mx n

  , match $ \(res :: RequestVoteRes) -> do
      let term = vresTerm res
      unlessStepDown term res . unlessStaleTerm term
        $ if voteGranted res
          then collectVotes mx (pred n)
          else collectVotes mx n

    -- If election timeout elapses: start new election
  , match $ \(timeout :: RemindTimeout) ->
      case timeout of
        ElectionTimeout -> return ()
        _               -> collectVotes mx n
  ]
  where unlessStepDown :: forall a. Serializable a => Term -> a -> Process ()
                       -> Process ()
        unlessStepDown term msg act = do
          stepDown <- syncWithTerm mx term
          if stepDown
            then getSelfPid >>= forward (wrapMessage msg)
            else act

        unlessStaleTerm :: Term -> Process () -> Process ()
        unlessStaleTerm term act = do
          ignore <- isTermStale mx term
          if ignore then collectVotes mx n else act
