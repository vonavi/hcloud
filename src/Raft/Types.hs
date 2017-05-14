{-# LANGUAGE DeriveGeneric #-}

module Raft.Types
  (
    Term
  , LeaderId
  , Role(..)
  , Command
  , LogEntry(..)
  , ServerState(..)
  , RequestVote(..)
  , ResponseVote(..)
  , AppendEntriesReq(..)
  , AppendEntriesRes(..)
  , RemindMessage(..)
  , raftServerName
  , electionTimeoutMs
  , sendIntervalMs
  ) where

import           Control.Distributed.Process (NodeId)
import           Data.Binary                 (Binary)
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)
import           System.Random               (StdGen)

type Term     = Int
type LeaderId = NodeId
data Role     = Follower | Candidate | Leader
type Command  = Double

data LogEntry = LogEntry { logCmd   :: Command
                         , logTerm  :: Term
                         , logIndex :: Int
                         }
              deriving (Typeable, Generic)
instance Binary LogEntry

data ServerState = ServerState { currTerm    :: Term
                               , votedFor    :: Maybe LeaderId
                               , currRole    :: Role
                               , currLog     :: [LogEntry]
                               , commitIndex :: Int
                               , lastApplied :: Int
                               , nextIndex   :: [(NodeId, Int)]
                               , matchIndex  :: [(NodeId, Int)]
                               , currStdGen  :: StdGen
                               }

data RequestVote = RequestVote
                   { reqTerm        :: Term
                   , reqCandidateId :: LeaderId
                   }
                 deriving (Typeable, Generic)
instance Binary RequestVote

data ResponseVote = ResponseVote
                    { resTerm     :: Term
                    , voteGranted :: Bool
                    }
                  deriving (Typeable, Generic)
instance Binary ResponseVote

data AppendEntriesReq = AppendEntriesReq
                        { areqTerm     :: Term
                        , leaderId     :: LeaderId
                        , prevLogIndex :: Int
                        , prevLogTerm  :: Term
                        , areqEntries  :: [LogEntry]
                        , leaderCommit :: Int
                        }
                      deriving (Typeable, Generic)
instance Binary AppendEntriesReq

data AppendEntriesRes = AppendEntriesRes
                        { aresTerm    :: Term
                        , aresSuccess :: Bool
                        }
                      deriving (Typeable, Generic)
instance Binary AppendEntriesRes

data RemindMessage = RemindTimeout deriving (Typeable, Generic)
instance Binary RemindMessage

raftServerName :: String
raftServerName = "raft"

-- | Election timeout in milliseconds
electionTimeoutMs :: Int
electionTimeoutMs = 150

-- | Time interval between consecutive messages
sendIntervalMs :: Int
sendIntervalMs = 1
