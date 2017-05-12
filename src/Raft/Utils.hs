module Raft.Utils
  (
    randomElectionTimeout
  ) where

import           Control.Distributed.Process (Process, liftIO)
import           System.Random               (randomRIO)

randomElectionTimeout :: Int -> Process Int
randomElectionTimeout base =
  liftIO $ ((base `div` 1000) *) <$> randomRIO (1000, 2000)
