{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Marconi.ChainIndex.Experimental.Indexers where

import Cardano.Api.Extended qualified as C
import Cardano.Api.Extended.Block qualified as C
import Cardano.Api.Shelley qualified as C
import Cardano.BM.Tracing qualified as BM
import Codec.CBOR.Decoding qualified as CBOR
import Codec.CBOR.Read qualified as CBOR
import Control.Monad.Cont (MonadIO)
import Control.Monad.Except (ExceptT, MonadError, MonadTrans (lift))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BS.Lazy
import Data.ByteString.Short qualified as BS.Short
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Marconi.ChainIndex.Experimental.Extract.WithDistance (WithDistance)
import Marconi.ChainIndex.Experimental.Indexers.BlockInfo qualified as Block
import Marconi.ChainIndex.Experimental.Indexers.ChainTip qualified as ChainTip
import Marconi.ChainIndex.Experimental.Indexers.Coordinator (coordinatorWorker, standardCoordinator)
import Marconi.ChainIndex.Experimental.Indexers.Datum qualified as Datum
import Marconi.ChainIndex.Experimental.Indexers.EpochState qualified as EpochState
import Marconi.ChainIndex.Experimental.Indexers.MintTokenEvent qualified as MintTokenEvent
import Marconi.ChainIndex.Experimental.Indexers.Spent qualified as Spent
import Marconi.ChainIndex.Experimental.Indexers.Utxo qualified as Utxo
import Marconi.ChainIndex.Experimental.Indexers.UtxoQuery qualified as UtxoQuery
import Marconi.ChainIndex.Experimental.Indexers.Worker (
  StandardWorker (StandardWorker),
  StandardWorkerConfig (StandardWorkerConfig),
 )
import Marconi.ChainIndex.Types (
  BlockEvent (BlockEvent),
  SecurityParam,
  TxIndexInBlock,
  blockInMode,
 )
import Marconi.Core.Experiment qualified as Core
import System.FilePath ((</>))

data AnyTxBody = forall era. (C.IsCardanoEra era) => AnyTxBody C.BlockNo TxIndexInBlock (C.TxBody era)
type instance Core.Point (Either C.ChainTip (WithDistance BlockEvent)) = C.ChainPoint
type instance Core.Point BlockEvent = C.ChainPoint
type instance Core.Point C.ChainTip = C.ChainPoint
type instance Core.Point [AnyTxBody] = C.ChainPoint

{- | Build all the indexers of marconi-chain-index
(all those which are available with the new implementation)
and expose a single coordinator to operate them
-}
buildIndexers
  :: SecurityParam
  -> Core.CatchupConfig
  -> Utxo.UtxoIndexerConfig
  -> MintTokenEvent.MintTokenEventConfig
  -> EpochState.EpochStateWorkerConfig
  -> BM.Trace IO Text
  -> FilePath
  -> ExceptT
      Core.IndexerError
      IO
      ( C.ChainPoint
      , -- Query part (should probably be wrapped in a more complex object later)
        UtxoQuery.UtxoQueryIndexer IO
      , -- Indexing part
        Core.WithTrace IO Core.Coordinator (Either C.ChainTip (WithDistance BlockEvent))
      )
buildIndexers securityParam catchupConfig utxoConfig mintEventConfig epochStateConfig logger path = do
  let mainLogger = BM.contramap (fmap (fmap $ Text.pack . show)) logger
      blockEventLogger = BM.appendName "blockEvent" mainLogger
      txBodyCoordinatorLogger = BM.appendName "txBody" blockEventLogger

  StandardWorker blockInfoMVar blockInfoWorker <-
    blockInfoBuilder securityParam catchupConfig blockEventLogger path

  Core.WorkerIndexer _epochStateMVar epochStateWorker <-
    epochStateBuilder securityParam catchupConfig epochStateConfig blockEventLogger path

  StandardWorker utxoMVar utxoWorker <-
    utxoBuilder securityParam catchupConfig utxoConfig txBodyCoordinatorLogger path
  StandardWorker spentMVar spentWorker <-
    spentBuilder securityParam catchupConfig txBodyCoordinatorLogger path
  StandardWorker datumMVar datumWorker <-
    datumBuilder securityParam catchupConfig txBodyCoordinatorLogger path
  StandardWorker _mintTokenMVar mintTokenWorker <-
    mintBuilder securityParam catchupConfig mintEventConfig txBodyCoordinatorLogger path

  let getTxBody :: (C.IsCardanoEra era) => C.BlockNo -> TxIndexInBlock -> C.Tx era -> AnyTxBody
      getTxBody blockNo ix tx = AnyTxBody blockNo ix (C.getTxBody tx)
      toTxBodys :: BlockEvent -> [AnyTxBody]
      toTxBodys (BlockEvent (C.BlockInMode (C.Block (C.BlockHeader _ _ bn) txs) _) _ _) =
        zipWith (getTxBody bn) [0 ..] txs

  coordinatorTxBodyWorkers <-
    buildTxBodyCoordinator
      txBodyCoordinatorLogger
      (pure . Just . fmap toTxBodys)
      [utxoWorker, spentWorker, datumWorker, mintTokenWorker]

  queryIndexer <-
    lift $
      UtxoQuery.mkUtxoSQLiteQuery $
        UtxoQuery.UtxoQueryAggregate utxoMVar spentMVar datumMVar blockInfoMVar

  blockCoordinator <-
    lift $
      standardCoordinator
        blockEventLogger
        [blockInfoWorker, epochStateWorker, coordinatorTxBodyWorkers]

  Core.WorkerIndexer _chainTipMVar chainTipIndexer <- chainTipBuilder mainLogger path

  mainCoordinator <- lift $ standardCoordinator mainLogger [blockCoordinator, chainTipWorker]

  resumePoint <- Core.lastStablePoint mainCoordinator

  -- TODO Create a dedicated return type for it instead of a tuple.
  -- However, we should wait until we have more stuff in the query side before we do it.
  pure (resumePoint, queryIndexer, mainCoordinator)

-- | Build and start a coordinator of a bunch of workers that takes an @AnyTxBody@ as an input
buildBlockEventCoordinator
  :: (MonadIO m)
  => BM.Trace IO (Core.IndexerEvent C.ChainPoint)
  -> [Core.Worker (WithDistance BlockEvent) C.ChainPoint]
  -> m (Core.Worker (Either C.ChainPoint (WithDistance BlockEvent)) C.ChainPoint)
buildBlockEventCoordinator logger workers =
  let rightToMaybe = \case
        Left _ -> Nothing
        Right x -> Just x
   in Core.worker <$> coordinatorWorker "BlockEvent coordinator" logger (pure . rightToMaybe) workers

-- | Build and start a coordinator of a bunch of workers that takes an @AnyTxBody@ as an input
buildTxBodyCoordinator
  :: (MonadIO m, Ord (Core.Point event))
  => BM.Trace IO (Core.IndexerEvent (Core.Point event))
  -> (WithDistance input -> IO (Maybe event))
  -> [Core.Worker event (Core.Point event)]
  -> m (Core.Worker (WithDistance input) (Core.Point event))
buildTxBodyCoordinator logger extract workers =
  Core.worker <$> coordinatorWorker "TxBody coordinator" logger extract workers

-- | Configure and start the @BlockInfo@ indexer
blockInfoBuilder
  :: (MonadIO n, MonadError Core.IndexerError n, MonadIO m)
  => SecurityParam
  -> Core.CatchupConfig
  -> BM.Trace m (Core.IndexerEvent C.ChainPoint)
  -> FilePath
  -> n (StandardWorker m BlockEvent Block.BlockInfo Core.SQLiteIndexer)
blockInfoBuilder securityParam catchupConfig logger path =
  let extractBlockInfo :: BlockEvent -> Block.BlockInfo
      extractBlockInfo (BlockEvent (C.BlockInMode b _) eno t) = Block.fromBlockEratoBlockInfo b eno t
      blockInfoWorkerConfig =
        StandardWorkerConfig
          "BlockInfo"
          securityParam
          catchupConfig
          (pure . Just . extractBlockInfo)
          (BM.appendName "blockInfo" logger)
   in Block.blockInfoWorker blockInfoWorkerConfig (path </> "blockInfo.db")

-- | Configure and start the @Utxo@ indexer
utxoBuilder
  :: (MonadIO n, MonadError Core.IndexerError n, MonadIO m)
  => SecurityParam
  -> Core.CatchupConfig
  -> Utxo.UtxoIndexerConfig
  -> BM.Trace m (Core.IndexerEvent C.ChainPoint)
  -> FilePath
  -> n (StandardWorker m [AnyTxBody] Utxo.UtxoEvent Core.SQLiteIndexer)
utxoBuilder securityParam catchupConfig utxoConfig logger path =
  let extractUtxos :: AnyTxBody -> [Utxo.Utxo]
      extractUtxos (AnyTxBody _ indexInBlock txb) = Utxo.getUtxosFromTxBody indexInBlock txb
      utxoWorkerConfig =
        StandardWorkerConfig
          "Utxo"
          securityParam
          catchupConfig
          (pure . NonEmpty.nonEmpty . (>>= extractUtxos))
          (BM.appendName "utxo" logger)
   in Utxo.utxoWorker utxoWorkerConfig utxoConfig (path </> "utxo.db")

-- | Configure and start the 'ChainTip' indexer
chainTipBuilder
  :: (MonadIO n, MonadError Core.IndexerError n, MonadIO m)
  => BM.Trace m (Core.IndexerEvent C.ChainPoint)
  -> FilePath
  -> n (Core.WorkerIndexer m (Either C.ChainTip b) C.ChainTip (Core.FileIndexer C.ChainTip))
chainTipBuilder tracer path = do
  let chainTipPath = path </> "chainTip"
      blockNoAsText = maybe "" (Text.pack . show . (\(C.BlockNo b) -> b) . C.chainTipBlockNo)

  chainTipIndexer <- ChainTip.mkChainTipIndexer chainTipPath storageConfig fileBuilder _
  Core.createWorker "chainTip" leftToMaybe fileIndexer

-- | Configure and start the @SpentInfo@ indexer
spentBuilder
  :: (MonadIO n, MonadError Core.IndexerError n, MonadIO m)
  => SecurityParam
  -> Core.CatchupConfig
  -> BM.Trace m (Core.IndexerEvent C.ChainPoint)
  -> FilePath
  -> n (StandardWorker m [AnyTxBody] Spent.SpentInfoEvent Core.SQLiteIndexer)
spentBuilder securityParam catchupConfig logger path =
  let extractSpent :: AnyTxBody -> [Spent.SpentInfo]
      extractSpent (AnyTxBody _ _ txb) = Spent.getInputs txb
      spentWorkerConfig =
        StandardWorkerConfig
          "spent"
          securityParam
          catchupConfig
          (pure . NonEmpty.nonEmpty . (>>= extractSpent))
          (BM.appendName "spent" logger)
   in Spent.spentWorker spentWorkerConfig (path </> "spent.db")

-- | Configure and start the @Datum@ indexer
datumBuilder
  :: (MonadIO n, MonadError Core.IndexerError n, MonadIO m)
  => SecurityParam
  -> Core.CatchupConfig
  -> BM.Trace m (Core.IndexerEvent C.ChainPoint)
  -> FilePath
  -> n (StandardWorker m [AnyTxBody] Datum.DatumEvent Core.SQLiteIndexer)
datumBuilder securityParam catchupConfig logger path =
  let extractDatum :: AnyTxBody -> [Datum.DatumInfo]
      extractDatum (AnyTxBody _ _ txb) = Datum.getDataFromTxBody txb
      datumWorkerConfig =
        StandardWorkerConfig
          "datum"
          securityParam
          catchupConfig
          (pure . NonEmpty.nonEmpty . (>>= extractDatum))
          (BM.appendName "datum" logger)
   in Datum.datumWorker datumWorkerConfig (path </> "datum.db")

-- | Configure and start the @MintToken@ indexer
mintBuilder
  :: (MonadIO n, MonadError Core.IndexerError n, MonadIO m)
  => SecurityParam
  -> Core.CatchupConfig
  -> MintTokenEvent.MintTokenEventConfig
  -> BM.Trace m (Core.IndexerEvent C.ChainPoint)
  -> FilePath
  -> n (StandardWorker m [AnyTxBody] MintTokenEvent.MintTokenBlockEvents Core.SQLiteIndexer)
mintBuilder securityParam catchupConfig mintEventConfig logger path =
  let extractMint :: AnyTxBody -> [MintTokenEvent.MintTokenEvent]
      extractMint (AnyTxBody bn ix txb) = MintTokenEvent.extractEventsFromTx bn ix txb
      mintTokenWorkerConfig =
        StandardWorkerConfig
          "mintToken"
          securityParam
          catchupConfig
          (pure . fmap MintTokenEvent.MintTokenBlockEvents . NonEmpty.nonEmpty . (>>= extractMint))
          (BM.appendName "mintToken" logger)
   in MintTokenEvent.mkMintTokenEventWorker mintTokenWorkerConfig mintEventConfig (path </> "mint.db")

-- | Configure and start the @EpochState@ indexer
epochStateBuilder
  :: (MonadIO n, MonadError Core.IndexerError n)
  => SecurityParam
  -> Core.CatchupConfig
  -> EpochState.EpochStateWorkerConfig
  -> BM.Trace IO (Core.IndexerEvent C.ChainPoint)
  -> FilePath
  -> n
      ( Core.WorkerIndexer
          IO
          (WithDistance BlockEvent)
          (WithDistance (Maybe EpochState.ExtLedgerState, C.BlockInMode C.CardanoMode))
          EpochState.EpochStateIndexer
      )
epochStateBuilder securityParam catchupConfig epochStateConfig logger path =
  let epochStateWorkerConfig =
        StandardWorkerConfig
          "epochState"
          securityParam
          catchupConfig
          (pure . Just . blockInMode)
          (BM.appendName "epochState" logger)
   in EpochState.mkEpochStateWorker epochStateWorkerConfig epochStateConfig (path </> "epochState")
