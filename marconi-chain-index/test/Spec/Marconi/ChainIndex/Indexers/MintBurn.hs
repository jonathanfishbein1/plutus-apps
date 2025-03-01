{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Spec.Marconi.ChainIndex.Indexers.MintBurn (tests) where

import Cardano.Api qualified as C
import Cardano.BM.Setup (withTrace)
import Cardano.BM.Trace (logError)
import Cardano.BM.Tracing (defaultConfigStdout)
import Cardano.Streaming (ChainSyncEventException (NoIntersectionFound), withChainSyncEventStream)
import Control.Concurrent qualified as IO
import Control.Concurrent.Async qualified as IO
import Control.Concurrent.STM qualified as IO
import Control.Exception (catch)
import Control.Lens ((^.))
import Control.Monad (forM, forM_, unless, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson qualified as Aeson
import Data.Coerce (coerce)
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Word (Word64)
import Gen.Marconi.ChainIndex.Indexers.MintBurn qualified as Gen
import Hedgehog (Property, forAll, tripping, (===))
import Hedgehog qualified as H
import Hedgehog.Extras.Test qualified as HE
import Hedgehog.Extras.Test.Base qualified as H
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Helpers qualified as TN
import Marconi.ChainIndex.Indexers qualified as M
import Marconi.ChainIndex.Indexers.MintBurn (MintAsset (MintAsset), MintBurnHandle (MintBurnHandle),
                                             StorableQuery (QueryAllMintBurn, QueryByAssetId),
                                             StorableResult (MintBurnResult))
import Marconi.ChainIndex.Indexers.MintBurn qualified as MintBurn
import Marconi.ChainIndex.Logging ()
import Marconi.ChainIndex.TestLib.StorableProperties qualified as StorableProperties
import Marconi.Core.Storable qualified as RI
import Prettyprinter (defaultLayoutOptions, layoutPretty, pretty, (<+>))
import Prettyprinter.Render.Text (renderStrict)
import Streaming.Prelude qualified as S
import System.Directory qualified as IO
import System.FilePath ((</>))
import Test.Base qualified as H
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testPropertyNamed)
import Testnet.Cardano qualified as TN

-- | Each test case is described beside every top level property
-- declaration.
tests :: TestTree
tests = testGroup "MintBurn"
  [ testPropertyNamed
      "Mints in `TxBodyContent` survive `makeTransactionBody` and end up in expected place in `TxBody`"
      "mintsPreserved" mintsPreserved
  , testPropertyNamed
      "Querying everything should return all indexed event"
      "propQueryingEverythingShouldReturnAllIndexedEvents"
      propQueryingEverythingShouldReturnAllIndexedEvents
  , testPropertyNamed
      "Querying a recreated indexer should only the persisted events, and not the in-memory events of the initial indexer"
      "propRecreatingIndexerFromDiskShouldOnlyReturnPersistedEvents "
      propRecreatingIndexerFromDiskShouldOnlyReturnPersistedEvents
  , testPropertyNamed
      "Querying mint events by AssetId all possible AssetIds should yield same results as querying everything"
      "propQueryingAssetIdsIndividuallyShouldBeSameAsQueryingAll"
      propQueryingAssetIdsIndividuallyShouldBeSameAsQueryingAll
  , testPropertyNamed
      "Querying everything at target slot should return all rows from genesis until that slot"
      "propQueryingAllMintBurnAtPointShouldReturnMintsUntilThatPoint"
      propQueryingAllMintBurnAtPointShouldReturnMintsUntilThatPoint
  , testPropertyNamed
      "Querying by AssetId all possible AssetIds at target slot should yield same results as querying everything until that slot"
      "propQueryingAssetIdsIndividuallyAtPointShouldBeSameAsQueryingAllAtPoint"
      propQueryingAssetIdsIndividuallyAtPointShouldBeSameAsQueryingAllAtPoint
  , testPropertyNamed
      "Querying all mint burn should be the same as querying all mint burn at latest indexed slot"
      "propQueryingAllMintBurnAtLatestPointShouldBeSameAsAllMintBurnQuery"
      propQueryingAllMintBurnAtLatestPointShouldBeSameAsAllMintBurnQuery
  , testPropertyNamed
      "Querying mint burn by AssetId should be the same as querying by AssetId at latest indexed slot"
      "propQueryingAssetIdsAtLatestPointShouldBeSameAsAssetIdsQuery"
      propQueryingAssetIdsAtLatestPointShouldBeSameAsAssetIdsQuery
  , testPropertyNamed
      "The points the indexer can be resumed from should return at least the genesis point"
      "propResumingShouldReturnAtLeastTheGenesisPoint"
      propResumingShouldReturnAtLeastTheGenesisPoint
  , testPropertyNamed
      "The points that indexer can be resumed from should be sorted in descending order"
      "propResumablePointsShouldBeSortedInDescOrder"
      propResumablePointsShouldBeSortedInDescOrder
  , testPropertyNamed
      "Rewinding to any slot forgets any newer events than that slot"
      "rewind" rewind
  , testPropertyNamed
      "Intervals work as expected"
      "intervals" intervals
  , testPropertyNamed
      "Indexing a testnet and then submitting a transaction with a mint event to it has the indexer receive that mint event"
      "endToEnd" endToEnd
  , testPropertyNamed
      "ToJSON/FromJSON roundtrip for TxMintRow"
      "propJsonRoundtripTxMintRow" propJsonRoundtripTxMintRow
  ]

-- | This is a sanity-check test that turns a TxBodyContent with mint
-- events into a TxBody through `makeTransactionBody` and checks if
-- the mint events are found in the result. It doesn't test an
-- indexer.
mintsPreserved :: Property
mintsPreserved = H.property $ do
  mintValue <- forAll Gen.genTxMintValue
  C.Tx txb _ :: C.Tx C.AlonzoEra <- forAll (Gen.genTxWithMint mintValue) >>= \case
    Left err  -> fail $ "TxBodyError: " <> show err
    Right tx' -> return tx'
  -- Index the transaction:
  let mints = MintBurn.txbMints txb
      gottenPolicyAssets = map (\mint -> (MintBurn.mintAssetPolicyId mint, MintBurn.mintAssetAssetName mint, MintBurn.mintAssetQuantity mint)) mints
  -- Print footnote should the test fail:
  let generatedPolicyAssets = getPolicyAssets mintValue
  H.footnote $ "Assets to be created: " <> show generatedPolicyAssets <> "\n"
            <> "Assets gotten: " <> show gottenPolicyAssets
  -- The assets that were used to construct the transaction were found
  -- in the generate transaction:
  equalSet generatedPolicyAssets gottenPolicyAssets

-- | Create transactions, index them, query indexer and find mint events.
propQueryingEverythingShouldReturnAllIndexedEvents :: Property
propQueryingEverythingShouldReturnAllIndexedEvents = H.property $ do
  (indexer, insertedEvents, _) <- Gen.genIndexWithEvents ":memory:"
  -- Query results:
  MintBurnResult queryResult <- liftIO $ RI.query RI.QEverything indexer $ QueryAllMintBurn Nothing
  -- Compare the sets of events inserted to the indexer and the set
  -- gotten out of the indexer:
  equalSet (MintBurn.groupBySlotAndHash insertedEvents) (MintBurn.fromRows queryResult)

propQueryingAssetIdsIndividuallyShouldBeSameAsQueryingAll :: Property
propQueryingAssetIdsIndividuallyShouldBeSameAsQueryingAll = H.property $ do
  (indexer, insertedEvents, _) <- Gen.genIndexWithEvents ":memory:"
  MintBurnResult allTxMintRows <- liftIO $ RI.query RI.QEverything indexer $ QueryAllMintBurn Nothing

  -- Getting all AssetIds from generated events
  let assetIds = concatMap
            (\e -> concat
                 $ NonEmpty.toList
                 $ fmap (\(_, assets) ->
                     fmap (\(MintAsset policyId assetName _ _ _) -> (policyId, assetName))
                        $ NonEmpty.toList assets)
                 $ MintBurn.txMintEventTxAssets e)
            insertedEvents
  combinedTxMintRows <- fmap concat <$> forM assetIds $ \(policyId, assetName) -> do
      (MintBurnResult rows) <- liftIO $ RI.query RI.QEverything indexer $ QueryByAssetId policyId assetName Nothing
      pure rows

  equalSet allTxMintRows combinedTxMintRows

propQueryingAllMintBurnAtPointShouldReturnMintsUntilThatPoint :: Property
propQueryingAllMintBurnAtPointShouldReturnMintsUntilThatPoint = H.property $ do
  (indexer, insertedEvents, _) <- Gen.genIndexWithEvents ":memory:"
  let possibleSlots = Set.toList $ Set.fromList $ fmap MintBurn.txMintEventSlotNo insertedEvents
  slotNo <- if null possibleSlots then pure (C.SlotNo 0) else forAll $ Gen.element possibleSlots
  MintBurnResult actualTxMints <- liftIO $ RI.query RI.QEverything indexer $ QueryAllMintBurn (Just slotNo)
  let expectedTxMints = filter (\e -> MintBurn.txMintEventSlotNo e <= slotNo) insertedEvents
  equalSet expectedTxMints (MintBurn.fromRows actualTxMints)

propQueryingAssetIdsIndividuallyAtPointShouldBeSameAsQueryingAllAtPoint :: Property
propQueryingAssetIdsIndividuallyAtPointShouldBeSameAsQueryingAllAtPoint = H.property $ do
  (indexer, insertedEvents, _) <- Gen.genIndexWithEvents ":memory:"
  let possibleSlots = Set.toList $ Set.fromList $ fmap MintBurn.txMintEventSlotNo insertedEvents
  slotNo <- if null possibleSlots then pure (C.SlotNo 0) else forAll $ Gen.element possibleSlots
  MintBurnResult allTxMintRows <- liftIO $ RI.query RI.QEverything indexer $ QueryAllMintBurn (Just slotNo)

  -- Getting all AssetIds from generated events
  let assetIds = concatMap
            (\e -> concat
                 $ NonEmpty.toList
                 $ fmap (\(_, assets) ->
                     fmap (\(MintAsset policyId assetName _ _ _) -> (policyId, assetName))
                        $ NonEmpty.toList assets)
                 $ MintBurn.txMintEventTxAssets e)
            insertedEvents
  combinedTxMintRows <- fmap concat <$> forM assetIds $ \(policyId, assetName) -> do
      (MintBurnResult rows) <- liftIO $ RI.query RI.QEverything indexer $ QueryByAssetId policyId assetName (Just slotNo)
      pure rows

  equalSet allTxMintRows combinedTxMintRows

propQueryingAllMintBurnAtLatestPointShouldBeSameAsAllMintBurnQuery :: Property
propQueryingAllMintBurnAtLatestPointShouldBeSameAsAllMintBurnQuery = H.property $ do
  (indexer, insertedEvents, _) <- Gen.genIndexWithEvents ":memory:"
  let possibleSlots = fmap MintBurn.txMintEventSlotNo insertedEvents
      latestSlotNo = if null possibleSlots then C.SlotNo 0 else List.maximum possibleSlots
  MintBurnResult allTxMintRows <- liftIO $ RI.query RI.QEverything indexer $ QueryAllMintBurn Nothing
  MintBurnResult txMintRowsAtSlot <- liftIO $ RI.query RI.QEverything indexer $ QueryAllMintBurn (Just latestSlotNo)
  equalSet allTxMintRows txMintRowsAtSlot

propQueryingAssetIdsAtLatestPointShouldBeSameAsAssetIdsQuery :: Property
propQueryingAssetIdsAtLatestPointShouldBeSameAsAssetIdsQuery = H.property $ do
  (indexer, insertedEvents, _) <- Gen.genIndexWithEvents ":memory:"
  let possibleSlots = fmap MintBurn.txMintEventSlotNo insertedEvents
      latestSlotNo = if null possibleSlots then C.SlotNo 0 else List.maximum possibleSlots

  -- Getting all AssetIds from generated events
  let assetIds = concatMap
            (\e -> concat
                 $ NonEmpty.toList
                 $ fmap (\(_, assets) ->
                     fmap (\(MintAsset policyId assetName _ _ _) -> (policyId, assetName))
                        $ NonEmpty.toList assets)
                 $ MintBurn.txMintEventTxAssets e)
            insertedEvents

  forM_ assetIds $ \(policyId, assetName) -> do
      (MintBurnResult allTxMintRows) <- liftIO $ RI.query RI.QEverything indexer $ QueryByAssetId policyId assetName Nothing
      (MintBurnResult txMintRowsAtSlot) <- liftIO $ RI.query RI.QEverything indexer $ QueryByAssetId policyId assetName (Just latestSlotNo)
      equalSet allTxMintRows txMintRowsAtSlot


-- | Insert some events to an indexer, then recreate it from what is
-- on disk (the in-memory part is lost), then query it and find all
-- persisted events and none of the in-memory events.
propRecreatingIndexerFromDiskShouldOnlyReturnPersistedEvents :: Property
propRecreatingIndexerFromDiskShouldOnlyReturnPersistedEvents = H.property $ do
  -- Index events that overflow:
  (indexer, events, (bufferSize, _nTx)) <- Gen.genIndexWithEvents ":memory:"
  -- Open a new indexer based off of the old indexers sql connection:
  indexer' <- liftIO $ mkNewIndexerBasedOnOldDb indexer
  MintBurnResult queryResult <- liftIO $ RI.query RI.QEverything indexer' $ QueryAllMintBurn Nothing
  let expected = MintBurn.groupBySlotAndHash $ take (eventsPersisted (fromIntegral bufferSize) (length events)) events
  -- The test: events that were persisted are exactly those we get from the query.
  equalSet expected (MintBurn.fromRows queryResult)

-- | The property verifies that the 'Storable.resumeFromStorage' call returns at least the
-- 'C.ChainPointAtGenesis' point.
propResumingShouldReturnAtLeastTheGenesisPoint :: Property
propResumingShouldReturnAtLeastTheGenesisPoint = H.property $ do
    (indexer, _, _) <- Gen.genIndexWithEvents ":memory:"
    StorableProperties.propResumingShouldReturnAtLeastTheGenesisPoint indexer

-- | The property verifies that the 'Storable.resumeFromStorage' call returns a sorted list of chain
-- points in descending order.
propResumablePointsShouldBeSortedInDescOrder :: Property
propResumablePointsShouldBeSortedInDescOrder = H.property $ do
    (indexer, _, _) <- Gen.genIndexWithEvents ":memory:"
    StorableProperties.propResumablePointsShouldBeSortedInDescOrder indexer

-- | Test that rewind (rollback for on-disk events) behaves as
-- expected: insert events such that buffer overflows, rollback so far
-- back that some events were already persisted, find no newer events
-- than rollback point in query.
rewind :: Property
rewind = H.property $ do
  (indexer, events, (_bufferSize, nTx)) <- Gen.genIndexWithEvents ":memory:"
  -- Rollback slot is from 0 to number of slots (slot numbers are from 0 to nTx - 1)
  rollbackSlotNo <- fmap coerce $ forAll $ Gen.integral $ Range.constant 0 ((let w64 = fromIntegral nTx in if w64 == 0 then 0 else w64 - 1) :: Word64)
  let cp = C.ChainPoint rollbackSlotNo dummyBlockHeaderHash
  rewoundIndexer <- let errMsg = "Failed to rewind! This shouldn't happen and the test should be fixed"
    in maybe (fail errMsg) pure =<< liftIO (RI.rewind cp indexer)
  MintBurnResult queryResult <- liftIO $ RI.query RI.QEverything rewoundIndexer $ QueryAllMintBurn Nothing
  -- Expect only older than rollback events.
  let expected = filter (\e -> MintBurn.txMintEventSlotNo e <= rollbackSlotNo) events
  equalSet expected (MintBurn.fromRows queryResult)

-- | Test that interval query works.
intervals :: Property
intervals = H.property $ do
  (indexer, events, (_bufferSize, _nTx)) <- Gen.genIndexWithEvents ":memory:"

  let
    cpFromSlot slotNo = C.ChainPoint slotNo dummyBlockHeaderHash
    queryInterval from to = do
      MintBurnResult queryResult <- liftIO $ RI.query (RI.QInterval from to) indexer $ QueryAllMintBurn Nothing
      pure $ MintBurn.fromRows queryResult

  -- Genesis to genesis returns nothing
  H.assert . null =<< queryInterval C.ChainPointAtGenesis C.ChainPointAtGenesis
  -- When there were at least one event created:
  unless (null events) $ do
    let eventCp e = cpFromSlot $ MintBurn.txMintEventSlotNo e
    -- From genesis to "latest slot + 1" returns everything:
    equalSet events =<< (queryInterval C.ChainPointAtGenesis $ cpFromSlot $ MintBurn.txMintEventSlotNo (last events) + 1)
    -- From first event's slot to last event's slot returns everything:
    equalSet events =<< queryInterval (eventCp $ head events) (eventCp $ last events)
    -- Form any slot to genesis returns nothing
    ix <- forAll $ Gen.integral $ Range.constant 0 (length events - 1)
    H.assert . null =<< queryInterval (cpFromSlot $ MintBurn.txMintEventSlotNo $ events !! ix) C.ChainPointAtGenesis

    -- TODO: Enable the following test when there is an API for
    -- getting an actual interval, and/or add another test for when
    -- the meaning of queryInterval is clear.
    --
    -- Form any existing earlier slot to any existing same-or-later slot:
    -- (from, to) <- do
    --   a' <- forAll $ Gen.integral $ Range.constant 0 (length events - 1)
    --   b' <- forAll $ Gen.integral $ Range.constant 0 (length events - 1)
    --   let a = MintBurn.txMintEventSlotNo $ events !! a'
    --       b = MintBurn.txMintEventSlotNo $ events !! b'
    --   return $ if a <= b then (a, b) else (b, a)
    -- let expected = filter (\e -> let slotNo = MintBurn.txMintEventSlotNo e in from <= slotNo && slotNo <= to) events
    -- equalSet expected =<< queryInterval (cpFromSlot from) (cpFromSlot to)

-- | Start testnet, start mint/burn indexer on it, create a single
-- mint event, put it in a transaction and submit it, find the
-- generated event passed back through the indexer.
endToEnd :: Property
endToEnd = H.withShrinks 0 $ H.integration $ (liftIO TN.setDarwinTmpdir >>) $ HE.runFinallies $ H.workspace "." $ \tempPath -> do
  base <- HE.noteM $ liftIO . IO.canonicalizePath =<< HE.getProjectBase
  (localNodeConnectInfo, conf, runtime) <- TN.startTestnet TN.defaultTestnetOptions base tempPath
  let networkId = TN.getNetworkId runtime
  socketPath <- TN.getSocketPathAbs conf runtime

  -- This is the channel we wait on to know if the event has been indexed
  indexedTxs <- liftIO IO.newChan
  -- Start indexer
  liftIO $ do
    coordinator <- M.initialCoordinator 1
    ch <- IO.atomically . IO.dupTChan $ M._channel coordinator
    (loop, _indexerMVar) <- M.mintBurnWorker_ 123 (IO.writeChan indexedTxs) coordinator ch (tempPath </> "db.db")
    void $ IO.async loop
    -- Receive ChainSyncEvents and pass them on to indexer's channel
    void $ IO.async $ do
      let chainPoint = C.ChainPointAtGenesis :: C.ChainPoint
      c <- defaultConfigStdout
      withTrace c "marconi" $ \trace -> let
        indexerWorker = withChainSyncEventStream socketPath networkId [chainPoint] $ S.mapM_ $
          \chainSyncEvent -> IO.atomically $ IO.writeTChan ch chainSyncEvent
        handleException NoIntersectionFound = logError trace $ renderStrict $ layoutPretty defaultLayoutOptions $
          "No intersection found for chain point" <+> pretty chainPoint <> "."
        in indexerWorker `catch` handleException :: IO ()

  -- Create & submit transaction
  pparams <- TN.getProtocolParams @C.AlonzoEra localNodeConnectInfo
  txMintValue <- forAll Gen.genTxMintValue

  genesisVKey :: C.VerificationKey C.GenesisUTxOKey <- TN.readAs (C.AsVerificationKey C.AsGenesisUTxOKey) $ tempPath </> "shelley/utxo-keys/utxo1.vkey"
  genesisSKey :: C.SigningKey C.GenesisUTxOKey <- TN.readAs (C.AsSigningKey C.AsGenesisUTxOKey) $ tempPath </> "shelley/utxo-keys/utxo1.skey"
  let paymentKey = C.castVerificationKey genesisVKey :: C.VerificationKey C.PaymentKey
      address :: C.Address C.ShelleyAddr
      address = C.makeShelleyAddress
        networkId
        (C.PaymentCredentialByKey (C.verificationKeyHash paymentKey :: C.Hash C.PaymentKey))
        C.NoStakeAddress :: C.Address C.ShelleyAddr

  value <- H.fromJustM $ getValue txMintValue
  (txIns, lovelace) <- TN.getAddressTxInsValue @C.AlonzoEra localNodeConnectInfo address

  let keyWitnesses = [C.WitnessPaymentKey $ C.castSigningKey genesisSKey]
      mkTxOuts lovelace' = [TN.mkAddressValueTxOut address $ C.TxOutValue C.MultiAssetInAlonzoEra $ C.lovelaceToValue lovelace' <> value]
      validityRange = (C.TxValidityNoLowerBound, C.TxValidityNoUpperBound C.ValidityNoUpperBoundInAlonzoEra)
  (feeLovelace, txbc) <- TN.calculateAndUpdateTxFee pparams networkId (length txIns) (length keyWitnesses) (TN.emptyTxBodyContent validityRange pparams)
    { C.txIns = map (, C.BuildTxWith $ C.KeyWitness C.KeyWitnessForSpending) txIns
    , C.txOuts = mkTxOuts 0
    , C.txProtocolParams = C.BuildTxWith $ Just pparams
    , C.txMintValue = txMintValue
    , C.txInsCollateral = C.TxInsCollateral C.CollateralInAlonzoEra txIns
    }
  txBody :: C.TxBody C.AlonzoEra <- H.leftFail $ C.makeTransactionBody $ txbc
    { C.txOuts = mkTxOuts $ lovelace - feeLovelace }
  let keyWitnesses' :: [C.KeyWitness C.AlonzoEra]
      keyWitnesses' = map (C.makeShelleyKeyWitness txBody) keyWitnesses
  TN.submitTx localNodeConnectInfo $ C.makeSignedTransaction keyWitnesses' txBody

  -- Receive event from the indexer, compare the mint that we
  -- submitted above with the one we got from the indexer.
  event <- liftIO $ IO.readChan indexedTxs
  case MintBurn.txMintEventTxAssets event of
     (_txId, gottenMintEvents :: NonEmpty MintAsset) :| [] -> let
       in equalSet (mintsToPolicyAssets $ NonEmpty.toList gottenMintEvents) (getPolicyAssets txMintValue)
     _ -> fail "More than one mint/burn event, but we created only one!"

