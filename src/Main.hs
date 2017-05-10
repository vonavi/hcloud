{-# LANGUAGE LambdaCase #-}

module Main
  (
    main
  ) where

import           Control.Distributed.Backend.P2P  (bootstrap, makeNodeId)
import           Control.Distributed.Process      (NodeId)
import           Control.Distributed.Process.Node (initRemoteTable)
import           Data.Foldable                    (forM_)
import           Data.List                        (delete)
import           Options.Applicative              (execParser)

import           Parameters                       (getParameters)
import           Raft                             (initRaft)
import           Types

main :: IO ()
main = execParser getParameters >>= \case
  RunParams  cfg     -> do
    nodeEndPoints <- map read . lines <$> readFile (nodeConf cfg)
    forM_ nodeEndPoints $ \ept -> do
      let seeds = mkSeedList ept nodeEndPoints
      bootstrap (getHost ept) (getPort ept) seeds initRemoteTable (initRaft cfg)
  TestParams cfg ept -> do
    nodeEndPoints <- map read . lines <$> readFile (nodeConf cfg)
    let seeds = mkSeedList ept nodeEndPoints
    bootstrap (getHost ept) (getPort ept) seeds initRemoteTable (initRaft cfg)

mkSeedList :: NodeEndPoint -> [NodeEndPoint] -> [NodeId]
mkSeedList nodeEpt = delete (helper nodeEpt) . map helper
  where helper (NodeEndPoint host port) = makeNodeId $ host ++ ":" ++ port
