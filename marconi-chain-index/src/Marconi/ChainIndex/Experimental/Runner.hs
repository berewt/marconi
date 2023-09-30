{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Allow the execution of indexers on a Cardano node using the chain sync protocol
module Marconi.ChainIndex.Experimental.Runner (
  runIndexer,
) where

import Cardano.Api.Extended qualified as C
import Cardano.Api.Extended.Block qualified as C
import Cardano.Api.Extended.Streaming (
  BlockEvent (BlockEvent),
  ChainSyncEvent (RollBackward, RollForward),
  ChainSyncEventException (NoIntersectionFound),
  withChainSyncBlockEventStream,
 )
import Cardano.BM.Trace qualified as Trace
import Control.Concurrent qualified as Concurrent
import Control.Concurrent.STM qualified as STM
import Control.Exception (catch)
import Control.Monad.Except (ExceptT, void)
import Control.Monad.State.Strict (MonadState (put), State, gets)
import Data.Foldable (traverse_)
import Data.Map (Map)
import Data.Map qualified as Map
import Marconi.ChainIndex.Experimental.Extract.WithDistance (WithDistance)
import Marconi.ChainIndex.Experimental.Extract.WithDistance qualified as Distance
import Marconi.ChainIndex.Experimental.Indexers.Orphans qualified ()
import Marconi.ChainIndex.Logging (chainSyncEventStreamLogging)
import Marconi.ChainIndex.Node.Client.Retry (withNodeConnectRetry)
import Marconi.ChainIndex.Types (
  RunIndexerConfig (RunIndexerConfig),
  SecurityParam,
 )
import Marconi.Core.Experiment qualified as Core
import Prettyprinter qualified as PP
import Prettyprinter.Render.Text qualified as PP
import Streaming qualified as S
import Streaming.Prelude qualified as S

-- | Wraps as a datatype log message emitted by the 'runIndexer' et al. functions.
data RunIndexerLog
  = -- | The last sync points of all indexers that will be used to start the chain-sync protocol.
    StartingPointLog C.ChainPoint
  | NoIntersectionFoundLog

instance PP.Pretty RunIndexerLog where
  pretty (StartingPointLog lastSyncPoint) =
    "The starting point for the chain-sync protocol is" PP.<+> PP.pretty lastSyncPoint
  pretty NoIntersectionFoundLog = "No intersection found"

type instance Core.Point (Either C.ChainTip (WithDistance BlockEvent)) = C.ChainPoint
type instance Core.Point BlockEvent = C.ChainPoint

{- | Connect to the given socket to start a chain sync protocol and start indexing it with the
given indexer.

If you want to start several indexers, use @runIndexers@.
-}
runIndexer
  :: ( Core.IsIndex (ExceptT Core.IndexerError IO) (Either C.ChainTip (WithDistance BlockEvent)) indexer
     , Core.Closeable IO indexer
     )
  => RunIndexerConfig
  -> indexer (Either C.ChainTip (WithDistance BlockEvent))
  -> IO ()
runIndexer
  ( RunIndexerConfig
      trace
      retryConfig
      securityParam
      networkId
      startingPoint
      socketPath
    )
  indexer = do
    withNodeConnectRetry trace retryConfig socketPath $ do
      Trace.logInfo trace $
        PP.renderStrict $
          PP.layoutPretty PP.defaultLayoutOptions $
            PP.pretty $
              StartingPointLog startingPoint
      eventQueue <- STM.newTBQueueIO $ fromIntegral securityParam
      cBox <- Concurrent.newMVar indexer
      let runChainSyncStream =
            withChainSyncBlockEventStream
              socketPath
              networkId
              [startingPoint]
              (mkEventStream eventQueue . chainSyncEventStreamLogging trace)
          whenNoIntersectionFound NoIntersectionFound =
            Trace.logError trace $
              PP.renderStrict $
                PP.layoutPretty PP.defaultLayoutOptions $
                  PP.pretty NoIntersectionFoundLog
      void $ Concurrent.forkIO $ runChainSyncStream `catch` whenNoIntersectionFound
      Core.processQueue (stablePointComputation securityParam) Map.empty eventQueue cBox

stablePointComputation
  :: SecurityParam
  -> Core.Timed C.ChainPoint (Maybe (Either C.ChainTip (WithDistance BlockEvent)))
  -> State (Map C.BlockNo C.ChainPoint) (Maybe C.ChainPoint)
stablePointComputation s (Core.Timed point (Just (Left tip))) = do
  let tipBlockNo = C.chainTipBlockNo tip
      lastVolatileBlock = tipBlockNo - fromIntegral s
  (immutable, volatile) <- gets (Map.spanAntitone (< lastVolatileBlock))
  put (Map.insert tipBlockNo point volatile)
  pure $ case Map.elems immutable of
    [] -> Nothing
    xs -> Just $ last xs
stablePointComputation _s (Core.Timed _ _) = pure Nothing

chainTipToTimedEvent :: C.ChainTip -> Core.Timed C.ChainPoint C.ChainTip
chainTipToTimedEvent tip = Core.Timed (C.chainTipToChainPoint tip) tip

-- | Event preprocessing, to ease the coordinator work
mkEventStream
  :: STM.TBQueue (Core.ProcessedInput C.ChainPoint (Either C.ChainTip (WithDistance BlockEvent)))
  -> S.Stream (S.Of (ChainSyncEvent BlockEvent)) IO r
  -> IO r
mkEventStream q =
  let blockTimed :: BlockEvent -> C.ChainTip -> Core.Timed C.ChainPoint (WithDistance BlockEvent)
      blockTimed
        (BlockEvent b@(C.BlockInMode block _) epochNo' bt)
        tip =
          let (C.Block (C.BlockHeader slotNo hsh currentBlockNo) _) = block
              blockWithDistance = Distance.attachDistance currentBlockNo tip (BlockEvent b epochNo' bt)
           in Core.Timed (C.ChainPoint slotNo hsh) blockWithDistance

      processEvent
        :: ChainSyncEvent BlockEvent
        -> [Core.ProcessedInput C.ChainPoint (Either C.ChainTip (WithDistance BlockEvent))]
      processEvent (RollForward x tip) =
        [ Core.Index $ Just . Right <$> blockTimed x tip
        , Core.Index $ Just . Left <$> chainTipToTimedEvent tip
        ]
      processEvent (RollBackward x tip) =
        [ Core.Rollback x
        , Core.Index $ Just . Left <$> chainTipToTimedEvent tip
        ]
   in S.mapM_ $ STM.atomically . traverse_ (STM.writeTBQueue q) . processEvent
