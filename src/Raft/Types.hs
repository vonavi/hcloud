{-# LANGUAGE DeriveGeneric #-}

module Raft.Types
  (
    Term
  , LeaderId
  , Role(..)
  , ServerState(..)
  , RequestVote(..)
  , ResponseVote(..)
  , RemindMessage(..)
  , raftServerName
  , electionTimeoutMs
  ) where

import           Control.Distributed.Process (NodeId)
import           Data.Binary                 (Binary)
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)

type Term     = Int
type LeaderId = NodeId
data Role     = Follower | Candidate | Leader

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

data ResponseVote = ResponseVote
                    { resTerm     :: Term
                    , voteGranted :: Bool
                    }
                  deriving (Typeable, Generic)
instance Binary ResponseVote

data RemindMessage = RemindTimeout deriving (Typeable, Generic)
instance Binary RemindMessage

raftServerName :: String
raftServerName = "raft"

-- | Election timeout in milliseconds
electionTimeoutMs :: Int
electionTimeoutMs = 150
