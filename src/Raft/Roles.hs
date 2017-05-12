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
import           Control.Monad.Trans.State   (StateT, get, put)

import           Raft.Types
import           Raft.Utils                  (randomElectionTimeout)

follower :: RaftConfig -> StateT ServerState Process ()
follower cfg = do
  currState <- get
  res       <- lift $ do
    -- Reset election timer
    eTime    <- randomElectionTimeout $ electionTimeoutMs cfg * 1000
    reminder <- remindAfter eTime

    -- Communicate if the election timer is not elapsed
    msg <- respondToServers currState
    exit reminder ()
    return msg
  case res of
    VoteGranted candId -> put currState { votedFor = Just candId }
    _                  -> updateRole Candidate
    where
      respondToServers :: ServerState -> Process ActionMessage
      respondToServers st =
        receiveWait [ match $ \req@RequestVote{} -> do
                        let candId   = reqCandidateId req
                            response = voteResponse st req
                        nsendRemote candId raftServerName response
                        if voteGranted response
                          then return $ VoteGranted candId
                          else respondToServers st

                    , match $ \RemindTimeout -> return TimeoutElapsed
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
candidate cfg = do
  term <- incCurrentTerm
  res  <- lift $ do
    -- Reset election timer
    eTime    <- randomElectionTimeout $ electionTimeoutMs cfg * 1000
    reminder <- remindAfter eTime

    -- Send RequestVote RPCs to all other servers
    node <- getSelfNode
    let peers = peerNodes cfg
    forM_ peers $ \p -> nsendRemote p raftServerName
                        RequestVote { reqTerm        = term
                                    , reqCandidateId = node
                                    }
    -- Collect votes from servers
    msg <- collectVotes node term $ (length peers + 1) `div` 2
    exit reminder ()
    return msg
  case res of
    VotesReceived      -> updateRole Leader
    LaterTerm recvTerm -> do updCurrentTerm recvTerm
                             node <- lift getSelfNode
                             updateRole $ FollowerOf node
    _                  -> return ()
  where
    collectVotes :: NodeId -> Term -> Int -> Process ActionMessage
    collectVotes _    _    0 = return VotesReceived
    collectVotes node term n =
      receiveWait
      [ match $ \ResponseVote{ resTerm     = recvTerm
                             , voteGranted = granted
                             }
                -> case () of
                     _ | granted         -> collectVotes node term (pred n)
                     _ | recvTerm > term -> return $ LaterTerm recvTerm
                     _                   -> collectVotes node term n

      , match $ \RemindTimeout -> return TimeoutElapsed
      ]

leader :: RaftConfig -> StateT ServerState Process ()
leader _ = lift $ do say "I'm the leader."
                     liftIO $ threadDelay 1000000

updateRole :: Role -> StateT ServerState Process ()
updateRole newRole = do st <- get
                        put st { currRole = newRole }

incCurrentTerm :: StateT ServerState Process Term
incCurrentTerm = do st <- get
                    let term = succ $ currTerm st
                    put st { currTerm = term }
                    return term

updCurrentTerm :: Term -> StateT ServerState Process ()
updCurrentTerm term = do st <- get
                         put st { currTerm = term }

remindAfter :: Int -> Process ProcessId
remindAfter micros = do
  pid <- getSelfPid
  spawnLocal $ do
    liftIO $ threadDelay micros
    send pid RemindTimeout
