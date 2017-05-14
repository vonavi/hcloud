module Raft.Utils
  (
    updCurrentTerm
  , incCurrentTerm
  , randomElectionTimeout
  , getNextIndex
  , nextRandomNum
  ) where

import           Control.Distributed.Process (Process, liftIO)
import           System.Random               (RandomGen, randomR, randomRIO)

import           Raft.Types

updCurrentTerm :: Term -> ServerState -> ServerState
updCurrentTerm term st
  | term > currTerm st = st { currTerm = term
                            , votedFor = Nothing
                            }
  | otherwise          = st

incCurrentTerm :: ServerState -> (Term, ServerState)
incCurrentTerm st = (updTerm, newSt)
  where updTerm = succ $ currTerm st
        newSt   = st { currTerm = updTerm
                     , votedFor = Nothing
                     }

randomElectionTimeout :: Int -> Process Int
randomElectionTimeout base =
  liftIO $ ((base `div` 1000) *) <$> randomRIO (1000, 2000)

getNextIndex :: [LogEntry] -> Int
getNextIndex (x : _) = succ $ logIndex x
getNextIndex _       = 1

nextRandomNum :: RandomGen g => g -> (Double, g)
nextRandomNum = randomR (0.001, 1)
