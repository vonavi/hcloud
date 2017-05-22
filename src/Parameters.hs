module Parameters
  (
    getParameters
  ) where

import           Data.Monoid         ((<>))
import           Options.Applicative

import           Types

getParameters :: ParserInfo Parameters
getParameters = info p idm
  where p = hsubparser
            ( command "run" runHelper <> command "test" testHelper )

        runHelper = info (RunParams <$> getConfig)
                    ( fullDesc <> header "Run Cloud Haskell" )

        testHelper = info (TestParams <$> getConfig)
                     ( fullDesc <> header "Test Cloud Haskell" )

getConfig :: Parser Config
getConfig = Config
            <$> option auto ( long "send-for"
                              <> metavar "SEC"
                              <> help "Sending period, in seconds" )
            <*> option auto ( long "wait-for"
                              <> metavar "SEC"
                              <> help "Grace period, in seconds" )
            <*> option auto ( long "with-seed"
                              <> metavar "INT"
                              <> help "Seed value for PRNG" )
            <*> strOption ( long "config"
                            <> metavar "FILE"
                            <> help "Configuration file with nodes" )
