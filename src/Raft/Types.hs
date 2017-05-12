{-# LANGUAGE DeriveGeneric #-}

module Raft.Types
  (
    RaftConfig(..)
  , Term
  , LeaderId
  , Role(..)
  , ServerState(..)
  , RequestVote(..)
  , GrantVote(..)
  , ActionMessage(..)
  , RemindMessage(..)
  , raftServerName
  ) where

import           Control.Distributed.Process (NodeId)
import           Data.Binary                 (Binary)
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)

data RaftConfig = RaftConfig { electionTimeoutMs :: Int
                               -- ^ Election timeout in milliseconds
                             , peerNodes         :: [NodeId]
                               -- ^ Peer nodes
                             }

type Term     = Int
type LeaderId = NodeId
data Role     = FollowerOf LeaderId
              | Candidate
              | Leader

data ServerState = ServerState { currTerm :: Term
                               , votedFor :: Maybe LeaderId
                               , currRole :: Role
                               }

data RequestVote = RequestVote
                   { reqTerm        :: Term
                   , reqCandidateId :: LeaderId
                   }
                 deriving (Typeable, Generic)
instance Binary RequestVote

data GrantVote = GrantVote LeaderId deriving (Typeable, Generic)
instance Binary GrantVote

data ActionMessage = VoteGranted LeaderId
                   | VotesReceived
                   | TimeoutElapsed

data RemindMessage = RemindTimeout deriving (Typeable, Generic)
instance Binary RemindMessage

raftServerName :: String
raftServerName = "raft"
