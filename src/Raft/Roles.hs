module Raft.Roles
  (
    follower
  , candidate
  , leader
  ) where

import           Control.Concurrent          (threadDelay)
import           Control.Distributed.Process (NodeId, Process, ProcessId, exit,
                                              getSelfNode, getSelfPid, liftIO,
                                              match, matchIf, nsendRemote,
                                              receiveTimeout, receiveWait, say,
                                              send, spawnLocal)
import           Control.Monad               (forM_)
import           Control.Monad.Trans.Class   (lift)
import           Control.Monad.Trans.State   (StateT, get, put)

import           Raft.Types
import           Raft.Utils                  (randomElectionTimeout)

follower :: RaftConfig -> StateT ServerState Process ()
follower cfg = do
  currState <- get
  res       <- lift $ do
    eTime <- randomElectionTimeout $ electionTimeoutMs cfg * 1000
    receiveTimeout eTime
      [ matchIf (grantVote currState) $ \req@RequestVote{} -> do
          let candidateId = reqCandidateId req
          nsendRemote candidateId raftServerName (GrantVote candidateId)
          return $ VoteGranted candidateId
      ]
  case res of
    Just (VoteGranted candId) -> put currState { votedFor = Just candId }
    _                         -> updateRole Candidate

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
    msg  <- collectVotes node $ (length peers + 1) `div` 2
    exit reminder ()
    return msg
  case res of
    VotesReceived -> updateRole Leader
    _             -> return ()

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

grantVote :: ServerState -> RequestVote -> Bool
grantVote st req
  | reqTerm req < currTerm st = False
  | otherwise                 =
    case votedFor st of
      Nothing     -> True
      Just candId -> candId == reqCandidateId req

remindAfter :: Int -> Process ProcessId
remindAfter micros = do
  pid <- getSelfPid
  spawnLocal $ do
    liftIO $ threadDelay micros
    send pid RemindTimeout

collectVotes :: NodeId -> Int -> Process ActionMessage
collectVotes _    0 = return VotesReceived
collectVotes node n =
  receiveWait
  [ match $ \(GrantVote candId) -> if candId == node
                                   then collectVotes node (pred n)
                                   else collectVotes node n
  , match $ \RemindTimeout      -> return TimeoutElapsed
  ]
