module Raft.Types
  (
    RaftConfig(..)
  , Role(..)
  , ServerState(..)
  ) where

data RaftConfig = RaftConfig { electionTimeoutMs :: Int
                               -- ^ Election timeout in milliseconds
                             }

data Role = Follower
          | Candidate
          | Leader

data ServerState = ServerState { currTerm :: Int
                               , currRole :: Role
                               }
