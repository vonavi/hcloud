module Raft.Utils
  (
    whenUpdatedTerm
  , syncWithTerm
  , incCurrentTerm
  , remindTimeout
  , randomElectionTimeout
  , getNextIndex
  , nextRandomNum
  , newLogQueue
  , writeLogQueue
  ) where

import           Control.Concurrent                           (forkIO)
import           Control.Concurrent.Chan                      (Chan, newChan,
                                                               readChan,
                                                               writeChan)
import           Control.Concurrent.Lifted                    (threadDelay)
import           Control.Concurrent.MVar.Lifted               (MVar, modifyMVar,
                                                               modifyMVar_,
                                                               readMVar)
import           Control.Distributed.Process                  (Process,
                                                               ProcessId,
                                                               getSelfPid,
                                                               liftIO, send,
                                                               spawnLocal)
import           Control.Distributed.Process.MonadBaseControl ()
import           Control.Monad                                (forever, void,
                                                               when)
import           Data.Bits                                    (shiftL, shiftR,
                                                               xor)
import           Data.Time.Clock                              (getCurrentTime)
import           Data.Time.Format                             (formatTime)
import           Data.Time.Format                             (defaultTimeLocale)
import           System.IO                                    (hPutStrLn,
                                                               stderr)
import           System.Random                                (randomRIO)

import           Raft.Types

whenUpdatedTerm :: MVar ServerState -> Term -> Process () -> Process ()
whenUpdatedTerm mx term act = do
  stTerm <- currTerm <$> readMVar mx
  when (term >= stTerm) act

syncWithTerm :: MVar ServerState -> Term -> Process ()
syncWithTerm mx term = modifyMVar_ mx $ return . updater
  where updater st = if term > currTerm st
                     then st { currTerm = term
                             , votedFor = Nothing
                             , currRole = Follower
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

newLogQueue :: IO (Chan String)
newLogQueue = do
  queue <- newChan
  void . forkIO . forever $ do
    msg <- readChan queue
    hPutStrLn stderr msg
  return queue

writeLogQueue :: Chan String -> String -> IO ()
writeLogQueue queue str = do
  now <- getCurrentTime
  writeChan queue $ formatTime defaultTimeLocale "%c" now ++ ": " ++ str
