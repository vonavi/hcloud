module Raft.Utils
  (
    updCurrentTerm
  , incCurrentTerm
  , randomElectionTimeout
  , getNextIndex
  , nextRandomNum
  ) where

import           Control.Distributed.Process (Process, liftIO)
import           Data.Bits                   (shiftL, shiftR, xor)
import           System.Random               (randomRIO)

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

-- Iterates the random generator for 32 bits
nextRandomNum :: Xorshift32 -> Xorshift32
nextRandomNum (Xorshift32 a) = Xorshift32 d
  where b = a `xor` shiftL a 13
        c = b `xor` shiftR b 17
        d = c `xor` shiftL c 5
