{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Leader
  (
    leader
  ) where

import           Control.Concurrent.Lifted                (threadDelay)
import           Control.Concurrent.MVar.Lifted           (MVar, modifyMVar_,
                                                           readMVar)
import           Control.Distributed.Process              (NodeId, Process,
                                                           ProcessId, exit,
                                                           forward, getSelfNode,
                                                           getSelfPid, link,
                                                           match, nsendRemote,
                                                           receiveWait, send,
                                                           spawnLocal,
                                                           wrapMessage)
import           Control.Distributed.Process.Serializable (Serializable)
import           Control.Monad                            (forM_, forever,
                                                           unless, when)
import           Data.List                                (sortBy)
import qualified Data.Map.Strict                          as M
import           Data.Maybe                               (fromJust)
import           Data.Ord                                 (Down (..), comparing)
import qualified Data.Vector.Unboxed                      as U

import           Raft.Types
import           Raft.Utils                               (getLastIndex,
                                                           getNextIndex,
                                                           isTermStale,
                                                           nextRandomNum,
                                                           remindTimeout,
                                                           saveSession,
                                                           syncWithTerm,
                                                           writeLogger)

leader :: MVar ServerState -> [NodeId] -> Process ()
leader mx peers = do
  pid <- getSelfPid
  writeLogger mx "Hi!"
  -- Initialize nextIndex for each server
  idx <- getNextIndex . currVec <$> readMVar mx
  modifyMVar_ mx
    $ \st -> return st { nextIndex = M.fromList $ zip peers (repeat idx) }

  -- Send initial empty AppendEntries RPCs (heartbeat) to each server
  forM_ peers $ sendAppendEntries mx

  -- Start to serve client requests
  client <- spawnLocal $ do
    link pid
    forever $ do
      threadDelay $ sendIntervalMs * 1000
      send pid SendIntervalTimeout

  heartbeat <- remindHeartbeat
  startCommunications mx peers heartbeat >>= flip exit ()
  exit client ()

sendAppendEntries :: MVar ServerState -> NodeId -> Process ()
sendAppendEntries mx peer = do
  writeLogger mx $ "sending AppendEntriesReq to " ++ show peer
  st   <- readMVar mx
  node <- getSelfNode
  let nextIdx            = nextIndex st M.! peer
      (nextLog, prevLog) = U.span ((>= nextIdx) . logIndex)
                           . getLog $ currVec st
      prevTerm
        | U.null prevLog = 0
        | otherwise      = logTerm $ U.head prevLog
  nsendRemote peer raftServerName
    AppendEntriesReq { areqTerm     = currTerm st
                     , leaderId     = node
                     , prevLogIndex = pred nextIdx
                     , prevLogTerm  = prevTerm
                     , areqEntries  = LogVector nextLog
                     , leaderCommit = commitIndex st
                     }

startCommunications :: MVar ServerState -> [NodeId] -> ProcessId
                    -> Process ProcessId
startCommunications mx peers heartbeat =
  receiveWait
  [ match $ \(req :: AppendEntriesReq) -> do
      writeLogger mx $ "received AppendEntriesReq from "
        ++ show (leaderId req) ++ " Term " ++ show (areqTerm req)
      unlessStepDown (areqTerm req) req $ startCommunications mx peers heartbeat

  , match $ \(req :: RequestVoteReq) -> do
      writeLogger mx $ "received RequestVoteReq from "
        ++ show (vreqCandidateId req) ++ " Term " ++ show (vreqTerm req)
      unlessStepDown (vreqTerm req) req $ startCommunications mx peers heartbeat

  , match $ \(res :: AppendEntriesRes) -> do
      writeLogger mx $ "received AppendEntriesRes from "
        ++ show (aresFollowerId res) ++ " Term " ++ show (aresTerm res)
      let term = aresTerm res
      unlessStepDown term res . unlessStaleTerm term $ do
        success <- collectAppendEntriesRes mx res
        unless success $ do
          let peer = aresFollowerId res
          decrementNextIndex mx peer
          sendAppendEntries mx peer
        startCommunications mx peers heartbeat

  , match $ \(res :: RequestVoteRes) -> do
      writeLogger mx
        $ "received RequestVoteRes from Term " ++ show (vresTerm res)
      unlessStepDown (vresTerm res) res $ startCommunications mx peers heartbeat

  , match $ \(timeout :: RemindTimeout) ->
      case timeout of
        SendIntervalTimeout -> do
          exit heartbeat ()
          modifyMVar_ mx $ return . newClientEntry
          saveSession mx
          forM_ peers $ sendAppendEntries mx
          remindHeartbeat >>= startCommunications mx peers

        HeartbeatTimeout    -> do
          exit heartbeat ()
          forM_ peers $ sendAppendEntries mx
          remindHeartbeat >>= startCommunications mx peers

        _                   -> startCommunications mx peers heartbeat
  ]
  where unlessStepDown :: forall a. Serializable a => Term -> a
                       -> Process ProcessId -> Process ProcessId
        unlessStepDown term msg act = do
          stepDown <- syncWithTerm mx term
          if stepDown
            then do getSelfPid >>= forward (wrapMessage msg)
                    return heartbeat
            else act

        unlessStaleTerm :: Term -> Process ProcessId -> Process ProcessId
        unlessStaleTerm term act = do
          ignore <- isTermStale mx term
          if ignore
            then startCommunications mx peers heartbeat
            else act

collectAppendEntriesRes :: MVar ServerState -> AppendEntriesRes -> Process Bool
collectAppendEntriesRes mx res
  | not (aresSuccess res) = return False
  | otherwise             = do
      let peer     = aresFollowerId res
          matchIdx = aresMatchIndex res
      modifyMVar_ mx
        $ \st -> return st { matchIndex = M.adjust (const matchIdx) peer
                                          $ matchIndex st
                           , nextIndex  = M.adjust (succ . const matchIdx) peer
                                          $ nextIndex st
                           }
      updateCommitIndex mx
      return True

updateCommitIndex :: MVar ServerState -> Process ()
updateCommitIndex mx = do
  st <- readMVar mx
  -- Find the index 'n' of log entry replicated on a majority of the servers
  let logs         = currVec st
      matchIdxList = sortBy (comparing Down) . (getLastIndex logs :)
                     . map snd . M.toList $ matchIndex st
      n            = matchIdxList !! (length matchIdxList `div` 2)
      term         = logTerm . fromJust
                     . U.find ((== n) . logIndex) .  getLog $ logs
  when ((n > commitIndex st) && (term == currTerm st))
    . modifyMVar_ mx $ \s -> return s { commitIndex = n
                                      , lastApplied = n
                                      }

decrementNextIndex :: MVar ServerState -> NodeId -> Process ()
decrementNextIndex mx peer =
  modifyMVar_ mx
  $ \st -> return st { nextIndex = M.adjust pred peer $ nextIndex st }

newClientEntry :: ServerState -> ServerState
newClientEntry st = st { currVec = LogVector $ U.cons entry oldLog }
  where oldLog = getLog $ currVec st
        seed   = if U.null oldLog
                 then initSeed st
                 else nextRandomNum . logSeed $ U.head oldLog
        entry  = LogEntry { logSeed  = seed
                          , logTerm  = currTerm st
                          , logIndex = getNextIndex $ LogVector oldLog
                          }

remindHeartbeat :: Process ProcessId
remindHeartbeat = remindTimeout (heartbeatTimeoutMs * 1000) HeartbeatTimeout
