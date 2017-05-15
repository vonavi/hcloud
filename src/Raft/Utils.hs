module Raft.Utils
  (
    updCurrentTerm
  , incCurrentTerm
  , remindTimeout
  , randomElectionTimeout
  , getNextIndex
  , nextRandomNum
  ) where

import           Control.Concurrent.Lifted                    (threadDelay)
import           Control.Concurrent.MVar.Lifted               (MVar, modifyMVar,
                                                               modifyMVar_)
import           Control.Distributed.Process                  (Process,
                                                               ProcessId,
                                                               getSelfPid,
                                                               liftIO, send,
                                                               spawnLocal)
import           Control.Distributed.Process.MonadBaseControl ()
import           Data.Bits                                    (shiftL, shiftR,
                                                               xor)
import           System.Random                                (randomRIO)

import           Raft.Types

updCurrentTerm :: MVar ServerState -> Term -> Process ()
updCurrentTerm mx term = modifyMVar_ mx $ return . updater
  where updater st = if term > currTerm st
                     then st { currTerm = term
                             , votedFor = Nothing
                             }
                     else st

incCurrentTerm :: MVar ServerState -> Process Term
incCurrentTerm mx = modifyMVar mx $ return . updater
  where updater st = (updSt, updTerm)
          where updTerm = succ $ currTerm st
                updSt   = st { currTerm = updTerm
                             , votedFor = Nothing
                             }

remindTimeout :: Int -> Process ProcessId
remindTimeout micros = do
  pid <- getSelfPid
  spawnLocal $ do
    liftIO $ threadDelay micros
    send pid RemindTimeout

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
