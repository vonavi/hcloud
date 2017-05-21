{-# LANGUAGE FlexibleContexts #-}

module Raft.Utils
  (
    isTermStale
  , syncWithTerm
  , incCurrentTerm
  , remindTimeout
  , randomElectionTimeout
  , getMatchIndex
  , getNextIndex
  , getLastIndex
  , getLastTerm
  , nextRandomNum
  , newLogger
  , writeLogger
  , newMailbox
  , registerMailbox
  , putMessages
  , saveSession
  , restoreSession
  ) where

import           Control.Concurrent                           (forkIO)
import           Control.Concurrent.Chan                      (Chan, newChan,
                                                               readChan,
                                                               writeChan)
import           Control.Concurrent.Lifted                    (threadDelay)
import           Control.Concurrent.MVar.Lifted               (MVar,
                                                               modifyMVar_,
                                                               newMVar,
                                                               readMVar)
import           Control.Concurrent.STM                       (atomically,
                                                               check)
import           Control.Concurrent.STM.TMVar                 (isEmptyTMVar,
                                                               newEmptyTMVar,
                                                               putTMVar)
import           Control.Distributed.Process                  (NodeId (..),
                                                               Process,
                                                               ProcessId,
                                                               getSelfNode,
                                                               getSelfPid,
                                                               liftIO, link,
                                                               send, spawnLocal)
import           Control.Distributed.Process.MonadBaseControl ()
import           Control.Exception                            (handle, throwIO)
import           Control.Monad                                (forever, void,
                                                               when)
import           Control.Monad.Trans.Control                  (MonadBaseControl)
import           Data.Bits                                    (shiftL, shiftR,
                                                               xor)
import qualified Data.ByteString.Char8                        as BC
import           Data.Serialize                               (decode, encode)
import qualified Data.Vector.Unboxed                          as U
import           Network.Transport                            (EndPointAddress (..))
import           System.IO                                    (hFlush, stderr,
                                                               stdout)
import           System.IO.Error                              (isDoesNotExistError)
import           System.Random                                (randomRIO)
import           Text.Printf                                  (hPrintf, printf)

import           Raft.Types

isTermStale :: MonadBaseControl IO m => MVar ServerState -> Term -> m Bool
isTermStale mx term = do
  stTerm <- currTerm <$> readMVar mx
  return (term < stTerm)

syncWithTerm :: MonadBaseControl IO m => MVar ServerState -> Term -> m Bool
syncWithTerm mx term = do
  stTerm <- currTerm <$> readMVar mx
  if term > stTerm
    then do modifyMVar_ mx $ \st -> return st { currTerm = term
                                              , votedFor = Nothing
                                              , currRole = Follower
                                              }
            return True
    else return False

incCurrentTerm :: MonadBaseControl IO m => MVar ServerState -> m ()
incCurrentTerm mx = modifyMVar_ mx
                    $ \st -> return st { currTerm = succ $ currTerm st
                                       , votedFor = Nothing
                                       }

remindTimeout :: Int -> RemindTimeout -> Process ProcessId
remindTimeout micros timeout = do
  pid <- getSelfPid
  spawnLocal $ do
    link pid
    threadDelay micros
    send pid timeout

randomElectionTimeout :: Int -> Process Int
randomElectionTimeout base =
  liftIO $ ((base `div` 1000) *) <$> randomRIO (1000, 2000)

getMatchIndex :: LogVector -> Int
getMatchIndex v | U.null logs = 0
                | otherwise   = logIndex $ U.head logs
  where logs = getLog v

getNextIndex :: LogVector -> Int
getNextIndex = succ . getMatchIndex

getLastIndex :: LogVector -> Int
getLastIndex v | U.null logs = 0
               | otherwise   = logIndex $ U.head logs
  where logs = getLog v

getLastTerm :: LogVector -> Term
getLastTerm v | U.null logs = 0
              | otherwise   = logTerm $ U.head logs
  where logs = getLog v

-- Iterates the random generator for 32 bits
nextRandomNum :: Xorshift32 -> Xorshift32
nextRandomNum (Xorshift32 a) = Xorshift32 d
  where b = a `xor` shiftL a 13
        c = b `xor` shiftR b 17
        d = c `xor` shiftL c 5

newLogger :: IO (Chan LogMessage)
newLogger = do
  logs <- newChan
  void . forkIO . forever $ do
    msg <- readChan logs
    hPrintf stderr "%s Term %03d %-9s: %s\n" (show $ msgNodeId msg)
      (msgTerm msg) (show $ msgRole msg) (msgString msg)
    hFlush stderr
  return logs

writeLogger :: MVar ServerState -> String -> Process ()
writeLogger mx str = do
  st  <- readMVar mx
  nid <- getSelfNode
  liftIO $ writeChan (selfLogger st)
    LogMessage { msgNodeId = nid
               , msgTerm   = currTerm st
               , msgRole   = currRole st
               , msgString = str
               }

newMailbox :: IO Mailbox
newMailbox = do
  start  <- atomically newEmptyTMVar
  box    <- newChan
  mNodes <- newMVar []
  void . forkIO . forever $ do
    msg     <- readChan box
    nidList <- readMVar mNodes
    let nid = msgNodeId msg
    when (nid `notElem` nidList) $ do
      printf "%s Term %03d %-9s: %s\n" (show $ msgNodeId msg)
        (msgTerm msg) (show $ msgRole msg) (msgString msg)
      hFlush stdout
    modifyMVar_ mNodes $ return . (nid :)
  return Mailbox { putMsg = start
                 , msgBox = box
                 }

registerMailbox :: MVar ServerState -> Mailbox -> Process ()
registerMailbox mx mailbox = do
  pid <- getSelfPid
  nid <- getSelfNode
  void . spawnLocal $ do
    link pid
    liftIO $ do
      atomically $ isEmptyTMVar (putMsg mailbox) >>= check . not
      st <- readMVar mx
      let str = show . U.reverse . U.dropWhile ((> commitIndex st) . logIndex)
                . getLog $ currVec st
      writeChan (msgBox mailbox)
        LogMessage { msgNodeId = nid
                   , msgTerm   = currTerm st
                   , msgRole   = currRole st
                   , msgString = str
                   }

putMessages :: Mailbox -> IO ()
putMessages mailbox = atomically $ putTMVar (putMsg mailbox) ()

saveSession :: MVar ServerState -> Process ()
saveSession mx = do
  st <- readMVar mx
  let term = currTerm st
      bs   = endPointAddressToByteString . nodeAddress <$> votedFor st
      logs = currVec st
      cIdx = commitIndex st
  liftIO . BC.writeFile (sessionFile st) $ encode (term, bs, logs, cIdx)

restoreSession :: FilePath -> Process (Term, Maybe LeaderId, LogVector, Int)
restoreSession file = do
  (term, bs, logs, cIdx) <- liftIO . handle fileHandler
                            $ either error id . decode <$> BC.readFile file
  return (term, toVoted bs, logs, cIdx)
    where fileHandler e
            | isDoesNotExistError e = return (0, Nothing, LogVector U.empty, 0)
            | otherwise             = throwIO e

          toVoted :: Maybe BC.ByteString -> Maybe LeaderId
          toVoted = fmap (NodeId . EndPointAddress)
