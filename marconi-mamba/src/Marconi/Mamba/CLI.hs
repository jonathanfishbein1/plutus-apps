module Marconi.Mamba.CLI where

import Data.Maybe (fromMaybe)
import Options.Applicative (Parser, ParserInfo, auto, execParser, fullDesc, header, help, helper, info, infoOption,
                            long, metavar, option, optional, progDesc, strOption)
import System.Environment (lookupEnv)

import Marconi.ChainIndex.CLI (multiString, pNetworkId)
import Marconi.Mamba.Api.Types (CliArgs (CliArgs))


-- | parse cli arguments
--
parserCliArgs :: Parser CliArgs
parserCliArgs = CliArgs
  <$> strOption
      (  long "socket-path"
      <> metavar "FILE-PATH"
      <> help "Socket path to node"
      )
  <*> strOption
      (  long "db-dir"
      <> metavar "DIR"
      <> help "Directory path that will contain all the SQLite databases"
      )
  <*> (optional . strOption)
      (  long "utxo-db-fname"
      <> metavar "FILE-NAME"
      <> help "File name of the utxo database."
      )
  <*> (optional . option  auto)
      (  long "http-port"
      <> metavar "HTTP-PORT"
      <> help "JSON-RPC http port number, default is port 3000."
      )
  <*> pNetworkId
  <*> (optional . multiString)
        (  long "addresses-to-index"
        <> metavar "BECH32-ADDRESS"
        <> help (  "Bech32 Shelley addresses to index."
                <> " i.e \"--address-to-index address-1 --address-to-index address-2 ...\""
                )
        )

parserOpts  :: String -> ParserInfo CliArgs
parserOpts sha =
    info (helper
          <*> versionOption
          <*> parserCliArgs)
    ( fullDesc
      <> progDesc "marconi-mamba"
      <> header
          "marconi - a lightweight customizable solution for indexing and querying the Cardano blockchain"
    )
    where
        versionOption =
            infoOption sha ( long "version"
                          <> help "Show git SHA"
                           )

parseCli :: IO CliArgs
parseCli = do
    maybeSha <- lookupEnv "GITHUB_SHA"
    let sha = fromMaybe "GIHUB_SHA environment variable not set!" maybeSha
    execParser $ parserOpts sha