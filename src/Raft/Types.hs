{-# LANGUAGE DeriveGeneric #-}

module Raft.Types
  (
    Xorshift32(..)
  , Term
  , LeaderId
  , Role(..)
  , LogEntry(..)
  , ServerState(..)
  , RequestVoteReq(..)
  , RequestVoteRes(..)
  , AppendEntriesReq(..)
  , AppendEntriesRes(..)
  , RemindTimeout(..)
  , raftServerName
  , electionTimeoutMs
  , sendIntervalMs
  ) where

import           Control.Concurrent.Chan     (Chan)
import           Control.Distributed.Process (NodeId)
import           Data.Binary                 (Binary)
import           Data.Typeable               (Typeable)
import           Data.Word                   (Word32)
import           GHC.Generics                (Generic)

newtype Xorshift32 = Xorshift32 { getWord32 :: Word32 }
                   deriving (Typeable, Generic)
instance Binary Xorshift32

type Term     = Int
type LeaderId = NodeId
data Role     = Follower | Candidate | Leader

data LogEntry = LogEntry { logSeed  :: Xorshift32
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
                               , initSeed    :: Xorshift32
                               , logQueue    :: Chan String
                               }

data RequestVoteReq = RequestVoteReq
                      { vreqTerm        :: Term
                      , vreqCandidateId :: LeaderId
                      }
                    deriving (Typeable, Generic)
instance Binary RequestVoteReq

data RequestVoteRes = RequestVoteRes
                      { vresTerm    :: Term
                      , voteGranted :: Bool
                      }
                    deriving (Typeable, Generic)
instance Binary RequestVoteRes

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

data RemindTimeout = RemindTimeout deriving (Typeable, Generic)
instance Binary RemindTimeout

raftServerName :: String
raftServerName = "raft"

-- | Election timeout in milliseconds
electionTimeoutMs :: Int
electionTimeoutMs = 150

-- | Time interval between consecutive messages
sendIntervalMs :: Int
sendIntervalMs = 1
