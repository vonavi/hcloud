{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Leader
  (
    leader
  ) where

import           Control.Concurrent.Lifted      (threadDelay)
import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (NodeId, Process, ProcessId,
                                                 exit, getSelfNode, getSelfPid,
                                                 match, nsendRemote,
                                                 receiveWait, send, spawnLocal)
import           Control.Monad                  (forM_, forever, void)
import qualified Data.Map.Strict                as M
import qualified Data.Vector.Unboxed            as U

import           Raft.Types
import           Raft.Utils                     (getNextIndex, nextRandomNum,
                                                 remindTimeout, syncWithTerm)

leader :: MVar ServerState -> [NodeId] -> Process ()
leader mx peers = do
  -- Initialize nextIndex for each server
  idx <- getNextIndex . currVec <$> readMVar mx
  modifyMVar_ mx
    $ \st -> return st { nextIndex = M.fromList $ zip peers (repeat idx) }

  -- Send initial empty AppendEntries RPCs (heartbeat) to each server
  void . spawnLocal . forM_ peers $ sendAppendEntries mx

  -- Start to serve client requests
  pid    <- getSelfPid
  client <- spawnLocal . forever $ do
    threadDelay sendIntervalMs
    send pid SendIntervalTimeout

  heartbeat <- remindTimeout heartbeatTimeoutMs HeartbeatTimeout
  startCommunications mx peers heartbeat >>= flip exit ()
  exit client ()

sendAppendEntries :: MVar ServerState -> NodeId -> Process ()
sendAppendEntries mx peer = do
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
  [ match $ \(timeout :: RemindTimeout) ->
      case timeout of
        SendIntervalTimeout -> do
          exit heartbeat ()
          modifyMVar_ mx $ return . newClientEntry
          void . spawnLocal . forM_ peers $ sendAppendEntries mx
          remindTimeout heartbeatTimeoutMs HeartbeatTimeout
            >>= startCommunications mx peers

        HeartbeatTimeout    -> do
          exit heartbeat ()
          void . spawnLocal . forM_ peers $ sendAppendEntries mx
          remindTimeout heartbeatTimeoutMs HeartbeatTimeout
            >>= startCommunications mx peers

        _                   -> startCommunications mx peers heartbeat
  ]

collectCommits :: MVar ServerState -> Int -> Process ()
collectCommits _  0 = return ()
collectCommits mx n =
  receiveWait
  [ match $ \(res :: AppendEntriesRes) -> do
      term <- currTerm <$> readMVar mx
      case () of
        _ | aresTerm res > term  -> syncWithTerm mx (aresTerm res)
        _ | aresTerm res == term
          , aresSuccess res      -> collectCommits mx (pred n)
        _                        -> collectCommits mx n
    ]

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
