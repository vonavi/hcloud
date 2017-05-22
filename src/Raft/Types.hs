{-# LANGUAGE DeriveAnyClass        #-}
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
  , LogMessage(..)
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
  , heartbeatTimeoutMs
  , sendIntervalMs
  ) where

import           Control.Concurrent.Chan      (Chan)
import           Control.Concurrent.STM.TMVar (TMVar)
import           Control.Distributed.Process  (NodeId)
import           Data.Binary                  (Binary)
import qualified Data.Map.Strict              as M
import           Data.Serialize               (Serialize)
import           Data.Typeable                (Typeable)
import           Data.Vector.Binary           ()
import           Data.Vector.Serialize        ()
import qualified Data.Vector.Unboxed          as U
import           Data.Vector.Unboxed.Deriving (derivingUnbox)
import           Data.Word                    (Word32)
import           GHC.Generics                 (Generic)

-- | Seed for Xorshift32 pseudo-random number generator
newtype Xorshift32 = Xorshift32 { getWord32 :: Word32 }
                   deriving (Show, Typeable, Generic, Serialize)
instance Binary Xorshift32

derivingUnbox "Xorshift32"
  [t| Xorshift32 -> Word32 |]
  [| \(Xorshift32 seed) -> seed |]
  [| Xorshift32 |]

-- | Server's term
type Term = Int
-- | Server's role
data Role = Follower | Candidate | Leader
          deriving Show

