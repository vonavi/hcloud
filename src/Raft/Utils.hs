{-# LANGUAGE FlexibleContexts #-}

module Raft.Utils
  (
    whenUpdatedTerm
  , syncWithTerm
  , incCurrentTerm
  , remindTimeout
  , randomElectionTimeout
  , getNextIndex
  , nextRandomNum
  , newLogger
  , writeLogger
  , newMailbox
  , registerMailbox
  , putMessages
  ) where

import           Control.Concurrent                           (forkIO)
import           Control.Concurrent.Chan                      (Chan, newChan,
                                                               readChan,
                                                               writeChan)
import           Control.Concurrent.Lifted                    (threadDelay)
import           Control.Concurrent.MVar.Lifted               (MVar, modifyMVar,
                                                               modifyMVar_,
                                                               readMVar)
import           Control.Concurrent.STM                       (atomically,
                                                               check)
import           Control.Concurrent.STM.TMVar                 (isEmptyTMVar,
                                                               newEmptyTMVar,
                                                               putTMVar)
import           Control.Distributed.Process                  (Process,
                                                               ProcessId,
                                                               getSelfPid,
                                                               liftIO, send,
                                                               spawnLocal)
import           Control.Distributed.Process.MonadBaseControl ()
import           Control.Monad                                (forever, void,
                                                               when)
import           Control.Monad.Trans.Control                  (MonadBaseControl)
import           Data.Bits                                    (shiftL, shiftR,
                                                               xor)
import           Data.Time.Clock                              (getCurrentTime)
import           Data.Time.Format                             (defaultTimeLocale,
                                                               formatTime)
import qualified Data.Vector.Unboxed                          as U
import           System.IO                                    (hFlush,
                                                               hPutStrLn,
                                                               stderr, stdout)
import           System.Random                                (randomRIO)

import           Raft.Types

whenUpdatedTerm :: MonadBaseControl IO m
                => MVar ServerState -> Term -> m () -> m ()
whenUpdatedTerm mx term act = do
  stTerm <- currTerm <$> readMVar mx
  when (term >= stTerm) act

syncWithTerm :: MonadBaseControl IO m => MVar ServerState -> Term -> m ()
syncWithTerm mx term = modifyMVar_ mx $ return . updater
  where updater st = if term > currTerm st
                     then st { currTerm = term
                             , votedFor = Nothing
                             , currRole = Follower
                             }
                     else st

incCurrentTerm :: MonadBaseControl IO m => MVar ServerState -> m Term
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
    threadDelay micros
    send pid RemindTimeout

randomElectionTimeout :: Int -> Process Int
randomElectionTimeout base =
  liftIO $ ((base `div` 1000) *) <$> randomRIO (1000, 2000)

getNextIndex :: LogVector -> Int
getNextIndex v | U.null logs = 1
               | otherwise   = succ . logIndex $ U.head logs
  where logs = getLog v

-- Iterates the random generator for 32 bits
nextRandomNum :: Xorshift32 -> Xorshift32
nextRandomNum (Xorshift32 a) = Xorshift32 d
  where b = a `xor` shiftL a 13
        c = b `xor` shiftR b 17
        d = c `xor` shiftL c 5

newLogger :: IO (Chan String)
newLogger = do
  logs <- newChan
  void . forkIO . forever
    $ readChan logs >>= hPutStrLn stderr >> hFlush stderr
  return logs

writeLogger :: Chan String -> String -> Process ()
writeLogger logs str = do
  now <- liftIO getCurrentTime
  pid <- getSelfPid
  liftIO . writeChan logs
    $ formatTime defaultTimeLocale "%c" now ++ " " ++ show pid ++ ": " ++ str

newMailbox :: IO Mailbox
newMailbox = do
  now <- atomically newEmptyTMVar
  box <- newChan
  void . forkIO . forever $ readChan box >>= print >> hFlush stdout
  return Mailbox { putMsg = now
                 , msgBox = box
                 }

registerMailbox :: MVar ServerState -> Mailbox -> Process ()
registerMailbox mx mailbox = void . spawnLocal . liftIO $ do
  atomically $ isEmptyTMVar (putMsg mailbox) >>= check . not
  entries <- currVec <$> readMVar mx
  writeChan (msgBox mailbox) entries

putMessages :: Mailbox -> IO ()
putMessages mailbox = atomically $ putTMVar (putMsg mailbox) ()
