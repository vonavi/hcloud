{-# LANGUAGE ScopedTypeVariables #-}

module Raft.Leader
  (
    leader
  , newClientEntry
  ) where

import           Control.Concurrent.MVar.Lifted (MVar, readMVar)
import           Control.Distributed.Process    (NodeId, Process, exit,
                                                 getSelfNode, match,
                                                 nsendRemote, receiveWait,
                                                 spawnLocal)
import           Data.Foldable                  (forM_)
import qualified Data.Vector.Unboxed            as U

import           Raft.Types
import           Raft.Utils                     (getNextIndex, nextRandomNum,
                                                 syncWithTerm)

leader :: MVar ServerState -> [NodeId] -> Process ()
leader mx peers = do
  idx    <- getNextIndex . currVec <$> readMVar mx
  sender <- spawnLocal . forM_ peers $ \p -> sendAppendEntries mx p idx

  collectCommits mx $ (length peers + 1) `div` 2
  exit sender ()

sendAppendEntries :: MVar ServerState -> NodeId -> Int -> Process ()
sendAppendEntries mx peer idx = do
  st <- readMVar mx
  let prevIdx = pred idx
      entry   = U.find ((== prevIdx) . logIndex) . getLog $ currVec st
      prevTerm
        | prevIdx == 0    = 0
        | Just e <- entry = logTerm e
        | otherwise       = error "inconsistent log"
  node <- getSelfNode
  nsendRemote peer raftServerName
    AppendEntriesReq { areqTerm     = currTerm st
                     , leaderId     = node
                     , prevLogIndex = prevIdx
                     , prevLogTerm  = prevTerm
                     , areqEntries  = LogVector U.empty
                     , leaderCommit = commitIndex st
                     }

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