-- | Log entry
data LogEntry = LogEntry { logSeed  :: {-# UNPACK #-} !Xorshift32
                           -- ^ seed of client messages
                         , logTerm  :: {-# UNPACK #-} !Term
                           -- ^ term when message was received from
                           --   client
                         , logIndex :: {-# UNPACK #-} !Int
                           -- ^ message index
                         }
              deriving (Show, Typeable, Generic, Serialize)
instance Binary LogEntry

derivingUnbox "LogEntry"
  [t| LogEntry -> (Xorshift32, Term, Int) |]
  [| \(LogEntry seed term idx) -> (seed, term, idx) |]
  [| \(seed, term, idx) -> LogEntry seed term idx |]

-- | Vector of log entries
newtype LogVector = LogVector { getLog :: U.Vector LogEntry }
                  deriving (Show, Typeable, Generic, Serialize)
instance Binary LogVector

-- | Information of debug message
data LogMessage = LogMessage
                  { msgNodeId :: {-# UNPACK #-} !NodeId
                    -- ^ server's identifier
                  , msgTerm   :: {-# UNPACK #-} !Term
                    -- ^ server's term
                  , msgRole   :: Role
                    -- ^ server's role
                  , msgString :: String
                    -- ^ debug message itself
                  }

-- | Parameters to be passed to initialize server
data RaftParams = RaftParams
                  { raftPeers   :: [NodeId]
                    -- ^ other cluster's nodes
                  , raftSeed    :: {-# UNPACK #-} !Word32
                    -- ^ initial seed of client messages
                  , raftFile    :: FilePath
                    -- ^ file to store persistent state
                  , raftLogger  :: {-# UNPACK #-} !(Chan LogMessage)
                    -- ^ channel to put debug messages
                  , raftMailbox :: {-# UNPACK #-} !Mailbox
                    -- ^ mailbox to put messages on demand
                  }

-- | Mailbox to put messages on demand
data Mailbox = Mailbox { putMsg :: {-# UNPACK #-} !(TMVar ())
                         -- ^ variable to listen
                       , msgBox :: {-# UNPACK #-} !(Chan LogMessage)
                         -- ^ channel where to put message
                       }
-- | Identifier of server
type LeaderId = NodeId

-- | State on all servers
data ServerState = ServerState
                   { currTerm    :: {-# UNPACK #-} !Term
                     -- ^ Latest term server has seen
                   , votedFor    :: Maybe LeaderId
                     -- ^ CandidateId that received vote in current
                     --   term
                   , currRole    :: Role
                     -- ^ Server state
                   , currVec     :: LogVector
                     -- ^ Log entries
                   , commitIndex :: {-# UNPACK #-} !Int
                     -- ^ Index of highest log entry known to be
                     --   committed
                   , lastApplied :: {-# UNPACK #-} !Int
                     -- ^ Index of highest log entry applied to state
                     --   machine
                   , nextIndex   :: M.Map NodeId Int
                     -- ^ For each server, index of the next log entry
                     --   to send to that server
                   , matchIndex  :: M.Map NodeId Int
                     -- ^ For each server, index of highest log entry
                     --   known to be replicated on server
                   , initSeed    :: {-# UNPACK #-} !Xorshift32
                     -- ^ Initial seed of randomly generated messages
                   , sessionFile :: FilePath
                     -- ^ File storing the persistent state of server
                   , selfLogger  :: {-# UNPACK #-} !(Chan LogMessage)
                     -- ^ Channel for debug information
                   }

-- | RequestVote RPC request
data RequestVoteReq = RequestVoteReq
                      { vreqTerm        :: {-# UNPACK #-} !Term
                        -- ^ candidate's term
                      , vreqCandidateId :: {-# UNPACK #-} !LeaderId
                        -- ^ candidate requesting vote
                      , lastLogIndex    :: {-# UNPACK #-} !Int
                        -- ^ index of candidate's last log entry
                      , lastLogTerm     :: {-# UNPACK #-} !Term
                        -- ^ term of candidate's last log entry
                      }
                    deriving (Typeable, Generic)
instance Binary RequestVoteReq

-- | RequestVote RPC response
data RequestVoteRes = RequestVoteRes
                      { vresTerm    :: {-# UNPACK #-} !Term
                        -- ^ currentTerm, for candidate to update
                        --   itself
                      , voteGranted :: Bool
                        -- ^ true means candidate received vote
                      }
                    deriving (Typeable, Generic)
instance Binary RequestVoteRes

-- | AppendEntries RPC request
data AppendEntriesReq = AppendEntriesReq
                        { areqTerm     :: {-# UNPACK #-} !Term
                          -- ^ leader's term
                        , leaderId     :: {-# UNPACK #-} !LeaderId
                          -- ^ so follower can redirect clients
                        , prevLogIndex :: {-# UNPACK #-} !Int
                          -- ^ index of log entry immediately
                          --   preceding new ones
                        , prevLogTerm  :: {-# UNPACK #-} !Term
                          -- ^ term of prevLogIndex entry
                        , areqEntries  :: LogVector
                          -- ^ log entries to store
                        , leaderCommit :: {-# UNPACK #-} !Int
                          -- ^ leader's commitIndex
                        }
                      deriving (Typeable, Generic)
instance Binary AppendEntriesReq

-- | AppendEntries RPC response
data AppendEntriesRes = AppendEntriesRes
                        { aresTerm       :: {-# UNPACK #-} !Term
                          -- ^ currentTerm, for leader to update
                          --   itself
                        , aresSuccess    :: Bool
                          -- ^ true if follower contained entry
                          --   matching prevLogIndex and prevLogTerm
                        , aresFollowerId :: {-# UNPACK #-} !NodeId
                          -- ^ so leader can update nextIndex and
                          --   matchIndex
                        , aresMatchIndex :: {-# UNPACK #-} !Int
                          -- ^ index of highest log entry
                        }
                      deriving (Typeable, Generic)
instance Binary AppendEntriesRes

-- | Message to be sent to remind a timeout
data RemindTimeout = HeartbeatTimeout
                   | SendIntervalTimeout
                   | ElectionTimeout
                   deriving (Typeable, Generic)
instance Binary RemindTimeout

-- | Server's name in registry
raftServerName :: String
raftServerName = "raft"

-- | Election timeout in milliseconds
electionTimeoutMs :: Int
electionTimeoutMs = 150

-- | Heartbeat timeout in milliseconds
heartbeatTimeoutMs :: Int
heartbeatTimeoutMs = 1

-- | Time interval between consecutive messages, in milliseconds
sendIntervalMs :: Int
sendIntervalMs = 1