propJsonRoundtripTxMintRow :: Property
propJsonRoundtripTxMintRow = H.property $ do
    mintEvents <- forAll Gen.genMintEvents
    let mpsTxRows = concatMap MintBurn.toRows $ fst mintEvents
    forM_ mpsTxRows $ \txMintRow -> Hedgehog.tripping txMintRow Aeson.encode Aeson.decode

-- * Helpers

eventsPersisted :: Int -> Int -> Int
eventsPersisted bufferSize nEvents = let
  -- Number of buffer flushes
  bufferFlushesN = let
    (n, m) = nEvents `divMod` bufferSize
    in if m == 0 then n - 1 else n
  -- Number of events persisted
  numberOfEventsPersisted = bufferFlushesN * bufferSize
  in numberOfEventsPersisted

-- | Recreate an indexe, useful because the sql connection to a
-- :memory: database can be reused.
mkNewIndexerBasedOnOldDb :: RI.State MintBurnHandle -> IO (RI.State MintBurnHandle)
mkNewIndexerBasedOnOldDb indexer = let
    MintBurnHandle sqlCon k = indexer ^. RI.handle
  in RI.emptyState (fromIntegral k) (MintBurnHandle sqlCon k)

dummyBlockHeaderHash :: C.Hash C.BlockHeader
dummyBlockHeaderHash = fromString "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" :: C.Hash C.BlockHeader

