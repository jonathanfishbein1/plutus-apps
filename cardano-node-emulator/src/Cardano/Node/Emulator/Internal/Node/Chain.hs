{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Cardano.Node.Emulator.Internal.Node.Chain where

import Cardano.Api qualified as C
import Cardano.Node.Emulator.Internal.Node.Params (Params)
import Cardano.Node.Emulator.Internal.Node.Validation qualified as Validation
import Control.Lens (alaf, makeLenses, makePrisms, over, view, (%~), (&), (.~))
import Control.Monad.Freer (Eff, Member, Members, send, type (~>))
import Control.Monad.Freer.Extras.Log (LogMsg, logDebug, logInfo, logWarn)
import Control.Monad.Freer.State (State, gets, modify)
import Control.Monad.State qualified as S
import Data.Aeson (FromJSON, ToJSON)
import Data.Foldable (traverse_)
import Data.List ((\\))
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Monoid (Ap (Ap))
import Data.Text (Text)
import Data.Traversable (for)
import GHC.Generics (Generic)
import Ledger (Block, Blockchain, CardanoTx, OnChainTx (Invalid, Valid), Slot (Slot), getCardanoTxCollateralInputs,
               getCardanoTxFee, getCardanoTxId, getCardanoTxTotalCollateral, getCardanoTxValidityRange, txOutValue,
               unOnChain)
import Ledger.Index qualified as Index
import Ledger.Interval qualified as Interval
import Ledger.Tx.CardanoAPI (fromPlutusIndex)
import Ledger.Value.CardanoAPI (lovelaceToValue)
import Plutus.V1.Ledger.Scripts qualified as Scripts
import Prettyprinter (Pretty (pretty), colon, (<+>))

-- | Events produced by the blockchain emulator.
data ChainEvent =
    TxnValidate !C.TxId !CardanoTx ![Text]
    -- ^ A transaction has been validated and added to the blockchain.
    | TxnValidationFail !Index.ValidationPhase !C.TxId !CardanoTx !Index.ValidationError !C.Value ![Text]
    -- ^ A transaction failed to validate. The @Value@ indicates the amount of collateral stored in the transaction.
    | SlotAdd !Slot
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

instance Pretty ChainEvent where
    pretty = \case
        TxnValidate i _ logs             -> "TxnValidate" <+> pretty i <+> pretty logs
        TxnValidationFail p i _ e _ logs -> "TxnValidationFail" <+> pretty p <+> pretty i <> colon <+> pretty e <+> pretty logs
        SlotAdd sl                       -> "SlotAdd" <+> pretty sl

chainEventOnChainTx :: ChainEvent -> Maybe OnChainTx
chainEventOnChainTx (TxnValidate _ tx _)                        = Just (Valid tx)
chainEventOnChainTx (TxnValidationFail Index.Phase2 _ tx _ _ _) = Just (Invalid tx)
chainEventOnChainTx _                                           = Nothing

-- | A pool of transactions which have yet to be validated.
type TxPool = [CardanoTx]

data ChainState = ChainState {
    _chainNewestFirst :: !Blockchain, -- ^ The current chain, with the newest transactions first in the list.
    _txPool           :: !TxPool, -- ^ The pool of pending transactions.
    _index            :: !Index.UtxoIndex, -- ^ The UTxO index, used for validation.
    _chainCurrentSlot :: !Slot -- ^ The current slot number
} deriving (Show, Generic)

emptyChainState :: ChainState
emptyChainState = ChainState [] [] mempty 0

makeLenses ''ChainState

data ChainControlEffect r where
    ProcessBlock :: ChainControlEffect Block
    ModifySlot :: (Slot -> Slot) -> ChainControlEffect Slot

data ChainEffect r where
    QueueTx :: CardanoTx -> ChainEffect ()
    GetCurrentSlot :: ChainEffect Slot
    GetParams :: ChainEffect Params

-- | Make a new block
processBlock :: Member ChainControlEffect effs => Eff effs Block
processBlock = send ProcessBlock

-- | Adjust the current slot number, returning the new slot.
modifySlot :: Member ChainControlEffect effs => (Slot -> Slot) -> Eff effs Slot
modifySlot = send . ModifySlot

queueTx :: Member ChainEffect effs => CardanoTx -> Eff effs ()
queueTx tx = send (QueueTx tx)

getParams :: Member ChainEffect effs => Eff effs Params
getParams = send GetParams

getCurrentSlot :: Member ChainEffect effs => Eff effs Slot
getCurrentSlot = send GetCurrentSlot

type ChainEffs = '[State ChainState, LogMsg ChainEvent]

handleControlChain :: Members ChainEffs effs => Params -> ChainControlEffect ~> Eff effs
handleControlChain params = \case
    ProcessBlock -> do
        pool  <- gets $ view txPool
        slot  <- gets $ view chainCurrentSlot
        idx   <- gets $ view index

        let ValidatedBlock block events idx' =
                validateBlock params slot idx pool

        modify $ txPool .~ []
        modify $ index .~ idx'
        modify $ addBlock block

        traverse_ logEvent events
        pure block

    ModifySlot f -> modify @ChainState (over chainCurrentSlot f) >> gets (view chainCurrentSlot)

logEvent :: Member (LogMsg ChainEvent) effs => ChainEvent -> Eff effs ()
logEvent e = case e of
    SlotAdd{}           -> logDebug e
    TxnValidationFail{} -> logWarn e
    TxnValidate{}       -> logInfo e

handleChain :: (Members ChainEffs effs) => Params -> ChainEffect ~> Eff effs
handleChain params = \case
    QueueTx tx     -> modify $ over txPool (addTxToPool tx)
    GetCurrentSlot -> gets _chainCurrentSlot
    GetParams      -> pure params

-- | The result of validating a block.
data ValidatedBlock = ValidatedBlock
    { vlbValid  :: !Block
    -- ^ The transactions that have been validated in this block.
    , vlbEvents :: ![ChainEvent]
    -- ^ Transaction validation events for the transactions in this block.
    , vlbIndex  :: !Index.UtxoIndex
    -- ^ The updated UTxO index after processing the block
    }

data ValidationCtx = ValidationCtx { vctxIndex :: !Index.UtxoIndex, vctxParams :: !Params }

-- | Validate a block given the current slot and UTxO index, returning the valid
--   transactions, success/failure events and the updated UTxO set.
validateBlock :: Params -> Slot -> Index.UtxoIndex -> TxPool -> ValidatedBlock
validateBlock params slot@(Slot s) idx txns =
    let
        -- Validate transactions, updating the UTXO index each time
        (processed, ValidationCtx idx' _) =
            flip S.runState (ValidationCtx idx params) $ for txns $ \tx -> do
                result <- validateEm slot tx
                pure (tx, result)

        -- The new block contains all transaction that were validated
        -- successfully
        block = mapMaybe toOnChain processed
          where
            toOnChain (_ , Left (Index.Phase1, _)) = Nothing
            toOnChain (tx, Left (Index.Phase2, _)) = Just (Invalid tx)
            toOnChain (tx, Right _               ) = Just (Valid tx)

        -- Also return an `EmulatorEvent` for each transaction that was
        -- processed
        nextSlot = Slot (s + 1)
        events   = (uncurry (mkValidationEvent idx) <$> processed) ++ [SlotAdd nextSlot]
    in ValidatedBlock block events idx'

getCollateral :: Index.UtxoIndex -> CardanoTx -> C.Value
getCollateral idx tx = case getCardanoTxTotalCollateral tx of
    Just v -> lovelaceToValue v
    Nothing -> fromMaybe (lovelaceToValue $ getCardanoTxFee tx) $
        alaf Ap foldMap (fmap txOutValue . (`Index.lookup` idx)) (getCardanoTxCollateralInputs tx)

-- | Check whether the given transaction can be validated in the given slot.
canValidateNow :: Slot -> CardanoTx -> Bool
canValidateNow slot = Interval.member slot . getCardanoTxValidityRange


mkValidationEvent :: Index.UtxoIndex -> CardanoTx -> Either Index.ValidationErrorInPhase Index.ValidationSuccess -> ChainEvent
mkValidationEvent idx t result =
    case result of
        Right r      -> TxnValidate (getCardanoTxId t) t logs
            where logs = concatMap (fst . snd) $ Map.toList r
        Left (phase, err) -> TxnValidationFail phase (getCardanoTxId t) t err (getCollateral idx t) logs
            where
                logs = case err of
                    Index.ScriptFailure (Scripts.EvaluationError msgs _) -> msgs
                    _                                                    -> []

-- | Validate a transaction in the current emulator state.
validateEm
    :: S.MonadState ValidationCtx m
    => Slot
    -> CardanoTx
    -> m (Either Index.ValidationErrorInPhase Index.ValidationSuccess)
validateEm h txn = do
    ctx@(ValidationCtx idx params) <- S.get
    let
        cUtxoIndex = fromPlutusIndex idx
        e = Validation.validateCardanoTx params h cUtxoIndex txn
        idx' = case e of
            Left (Index.Phase1, _) -> idx
            Left (Index.Phase2, _) -> Index.insertCollateral txn idx
            Right _                -> Index.insert txn idx
    _ <- S.put ctx{ vctxIndex = idx' }
    pure e

-- | Adds a block to ChainState, without validation.
addBlock :: Block -> ChainState -> ChainState
addBlock blk st =
  st & chainNewestFirst %~ (blk :)
     -- The block update may contain txs that are not in this client's
     -- `txPool` which will get ignored
     & txPool %~ (\\ map unOnChain blk)

addTxToPool :: CardanoTx -> TxPool -> TxPool
addTxToPool = (:)

makePrisms ''ChainEvent
