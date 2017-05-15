{-# LANGUAGE ScopedTypeVariables #-}

module Raft.AppendEntries
  (
    newClientEntry
  , sendAppendEntries
  , collectCommits
  , appendEntries
  ) where

import           Control.Concurrent.MVar.Lifted (MVar, modifyMVar_, readMVar)
import           Control.Distributed.Process    (NodeId, Process, getSelfNode,
                                                 match, nsendRemote,
                                                 receiveWait)
import           Data.List                      (find)

import           Raft.Types
import           Raft.Utils                     (getNextIndex, nextRandomNum,
                                                 updCurrentTerm)

newClientEntry :: ServerState -> ServerState
newClientEntry st = st { currLog  = entry : oldLog }
  where oldLog = currLog st
        seed   = case oldLog of
                   (e : _) -> nextRandomNum $ logSeed e
                   []      -> initSeed st
        entry  = LogEntry { logSeed  = seed
                          , logTerm  = currTerm st
                          , logIndex = getNextIndex oldLog
                          }

sendAppendEntries :: MVar ServerState -> NodeId -> Int -> Process ()
sendAppendEntries mx peer idx = do
  st <- readMVar mx
  let prevIdx = pred idx
      entry   = find ((== prevIdx) . logIndex) $ currLog st
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
                     , areqEntries  = []
                     , leaderCommit = commitIndex st
                     }

collectCommits :: MVar ServerState -> Int -> Process ()
collectCommits _  0 = return ()
collectCommits mx n =
  receiveWait
  [ match $ \(res :: AppendEntriesRes) -> do
      term <- currTerm <$> readMVar mx
      case () of
        _ | aresTerm res > term -> do
              updCurrentTerm mx (aresTerm res)
              modifyMVar_ mx $ \st -> return st { currRole = Follower }
        _ | aresSuccess res     -> collectCommits mx (pred n)
        _                       -> collectCommits mx n
    ]

appendEntries :: MVar ServerState -> AppendEntriesReq -> Process ()
appendEntries mx req = do
  st <- readMVar mx
  let term       = currTerm st
      idx        = prevLogIndex req
      oldLog     = dropWhile ((> idx) . logIndex) $ currLog st
      entries    = areqEntries req
      result res = AppendEntriesRes { aresTerm    = term
                                    , aresSuccess = res
                                    }
  case () of
    _ | areqTerm req < term -> reply $ result False
    _ | idx == 0            -> do
          reply $ result True
          modifyMVar_ mx $ return . updCommits . setLog entries
    _ | (e : _) <- oldLog
      , logIndex e == idx   ->
          if logTerm e == prevLogTerm req
          then do reply $ result True
                  modifyMVar_ mx
                    $ return . updCommits . setLog (entries ++ oldLog)
          else do reply $ result False
                  modifyMVar_ mx $ \s -> return s { currLog = tail oldLog }
    _                       -> reply $ result False
  where
    reply = nsendRemote (leaderId req) raftServerName

    setLog entries st = st { currLog = entries }

    updCommits st = st { commitIndex = n }
      where n = case currLog st of
                  []      -> 0
                  (e : _) -> min (leaderCommit req) (logIndex e)
