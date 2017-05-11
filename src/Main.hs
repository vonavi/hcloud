{-# LANGUAGE LambdaCase #-}

module Main
  (
    main
  ) where

import           Control.Concurrent               (forkIO, threadDelay)
import           Control.Concurrent.Async         (forConcurrently_)
import           Control.Distributed.Process      (NodeId (..), Process,
                                                   expectTimeout, getSelfPid,
                                                   kill, liftIO, nsendRemote,
                                                   register, spawnLocal)
import           Control.Distributed.Process.Node (initRemoteTable,
                                                   newLocalNode, runProcess)
import           Control.Monad                    (forM_, when)
import qualified Data.ByteString.Char8            as BC
import           Data.List                        (delete)
import           Data.Maybe                       (isNothing)
import           Network.Transport                (EndPointAddress (..))
import           Network.Transport.TCP            (createTransport,
                                                   defaultTCPParameters)
import           Options.Applicative              (execParser)

import           Parameters                       (getParameters)
import           Raft                             (initRaft)
import           Types

main :: IO ()
main = execParser getParameters >>= \case
  RunParams cfg      -> do
    nodeEndPoints <- map read . lines <$> readFile (nodeConf cfg)
    forConcurrently_ nodeEndPoints
      $ \ept -> do let peers = mkPeerList ept nodeEndPoints
                   sendMessages ept peers (sendPeriod cfg)
    liftIO . threadDelay . (1000000 *) $ sendPeriod cfg + gracePeriod cfg

  TestParams cfg ept -> do
    nodeEndPoints <- map read . lines <$> readFile (nodeConf cfg)
    let peers = mkPeerList ept nodeEndPoints
    _ <- forkIO $ sendMessages ept peers (sendPeriod cfg)
    liftIO . threadDelay . (1000000 *) $ sendPeriod cfg + gracePeriod cfg

sendMessages :: NodeEndPoint -> [NodeId] -> Int -> IO ()
sendMessages ept peers period = do
  tr   <- either (error . show) id
          <$> createTransport (getHost ept) (getPort ept) defaultTCPParameters
  node <- newLocalNode tr initRemoteTable
  runProcess node $ do
    pid <- spawnLocal initRaft
    getSelfPid >>= register receiverName
    res <- expectTimeout (1000000 * period) :: Process (Maybe StopMessage)
    kill pid "Send period is over"
    when (isNothing res) . forM_ peers
      $ \p -> nsendRemote p receiverName stopMessage

mkPeerList :: NodeEndPoint -> [NodeEndPoint] -> [NodeId]
mkPeerList ept = delete (mkNodeId ept) . map mkNodeId

mkNodeId :: NodeEndPoint -> NodeId
mkNodeId (NodeEndPoint host port) = NodeId . EndPointAddress . BC.concat
                                    . map BC.pack $ [host, ":", port, ":0"]
