{-# LANGUAGE LambdaCase #-}

module Main
  (
    main
  ) where

import           Control.Concurrent               (forkIO, killThread,
                                                   threadDelay)
import           Control.Concurrent.Async         (forConcurrently)
import           Control.Concurrent.Chan          (Chan)
import           Control.Distributed.Process      (NodeId (..), liftIO,
                                                   spawnLocal)
import           Control.Distributed.Process.Node (closeLocalNode,
                                                   initRemoteTable,
                                                   newLocalNode, runProcess)
import           Control.Exception                (catch, throwIO)
import           Control.Monad                    (forM_, forever, void)
import           Control.Monad.Trans.State        (StateT, evalStateT, get, put)
import qualified Data.ByteString.Char8            as BC
import           Data.List                        (delete)
import qualified Data.Map.Strict                  as M
import           Data.Word                        (Word32)
import           Network.Transport                (EndPointAddress (..),
                                                   closeTransport)
import           Network.Transport.TCP            (createTransport,
                                                   defaultTCPParameters)
import           Options.Applicative              (execParser)
import           System.Directory                 (getTemporaryDirectory,
                                                   removeFile)
import           System.FilePath.Posix            ((</>))
import           System.IO.Error                  (isDoesNotExistError)
import           System.Random                    (randomRIO)
import           System.Random.Shuffle            (shuffleM)

import           Parameters                       (getParameters)
import           Raft                             (initRaft)
import           Raft.Types                       (Mailbox (..),
                                                   RaftParams (..))
import           Raft.Utils                       (newLogger, newMailbox,
                                                   putMessages, writeLogger)
import           Types

main :: IO ()
main = do
  logs    <- newLogger
  mailbox <- newMailbox
  execParser getParameters >>= \case
    RunParams cfg -> do
      nodeEndPoints <- map read . lines <$> readFile (nodeConf cfg)
      files         <- mapM tempSessionFile nodeEndPoints
      mapM_ rmSessionFile files
      let nidList = map mkNodeId nodeEndPoints
          storage = M.fromList $ zip nidList files
      connections <- forConcurrently nodeEndPoints $ \ept -> do
        let nid    = mkNodeId ept
            params = RaftParams
                     { raftPeers   = delete nid nidList
                     , raftSeed    = msgSeed cfg
                     , raftFile    = storage M.! nid
                     , raftLogger  = logs
                     , raftMailbox = mailbox
                     }
        startServer params ept
      sendThenPutMessages cfg mailbox
      mapM_ (stopServer logs) connections
      mapM_ rmSessionFile files

    TestParams cfg -> do
      nodeEndPoints <- map read . lines <$> readFile (nodeConf cfg)
      files         <- mapM tempSessionFile nodeEndPoints
      mapM_ rmSessionFile files
      let nidList = map mkNodeId nodeEndPoints
          nodeCfg = NodeConfig
                    { stopEpts  = nodeEndPoints
                    , startEpts = []
                    , allNodes  = nidList
                    , nodeMap   = M.empty
                    , fileMap   = M.fromList $ zip nidList files
                    }
      tid <- forkIO . flip evalStateT nodeCfg
             $ runTest (msgSeed cfg) logs mailbox
      sendThenPutMessages cfg mailbox
      killThread tid
      mapM_ rmSessionFile files

startServer :: RaftParams -> NodeEndPoint -> IO Connection
startServer params ept = do
  tr   <- either (error . show) id
          <$> createTransport (getHost ept) (getPort ept) defaultTCPParameters
  node <- newLocalNode tr initRemoteTable
  runProcess node $ do
    writeLogger (raftLogger params) "starting server..."
    void . spawnLocal $ initRaft params
  return (tr, node)

stopServer :: Chan String -> Connection -> IO ()
stopServer logs (tr, node) = do
  runProcess node $ writeLogger logs "stopping server..."
  closeTransport tr
  closeLocalNode node

runTest :: Word32 -> Chan String -> Mailbox -> StateT NodeConfig IO ()
runTest seed logs mailbox = forever $ do
  nodeCfg <- get
  -- The majority of nodes should be always connected
  let n = length $ allNodes nodeCfg
  numOfNodes <- liftIO $ randomRIO ((n + 2) `div` 2, n)

  let delta = numOfNodes - length (startEpts nodeCfg)
  case compare delta 0 of
    EQ -> return ()

    GT -> do (up, down) <- liftIO $ randomSplit delta (stopEpts nodeCfg)
             kvs        <- liftIO $ forConcurrently up $ \ept -> do
               let nid    = mkNodeId ept
                   params = RaftParams
                            { raftPeers   = delete nid $ allNodes nodeCfg
                            , raftSeed    = seed
                            , raftFile    = fileMap nodeCfg M.! nid
                            , raftLogger  = logs
                            , raftMailbox = mailbox
                            }
               conn <- startServer params ept
               return (nid, conn)
             let updMap = foldr (uncurry M.insert) (nodeMap nodeCfg) kvs
             put nodeCfg { stopEpts  = down
                         , startEpts = up ++ startEpts nodeCfg
                         , nodeMap   = updMap
                         }

    LT -> do (down, up) <- liftIO
                           $ randomSplit (negate delta) (startEpts nodeCfg)
             liftIO . forM_ down
               $ \ept -> stopServer logs $ nodeMap nodeCfg M.! mkNodeId ept
             let updMap = foldr (M.delete . mkNodeId) (nodeMap nodeCfg) down
             put nodeCfg { stopEpts  = down ++ stopEpts nodeCfg
                         , startEpts = up
                         , nodeMap   = updMap
                         }

  -- Random delay before the next re-connection
  liftIO $ randomRIO (0, 2000) >>= threadDelay . (1000 *)

sendThenPutMessages :: Config -> Mailbox -> IO ()
sendThenPutMessages cfg mailbox = do
  threadDelay (1000000 * sendPeriod cfg)
  putMessages mailbox
  threadDelay (1000000 * gracePeriod cfg)

randomSplit :: Int -> [a] -> IO ([a], [a])
randomSplit n = fmap (splitAt n) . shuffleM

mkNodeId :: NodeEndPoint -> NodeId
mkNodeId (NodeEndPoint host port) = NodeId . EndPointAddress . BC.concat
                                    . map BC.pack $ [host, ":", port, ":0"]

tempSessionFile :: NodeEndPoint -> IO FilePath
tempSessionFile ept = do
  dir <- getTemporaryDirectory
  return $ dir </> getHost ept ++ ":" ++ getPort ept ++ ".tmp"

rmSessionFile :: FilePath -> IO ()
rmSessionFile file = removeFile file `catch` fileHandler
  where fileHandler e
          | isDoesNotExistError e = return ()
          | otherwise             = throwIO e
