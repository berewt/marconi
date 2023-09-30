{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Marconi.ChainIndex.Experimental.Indexers.ChainTip (
  mkChainTipIndexer,
) where

import qualified Cardano.Api.Extended as C
import qualified Cardano.Api.Extended.Block as C
import qualified Cardano.Api.Shelley as C
import qualified Cardano.BM.Trace as BM
import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Read as CBOR
import Control.Monad.Cont (MonadIO)
import Control.Monad.Error (MonadError)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as BS.Lazy
import qualified Data.ByteString.Short as BS.Short
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Marconi.Core.Experiment as Core
import System.FilePath ((</>))
import qualified Text.Read as Text

-- | Configure and start the 'ChainTip' indexer
mkChainTipIndexer
  :: (MonadIO n, MonadError Core.IndexerError n, MonadIO m)
  => BM.Trace m (Core.IndexerEvent C.ChainPoint)
  -> FilePath
  -> n (Core.WorkerIndexer m (Either C.ChainTip b) C.ChainTip (Core.FileIndexer C.ChainTip))
mkChainTipIndexer tracer path = do
  let chainTipPath = path </> "chainTip"
      blockNoAsText = maybe "" (Text.pack . show . (\(C.BlockNo b) -> b) . C.chainTipBlockNo)

      deserialiseMetadata :: [Text] -> Maybe C.ChainTip
      deserialiseMetadata ["", "", ""] = C.ChainTipAtGenesis
      deserialiseMetadata [blockNoStr, slotNoStr, bhhStr] = do
        EpochMetadata
          <$> parseBlockNo blockNoStr
          <*> (C.ChainPoint <$> parseSlotNo slotNoStr <*> parseBlockHeaderHash bhhStr)
        where
          parseSlotNo = fmap C.SlotNo . Text.readMaybe . Text.unpack
          parseBlockHeaderHash bhhStr' = do
            bhhBs <- either (const Nothing) Just $ Base16.decode $ Text.encodeUtf8 bhhStr'
            either (const Nothing) Just $ C.deserialiseFromRawBytes (C.proxyToAsType Proxy) bhhBs
          parseBlockNo "" = pure Nothing
          parseBlockNo bhh = Just . C.BlockNo <$> Text.readMaybe (Text.unpack bhh)
      deserialiseMetadata _ = Nothing

      deserialisePoint :: BS.ByteString -> Either Text C.ChainPoint
      deserialisePoint bs =
        let pointDecoding = do
              b <- CBOR.decodeBool
              if b
                then do
                  s <- C.SlotNo <$> CBOR.decodeWord64
                  bhh <- C.HeaderHash . BS.Short.toShort <$> CBOR.decodeBytes
                  pure $ C.ChainPoint s bhh
                else pure C.ChainPointAtGenesis
         in case CBOR.deserialiseFromBytes pointDecoding . BS.fromStrict $ bs of
              Right (remain, res) | BS.Lazy.null remain -> Right res
              _other -> Left "Can't read chainpoint"
      storageConfig = Core.FileStorageConfig False (const id) compare
      fileBuilder = Core.FileBuilder "chainTip" "no" metadataAsText (const BS.empty) (const BS.empty)
      eventBuilder = Core.EventBuilder _ _ _ deserialisePoint
      leftToMaybe = \case
        Left x -> Just x
        Right _ -> Nothing
  fileIndexer <- Core.mkFileIndexer chainTipPath storageConfig fileBuilder _
  Core.createWorker "chainTip" leftToMaybe fileIndexer

metadataAsText (Core.Timed C.ChainPointAtGenesis evt) = [blockNoAsText evt]
metadataAsText (Core.Timed chainPoint evt) =
  let chainPointTexts = case chainPoint of
        C.ChainPoint (C.SlotNo slotNo) blockHeaderHash ->
          [Text.pack $ show slotNo, C.serialiseToRawBytesHexText blockHeaderHash]
   in blockNoAsText evt : chainPointTexts
