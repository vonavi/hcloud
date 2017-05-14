{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Roles
  (
    follower
  , candidate
  , leader
  ) where

import           Control.Concurrent          (threadDelay)
import           Control.Distributed.Process (NodeId, Process, ProcessId, exit,
                                              getSelfNode, getSelfPid, liftIO,
                                              match, nsendRemote, receiveWait,
                                              send, spawnLocal)
import           Control.Monad               (forM_)
import           Control.Monad.Trans.State   (StateT (..))

import           Raft.AppendEntries          (appendEntries, collectCommits,
                                              sendAppendEntries)
import           Raft.RequestVote            (collectVotes, responseVote)
import           Raft.Types
import           Raft.Utils                  (getNextIndex, incCurrentTerm,
                                              randomElectionTimeout,
                                              updCurrentTerm)

follower :: StateT ServerState Process ()
follower = StateT $ \currState -> do
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindTimeout eTime

  -- Communicate if the election timer is not elapsed
  nextState <- respondToServers currState
  exit reminder ()
  return ((), nextState)
    where
      respondToServers :: ServerState -> Process ServerState
      respondToServers st =
        receiveWait [ match $ \(req :: AppendEntriesReq)
                              -> appendEntries req
                                 . updCurrentTerm (areqTerm req) $ st

                    , match $ \(req :: RequestVoteReq) -> do
                        -- Update the current term
                        let newSt = updCurrentTerm (vreqTerm req) st

                        let candId   = vreqCandidateId req
                            response = responseVote newSt req
                        nsendRemote candId raftServerName response
                        if voteGranted response
                          then return newSt { votedFor = Just candId }
                          else respondToServers newSt

                    -- If election timeout elapses without receiving
                    -- AppendEntries RPC form current leader or
                    -- granting vote to candidate: convert to
                    -- candidate.
                    , match $ \(_ :: RemindTimeout)
                              -> return st { currRole = Candidate }
                    ]

candidate :: [NodeId] -> StateT ServerState Process ()
candidate peers = StateT $ \currState -> do
  let (term, updState) = incCurrentTerm currState
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindTimeout eTime

  -- Send RequestVote RPCs to all other servers
  node <- getSelfNode
  forM_ peers $ \p -> nsendRemote p raftServerName
                                 RequestVoteReq { vreqTerm        = term
                                                , vreqCandidateId = node
                                                }

  nextState <- collectVotes updState $ (length peers + 1) `div` 2
  exit reminder ()
  return ((), nextState)

leader :: [NodeId] -> StateT ServerState Process ()
leader peers = StateT $ \currState -> do
  let idx = getNextIndex $ currLog currState
  sender <- spawnLocal . forM_ peers $ \p -> sendAppendEntries p idx currState

  nextState <- collectCommits currState $ (length peers + 1) `div` 2
  exit sender ()
  return ((), nextState)

remindTimeout :: Int -> Process ProcessId
remindTimeout micros = do
  pid <- getSelfPid
  spawnLocal $ do
    liftIO $ threadDelay micros
    send pid RemindTimeout
