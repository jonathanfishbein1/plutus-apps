{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-} -- Not using all CardanoEra

module Spec.Builtins.SECP256k1(tests) where

import Cardano.Api qualified as C
import Data.Map qualified as Map
import Test.Tasty (TestTree, testGroup)

import Hedgehog qualified as H
import Hedgehog.Extras.Test qualified as HE
import Test.Base qualified as H
import Test.Tasty.Hedgehog (testProperty)

import Helpers (testnetOptionsAlonzo6, testnetOptionsBabbage7, testnetOptionsBabbage8)
import Helpers qualified as TN
import PlutusScripts qualified as PS
import Testnet.Plutus qualified as TN

tests :: TestTree
tests = testGroup "SECP256k1"
  [ testProperty "unable to use SECP256k1 builtins in Alonzo PV6" (verifySchnorrAndEcdsa testnetOptionsAlonzo6)
  , testProperty "unable to use SECP256k1 builtins in Babbage PV7" (verifySchnorrAndEcdsa testnetOptionsBabbage7)
  , testProperty "can use SECP256k1 builtins in Babbage PV8" (verifySchnorrAndEcdsa testnetOptionsBabbage8)
  --, testProperty "can use SECP256k1 builtins in Babbage PV8 (on preview testnet)" (verifySchnorrAndEcdsa localNodeOptionsPreview) -- uncomment to use local node on preview testnet
  ]

{- | Test that builtins: verifySchnorrSecp256k1Signature and verifyEcdsaSecp256k1Signature can only
   be used to mint in Babbage era protocol version 8 and beyond.

   Steps:
    - spin up a testnet
    - build and submit a transaction to mint a token using the two SECP256k1 builtins
    - if pv8+ then query the ledger to see if mint was successful otherwise expect
        "forbidden builtin" error when building tx
-}
verifySchnorrAndEcdsa :: Either TN.LocalNodeOptions TN.TestnetOptions -> H.Property
verifySchnorrAndEcdsa networkOptions = H.integration . HE.runFinallies . TN.workspace "." $ \tempAbsPath -> do

  pv <- TN.pvFromOptions networkOptions
  C.AnyCardanoEra era <- TN.eraFromOptions networkOptions

  -- 1: spin up a testnet or use local node connected to public testnet
  (localNodeConnectInfo, pparams, networkId) <- TN.setupTestEnvironment networkOptions tempAbsPath
  (w1SKey, w1Address) <- TN.w1 tempAbsPath networkId

-- 2: build a transaction

  txIn <- TN.adaOnlyTxInAtAddress era localNodeConnectInfo w1Address

  let
    (verifySchnorrAssetId, verifyEcdsaAssetId, verifySchnorrMintWitness, verifyEcdsaMintWitness) =
      case era of
        C.AlonzoEra  ->
          ( PS.verifySchnorrAssetIdV1,
            PS.verifyEcdsaAssetIdV1,
            PS.verifySchnorrMintWitnessV1 era,
            PS.verifyEcdsaMintWitnessV1 era )
        C.BabbageEra ->
          ( PS.verifySchnorrAssetIdV2,
            PS.verifyEcdsaAssetIdV2,
            PS.verifySchnorrMintWitnessV2 era,
            PS.verifyEcdsaMintWitnessV2 era )

    tokenValues = C.valueFromList [(verifySchnorrAssetId, 4), (verifyEcdsaAssetId, 2)]
    txOut = TN.txOut era (C.lovelaceToValue 3_000_000 <> tokenValues) w1Address
    mintWitnesses = Map.fromList [verifySchnorrMintWitness, verifyEcdsaMintWitness]
    collateral = TN.txInsCollateral era [txIn]
    txBodyContent = (TN.emptyTxBodyContent era pparams)
      { C.txIns = TN.pubkeyTxIns [txIn]
      , C.txInsCollateral = collateral
      , C.txMintValue = TN.txMintValue era tokenValues mintWitnesses
      , C.txOuts = [txOut]
      }

  case pv < 8 of
    True -> do
      -- Assert that "forbidden" error occurs when attempting to use either SECP256k1 builtin
      eitherTx <- TN.buildTx' era txBodyContent w1Address w1SKey networkId
      H.assert $ TN.isTxBodyScriptExecutionError
        "Forbidden builtin function: (builtin verifySchnorrSecp256k1Signature)" eitherTx
      H.assert $ TN.isTxBodyScriptExecutionError
        "Forbidden builtin function: (builtin verifyEcdsaSecp256k1Signature)" eitherTx
      H.success

    False -> do
      -- Build and submit transaction
      signedTx <- TN.buildTx era txBodyContent w1Address w1SKey networkId
      TN.submitTx era localNodeConnectInfo signedTx
      let expectedTxIn = TN.txIn (TN.txId signedTx) 0

      -- Query for txo and assert it contains newly minting tokens to prove successfuluse of SECP256k1 builtins
      resultTxOut <- TN.getTxOutAtAddress era localNodeConnectInfo w1Address expectedTxIn "TN.getTxOutAtAddress"
      txOutHasTokenValue <- TN.txOutHasValue resultTxOut tokenValues
      H.assert txOutHasTokenValue
      H.success