equalSet :: (H.MonadTest m, Show a, Ord a) => [a] -> [a] -> m ()
equalSet a b = Set.fromList a === Set.fromList b

getPolicyAssets :: C.TxMintValue C.BuildTx C.AlonzoEra -> [(C.PolicyId, C.AssetName, C.Quantity)]
getPolicyAssets txMintValue = case txMintValue of
  (C.TxMintValue C.MultiAssetInAlonzoEra mintedValues (C.BuildTxWith _policyIdToWitnessMap)) ->
    mapMaybe (\(assetId, quantity) -> case assetId of
             C.AssetId policyId assetName -> Just (policyId, assetName, quantity)
             C.AdaAssetId                 -> Nothing
        ) $ C.valueToList mintedValues
  _ -> []

getValue :: C.TxMintValue C.BuildTx C.AlonzoEra -> Maybe C.Value
getValue = \case
  C.TxMintValue C.MultiAssetInAlonzoEra value (C.BuildTxWith _policyIdToWitnessMap) -> Just value
  _                                                                                 -> Nothing

mintsToPolicyAssets :: [MintAsset] -> [(C.PolicyId, C.AssetName, C.Quantity)]
mintsToPolicyAssets =
  map (\mint -> (MintBurn.mintAssetPolicyId mint, MintBurn.mintAssetAssetName mint, MintBurn.mintAssetQuantity mint))
