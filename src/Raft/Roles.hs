{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Roles
  (
    follower
  , candidate
  , leader
  ) where

import           Control.Concurrent.Lifted      (threadDelay)
import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (NodeId, Process, ProcessId,
                                                 exit, getSelfNode, getSelfPid,
                                                 liftIO, match, nsendRemote,
                                                 receiveWait, send, spawnLocal)
import           Data.Foldable                  (forM_)

import           Raft.AppendEntries             (appendEntries, collectCommits,
                                                 sendAppendEntries)
import           Raft.RequestVote               (collectVotes, responseVote)
import           Raft.Types
import           Raft.Utils                     (getNextIndex, incCurrentTerm,
                                                 randomElectionTimeout,
                                                 updCurrentTerm)

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

candidate :: MVar ServerState -> [NodeId] -> Process ()
candidate mx peers = do
  term     <- incCurrentTerm mx
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindTimeout eTime

  -- Send RequestVote RPCs to all other servers
  node <- getSelfNode
  forM_ peers $ \p -> nsendRemote p raftServerName
                      RequestVoteReq { vreqTerm        = term
                                     , vreqCandidateId = node
                                     }

  collectVotes mx $ (length peers + 1) `div` 2
  exit reminder ()

leader :: MVar ServerState -> [NodeId] -> Process ()
leader mx peers = do
  idx    <- getNextIndex . currLog <$> readMVar mx
  sender <- spawnLocal . forM_ peers $ \p -> sendAppendEntries mx p idx

  collectCommits mx $ (length peers + 1) `div` 2
  exit sender ()

remindTimeout :: Int -> Process ProcessId
remindTimeout micros = do
  pid <- getSelfPid
  spawnLocal $ do
    liftIO $ threadDelay micros
    send pid RemindTimeout
