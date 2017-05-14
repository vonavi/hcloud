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

import           Raft.AppendEntries
import           Raft.Types
import           Raft.Utils                  (getNextIndex, incCurrentTerm,
                                              randomElectionTimeout,
                                              updCurrentTerm)

follower :: StateT ServerState Process ()
follower = StateT $ \currState -> do
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindAfter eTime

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

                    , match $ \req@RequestVote{} -> do
                        -- Update the current term
                        let newSt = updCurrentTerm (reqTerm req) st

                        let candId   = reqCandidateId req
                            response = voteResponse newSt req
                        nsendRemote candId raftServerName response
                        if voteGranted response
                          then return newSt { votedFor = Just candId }
                          else respondToServers newSt

                    -- If election timeout elapses without receiving
                    -- AppendEntries RPC form current leader or
                    -- granting vote to candidate: convert to
                    -- candidate.
                    , match $ \RemindTimeout
                              -> return st { currRole = Candidate }
                    ]

      voteResponse :: ServerState -> RequestVote -> ResponseVote
      voteResponse st req = ResponseVote { resTerm     = currTerm st
                                         , voteGranted = granted
                                         }
        where granted
                | reqTerm req < currTerm st = False
                | otherwise                 =
                    case votedFor st of
                      Nothing     -> True
                      Just candId -> candId == reqCandidateId req

candidate :: [NodeId] -> StateT ServerState Process ()
candidate peers = StateT $ \currState -> do
  let (term, updState) = incCurrentTerm currState
  eTime    <- randomElectionTimeout $ electionTimeoutMs * 1000
  reminder <- remindAfter eTime

  -- Send RequestVote RPCs to all other servers
  node <- getSelfNode
  forM_ peers $ \p -> nsendRemote p raftServerName
                                 RequestVote { reqTerm        = term
                                             , reqCandidateId = node
                                             }

  nextState <- collectVotes updState $ (length peers + 1) `div` 2
  exit reminder ()
  return ((), nextState)
  where
    collectVotes :: ServerState -> Int -> Process ServerState
    collectVotes st 0 = return st { currRole = Leader }
    collectVotes st n =
      receiveWait
      [ match $ \ResponseVote{ resTerm     = term
                             , voteGranted = granted
                             }
                -> case () of
                     _ | term > currTerm st -> do
                           let newSt = updCurrentTerm term st
                           return newSt { currRole = Follower }
                     _ | granted            -> collectVotes st (pred n)
                     _                      -> collectVotes st n

      -- If election timeout elapses: start new election
      , match $ \RemindTimeout -> return st
      ]

leader :: [NodeId] -> StateT ServerState Process ()
leader peers = StateT $ \currState -> do
  let idx = getNextIndex $ currLog currState
  sender <- spawnLocal . forM_ peers $ \p -> sendAppendEntries p idx currState

  nextState <- collectCommits currState $ (length peers + 1) `div` 2
  exit sender ()
  return ((), nextState)

remindAfter :: Int -> Process ProcessId
remindAfter micros = do
  pid <- getSelfPid
  spawnLocal $ do
    liftIO $ threadDelay micros
    send pid RemindTimeout
