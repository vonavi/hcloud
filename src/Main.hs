{-# LANGUAGE LambdaCase #-}

module Main
  (
    main
  ) where

import           Control.Concurrent               (forkIO, killThread,
                                                   threadDelay)
import           Control.Concurrent.Async         (forConcurrently)
import           Control.Distributed.Process      (NodeId (..), liftIO,
                                                   spawnLocal)
import           Control.Distributed.Process.Node (LocalNode, closeLocalNode,
                                                   initRemoteTable,
                                                   newLocalNode, runProcess)
import           Control.Monad                    (forM_, forever, void)
import           Control.Monad.Trans.State        (StateT, evalStateT, get, put)
import qualified Data.ByteString.Char8            as BC
import           Data.List                        (delete)
import qualified Data.Map.Strict                  as M
import           System.Random.Shuffle            (shuffleM)

import           Network.Transport                (EndPointAddress (..))
import           Network.Transport.TCP            (createTransport,
                                                   defaultTCPParameters)
import           Options.Applicative              (execParser)
import           System.Random                    (randomRIO)

import           Parameters                       (getParameters)
import           Raft                             (initRaft)
import           Types

main :: IO ()
main = execParser getParameters >>= \case
  RunParams cfg -> do
    nodeEndPoints <- map read . lines <$> readFile (nodeConf cfg)
    let nidList = map mkNodeId nodeEndPoints
    nodes <- forConcurrently nodeEndPoints
      $ \ept -> do let peers = delete (mkNodeId ept) nidList
                   startLocalNode ept peers cfg
    waitForSeconds $ sendPeriod cfg + gracePeriod cfg
    mapM_ closeLocalNode nodes

  TestParams cfg -> do
    nodeEndPoints <- map read . lines <$> readFile (nodeConf cfg)
    let nodeCfg = NodeConfig { stopEpts  = nodeEndPoints
                             , startEpts = []
                             , allNodes  = map mkNodeId nodeEndPoints
                             , nodeMap   = M.empty
                             }
    tid <- forkIO $ evalStateT (runTest cfg) nodeCfg
    waitForSeconds $ sendPeriod cfg + gracePeriod cfg
    killThread tid

startLocalNode :: NodeEndPoint -> [NodeId] -> Config -> IO LocalNode
startLocalNode ept peers cfg = do
  tr   <- either (error . show) id
          <$> createTransport (getHost ept) (getPort ept) defaultTCPParameters
  node <- newLocalNode tr initRemoteTable
  runProcess node . void . spawnLocal $ initRaft peers (msgSeed cfg)
  return node

runTest :: Config -> StateT NodeConfig IO ()
runTest cfg = forever $ do
  nodeCfg <- get
  -- The majority of nodes should be always connected
  let n = length $ allNodes nodeCfg
  numOfNodes <- liftIO $ randomRIO ((n + 2) `div` 2, n)

  let delta = numOfNodes - length (startEpts nodeCfg)
  case compare delta 0 of
    EQ -> return ()

    GT -> do (up, down) <- liftIO $ randomSplit delta (stopEpts nodeCfg)
             kvs        <- liftIO $ forConcurrently up $ \ept -> do
               let nid = mkNodeId ept
               node <- startLocalNode ept (delete nid $ allNodes nodeCfg) cfg
               return (nid, node)
             let updMap = foldr (uncurry M.insert) (nodeMap nodeCfg) kvs
             put nodeCfg { stopEpts  = down
                         , startEpts = up ++ startEpts nodeCfg
                         , nodeMap   = updMap
                         }

    LT -> do (down, up) <- liftIO
                           $ randomSplit (negate delta) (startEpts nodeCfg)
             liftIO . forM_ down $ \ept -> do
               let node = nodeMap nodeCfg M.! mkNodeId ept
               closeLocalNode node
             let updMap = foldr (M.delete . mkNodeId) (nodeMap nodeCfg) down
             put nodeCfg { stopEpts  = down ++ stopEpts nodeCfg
                         , startEpts = up
                         , nodeMap   = updMap
                         }

  -- Random delay before the next re-connection
  liftIO $ randomRIO (0, 2000) >>= threadDelay . (1000 *)

randomSplit :: Int -> [a] -> IO ([a], [a])
randomSplit n = fmap (splitAt n) . shuffleM

mkNodeId :: NodeEndPoint -> NodeId
mkNodeId (NodeEndPoint host port) = NodeId . EndPointAddress . BC.concat
                                    . map BC.pack $ [host, ":", port, ":0"]

waitForSeconds :: Int -> IO ()
waitForSeconds = liftIO . threadDelay . (1000000 *)
