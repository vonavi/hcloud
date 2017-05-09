module Types
  (
    Node(..)
  , Config(..)
  , Parameters(..)
  ) where

data Node = Node String Int

instance Show Node where
  show (Node host port) = host ++ ":" ++ show port

instance Read Node where
  readsPrec d s = [ (Node host port, v)
                  | (":", u)  <- lex t
                  , (port, v) <- readsPrec d u
                  ]
    where (host, t) = break (== ':') s

data Config = Config { sendPeriod  :: Int
                     , gracePeriod :: Int
                     , msgSeed     :: Int
                     , nodeConf    :: FilePath
                     }

data Parameters = RunParams Config
                | TestParams Config Node
