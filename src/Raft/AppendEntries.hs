{-# LANGUAGE ScopedTypeVariables #-}

module Raft.AppendEntries
  (
    newClientEntry
  , sendAppendEntries
  , collectCommits
  , appendEntries
  ) where

import           Control.Distributed.Process (NodeId, Process, getSelfNode,
                                              match, nsendRemote, receiveWait)
import           Data.List                   (find)

import           Raft.Types
import           Raft.Utils                  (getNextIndex, nextRandomNum,
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

sendAppendEntries :: NodeId -> Int -> ServerState -> Process ()
sendAppendEntries peer idx st = do
  node <- getSelfNode
  nsendRemote peer raftServerName
    AppendEntriesReq { areqTerm     = currTerm st
                     , leaderId     = node
                     , prevLogIndex = prevIdx
                     , prevLogTerm  = prevTerm
                     , areqEntries  = []
                     , leaderCommit = commitIndex st
                     }
    where prevIdx = pred idx
          entry   = find ((== prevIdx) . logIndex) $ currLog st
          prevTerm
            | prevIdx == 0    = 0
            | Just e <- entry = logTerm e
            | otherwise       = error "inconsistent leader log"

collectCommits :: ServerState -> Int -> Process ServerState
collectCommits st 0 = return st
collectCommits st n =
  receiveWait
  [ match $ \(res :: AppendEntriesRes) -> do
      let term = aresTerm res
      case () of
        _ | term > currTerm st -> do
              let newSt = updCurrentTerm term st
              return newSt { currRole = Follower }
        _ | aresSuccess res    -> collectCommits st (pred n)
        _                      -> collectCommits st n
  ]

appendEntries :: AppendEntriesReq -> ServerState -> Process ServerState
appendEntries req st
  | areqTerm req < term = append False
  | idx == 0            = append True
  | (e : _) <- oldLog
  , logIndex e == idx   = if logTerm e == prevLogTerm req
                          then append True
                          else do updSt <- append False
                                  return updSt { currLog = tail oldLog }
  | otherwise           = append False
  where term    = currTerm st
        idx     = prevLogIndex req
        oldLog  = dropWhile ((> idx) . logIndex) $ currLog st
        entries = areqEntries req

        append res = do nsendRemote (leaderId req) raftServerName
                          AppendEntriesRes { aresTerm    = term
                                           , aresSuccess = res
                                           }
                        return $ if res
                                 then updCommitIndex
                                      $ st { currLog = entries ++ oldLog }
                                 else st

        updCommitIndex updSt = updSt { commitIndex = n }
          where n = case currLog updSt of
                      []      -> 0
                      (e : _) -> min (leaderCommit req) (logIndex e)
