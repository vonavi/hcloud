module Raft
  (
    initRaft
  ) where

import           Control.Concurrent          (threadDelay)
import           Control.Distributed.Process (Process, liftIO, say)

import           Types

initRaft :: Config -> Process ()
initRaft cfg = do say "hello world"
                  liftIO . threadDelay $ 1000000 * gracePeriod cfg
