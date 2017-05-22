{-# LANGUAGE FlexibleContexts #-}

module Raft.Utils
  (
    isTermStale
  , syncWithTerm
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
import           Data.Function                                (on)
import           Data.Serialize                               (decode, encode)
import qualified Data.Vector.Unboxed                          as U
import           Data.Word                                    (Word32)
import           Network.Transport                            (EndPointAddress (..))
import           System.IO                                    (hFlush, stderr,
                                                               stdout)
import           System.IO.Error                              (isDoesNotExistError)
import           System.Random                                (randomRIO)
import           Text.Printf                                  (hPrintf)

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
      putStrLn $ show nid ++ ": " ++ msgString msg
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
      let applied    = lastApplied st
          logApplied = U.dropWhile ((> applied) . logIndex)
                       . getLog $ currVec st
      writeChan (msgBox mailbox)
        LogMessage { msgNodeId = nid
                   , msgTerm   = currTerm st
                   , msgRole   = currRole st
                   , msgString = show (applied, weightedSum logApplied)
                   }
        where weightedSum = U.sum . U.map weight
              weight :: LogEntry -> Double
              weight LogEntry { logIndex = i, logSeed = x } =
                let n = ((/) `on` fromIntegral) (word32 x) (maxBound :: Word32)
                in fromIntegral i * n

putMessages :: Mailbox -> IO ()
putMessages mailbox = atomically $ putTMVar (putMsg mailbox) ()

saveSession :: MVar ServerState -> Process ()
saveSession mx = do
  st <- readMVar mx
  liftIO . BC.writeFile (sessionFile st)
    $ encode PersistentState { sessTerm        = currTerm st
                             , sessVotedFor    = endPointAddressToByteString
                                                 . nodeAddress <$> votedFor st
                             , sessVec         = currVec st
                             , sessCommitIdx   = commitIndex st
                             , sessLastApplied = lastApplied st
                             }

restoreSession :: FilePath -> Process PersistentState
restoreSession file =
  liftIO . handle fileHandler $ either error id . decode <$> BC.readFile file
  where fileHandler e
          | isDoesNotExistError e = return emptySession
          | otherwise             = throwIO e

        emptySession = PersistentState { sessTerm        = 0
                                       , sessVotedFor    = Nothing
                                       , sessVec         = LogVector U.empty
                                       , sessCommitIdx   = 0
                                       , sessLastApplied = 0
                                       }
