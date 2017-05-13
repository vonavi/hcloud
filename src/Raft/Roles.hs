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
                                              say, send, spawnLocal)
import           Control.Monad               (forM_)
import           Control.Monad.Trans.Class   (lift)
import           Control.Monad.Trans.State   (StateT (..))

import           Raft.Types
import           Raft.Utils                  (randomElectionTimeout)

follower :: RaftConfig -> StateT ServerState Process ()
follower cfg = StateT $ \currState -> do
  eTime    <- randomElectionTimeout $ electionTimeoutMs cfg * 1000
  reminder <- remindAfter eTime

  -- Communicate if the election timer is not elapsed
  nextState <- respondToServers currState
  exit reminder ()
  return ((), nextState)
    where
      respondToServers :: ServerState -> Process ServerState
      respondToServers st =
        receiveWait [ match $ \req@RequestVote{} -> do
                        let candId   = reqCandidateId req
                            response = voteResponse st req
                        nsendRemote candId raftServerName response

                        -- Update the current term
                        newSt <- updCurrentTerm st (reqTerm req)

                        if voteGranted response
                          then return newSt { votedFor = Just candId }
                          else respondToServers newSt

                    -- If election timeout elapses without receiving
                    -- AppendEntries RPC form current leader or
                    -- granting vote to candidate: convert to
                    -- candidate.
                    , match $ \RemindTimeout -> updateRole st Candidate
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

candidate :: RaftConfig -> StateT ServerState Process ()
candidate cfg = StateT $ \currState -> do
  (term, updState) <- incCurrentTerm currState
  eTime            <- randomElectionTimeout $ electionTimeoutMs cfg * 1000
  reminder         <- remindAfter eTime

  -- Send RequestVote RPCs to all other servers
  node <- getSelfNode
  let peers = peerNodes cfg
  forM_ peers $ \p -> nsendRemote p raftServerName
                                 RequestVote { reqTerm        = term
                                             , reqCandidateId = node
                                             }

  nextState <- collectVotes updState node $ (length peers + 1) `div` 2
  exit reminder ()
  return ((), nextState)
  where
    collectVotes :: ServerState -> NodeId -> Int -> Process ServerState
    collectVotes st _    0 = updateRole st Leader
    collectVotes st node n =
      receiveWait
      [ match $ \ResponseVote{ resTerm     = term
                             , voteGranted = granted
                             }
                -> case () of
                     _ | term > currTerm st -> do
                           newSt <- updCurrentTerm st term
                           updateRole newSt $ FollowerOf node
                     _ | granted            -> collectVotes st node (pred n)
                     _                      -> collectVotes st node n

      -- If election timeout elapses: start new election
      , match $ \RemindTimeout -> return st
      ]

leader :: RaftConfig -> StateT ServerState Process ()
leader _ = lift $ do say "I'm the leader."
                     liftIO $ threadDelay 1000000

updateRole :: ServerState -> Role -> Process ServerState
updateRole st newRole = return st { votedFor = Nothing
                                  , currRole = newRole
                                  }

incCurrentTerm :: ServerState -> Process (Term, ServerState)
incCurrentTerm st = return (updTerm, st { currTerm = updTerm })
  where updTerm = succ $ currTerm st

updCurrentTerm :: ServerState -> Term -> Process ServerState
updCurrentTerm st term
  | term > currTerm st = return st { currTerm = term }
  | otherwise          = return st

remindAfter :: Int -> Process ProcessId
remindAfter micros = do
  pid <- getSelfPid
  spawnLocal $ do
    liftIO $ threadDelay micros
    send pid RemindTimeout
