module Types
  (
    Node(..)
  , Config(..)
  , Parameters(..)
  ) where

import           Data.Char                    (isDigit)
import           Text.ParserCombinators.ReadP

type Host = String
type Port = String
data Node = Node Host Port

instance Show Node where
  show (Node host port) = host ++ ":" ++ port

instance Read Node where
  readsPrec _ = readP_to_S $ Node <$> munch1 (/= ':') <* get <*> munch1 isDigit

data Config = Config { sendPeriod  :: Int
                     , gracePeriod :: Int
                     , msgSeed     :: Int
                     , nodeConf    :: FilePath
                     }

data Parameters = RunParams Config
                | TestParams Config Node
