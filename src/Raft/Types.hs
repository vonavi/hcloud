{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}

module Raft.Types
  (
    Xorshift32(..)
  , Term
  , LogEntry(..)
  , LogVector(..)
  , RaftParams(..)
  , Mailbox(..)
  , LeaderId
  , Role(..)
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

import           Control.Concurrent.Chan      (Chan)
import           Control.Concurrent.STM.TMVar (TMVar)
import           Control.Distributed.Process  (NodeId)
import           Data.Binary                  (Binary)
import           Data.Typeable                (Typeable)
import           Data.Vector.Binary           ()
import qualified Data.Vector.Unboxed          as U
import           Data.Vector.Unboxed.Deriving (derivingUnbox)
import           Data.Word                    (Word32)
import           GHC.Generics                 (Generic)

newtype Xorshift32 = Xorshift32 { getWord32 :: Word32 }
                   deriving (Show, Typeable, Generic)
instance Binary Xorshift32

derivingUnbox "Xorshift32"
  [t| Xorshift32 -> Word32 |]
  [| \(Xorshift32 seed) -> seed |]
  [| Xorshift32 |]

type Term = Int

data LogEntry = LogEntry { logSeed  :: Xorshift32
                         , logTerm  :: Term
                         , logIndex :: Int
                         }
              deriving (Show, Typeable, Generic)
instance Binary LogEntry

derivingUnbox "LogEntry"
  [t| LogEntry -> (Xorshift32, Term, Int) |]
  [| \(LogEntry seed term idx) -> (seed, term, idx) |]
  [| \(seed, term, idx) -> LogEntry seed term idx |]

newtype LogVector = LogVector { getLog :: U.Vector LogEntry }
                  deriving (Show, Typeable, Generic)
instance Binary LogVector

data RaftParams = RaftParams { raftPeers   :: [NodeId]
                             , raftSeed    :: Word32
                             , raftFile    :: FilePath
                             , raftLogger  :: Chan String
                             , raftMailbox :: Mailbox
                             }

data Mailbox = Mailbox { putMsg :: TMVar ()
                       , msgBox :: Chan LogVector
                       }

type LeaderId = NodeId
data Role     = Follower | Candidate | Leader

data ServerState = ServerState { currTerm    :: Term
                               , votedFor    :: Maybe LeaderId
                               , currRole    :: Role
                               , currVec     :: LogVector
                               , commitIndex :: Int
                               , lastApplied :: Int
                               , nextIndex   :: [(NodeId, Int)]
                               , matchIndex  :: [(NodeId, Int)]
                               , initSeed    :: Xorshift32
                               , sessionFile :: FilePath
                               , selfLogger  :: Chan String
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
                        , areqEntries  :: LogVector
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
