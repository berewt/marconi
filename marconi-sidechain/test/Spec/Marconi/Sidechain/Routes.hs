{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Spec.Marconi.Sidechain.Routes (tests) where

import Cardano.Api qualified as C
import Cardano.Api.Shelley qualified as C
import Cardano.Crypto.Hash.Class qualified as Crypto
import Cardano.Ledger.Shelley.API qualified as Ledger
import Cardano.Slotting.Slot (WithOrigin (At, Origin))
import Control.Monad (forM)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty qualified as Aeson
import Data.ByteString.Lazy (ByteString)
import Data.Proxy (Proxy (Proxy))
import Data.String (fromString)
import Gen.Marconi.ChainIndex.Types qualified as Gen
import Hedgehog (
  Gen,
  Property,
  forAll,
  property,
  tripping,
 )
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Marconi.ChainIndex.Indexers.Utxo (BlockInfo (BlockInfo))
import Marconi.ChainIndex.Types (TxIndexInBlock (TxIndexInBlock))
import Marconi.Sidechain.Api.Routes (
  ActiveSDDResult (ActiveSDDResult),
  AddressUtxoResult (AddressUtxoResult),
  AssetIdTxResult (AssetIdTxResult),
  GetBurnTokenEventsParams (GetBurnTokenEventsParams),
  GetBurnTokenEventsResult (GetBurnTokenEventsResult),
  GetCurrentSyncedBlockResult (GetCurrentSyncedBlockResult),
  GetEpochActiveStakePoolDelegationResult (GetEpochActiveStakePoolDelegationResult),
  GetEpochNonceResult (GetEpochNonceResult),
  GetUtxosFromAddressParams (GetUtxosFromAddressParams),
  GetUtxosFromAddressResult (GetUtxosFromAddressResult),
  NonceResult (NonceResult),
  SidechainValue (SidechainValue),
  SpentInfoResult (SpentInfoResult),
  UtxoTxInput (UtxoTxInput),
 )
import Test.Gen.Cardano.Api.Typed qualified as CGen
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Golden (goldenVsStringDiff)
import Test.Tasty.Hedgehog (testPropertyNamed)

tests :: TestTree
tests =
  testGroup
    "Spec.Marconi.Sidechain.Routes"
    [ testGroup
        "ToJSON/FromJSON rountrip"
        [ testPropertyNamed
            "GetCurrentSyncedBlockResult"
            "propJSONRountripCurrentSyncedBlockResult"
            propJSONRountripCurrentSyncedBlockResult
        , testPropertyNamed
            "GetEpochActiveStakePoolDelegationResult"
            "propJSONRountripEpochStakePoolDelegationResult"
            propJSONRountripEpochStakePoolDelegationResult
        , testPropertyNamed
            "GetEpochNonceResult"
            "propJSONRountripEpochNonceResult"
            propJSONRountripEpochNonceResult
        , testPropertyNamed
            "GetUtxosFromAddressParams"
            "propJSONRountripGetUtxosFromAddressParams"
            propJSONRountripGetUtxosFromAddressParams
        , testPropertyNamed
            "GetUtxosFromAddressResult"
            "propJSONRountripGetUtxosFromAddressResult"
            propJSONRountripGetUtxosFromAddressResult
        , testPropertyNamed
            "GetBurnTokenEventsParams"
            "propJSONRountripGetBurnTokenEventsParams"
            propJSONRountripGetBurnTokenEventsParams
        , testPropertyNamed
            "GetBurnTokenEventsResult"
            "propJSONRountripGetBurnTokenEventsResult"
            propJSONRountripGetBurnTokenEventsResult
        , testPropertyNamed
            "SidechainValue"
            "propJSONRountripSidechainValue"
            propJSONRountripSidechainValue
        ]
    , testGroup
        "Golden test for query results"
        [ goldenVsStringDiff
            "Golden test for CurrentSyncedBlockResult in JSON format when chain point is at genesis"
            (\expected actual -> ["diff", "--color=always", expected, actual])
            "test/Spec/Marconi/Sidechain/Api/Routes/Golden/current-synced-point-response-1.json"
            goldenCurrentChainPointGenesisResult
        , goldenVsStringDiff
            "Golden test for CurrentSyncedBlockResult in JSON format when chain point is at point other than genesis"
            (\expected actual -> ["diff", "--color=always", expected, actual])
            "test/Spec/Marconi/Sidechain/Api/Routes/Golden/current-synced-point-response-2.json"
            goldenCurrentChainPointResult
        , goldenVsStringDiff
            "Golden test for AddressUtxoResult in JSON format"
            (\expected actual -> ["diff", "--color=always", expected, actual])
            "test/Spec/Marconi/Sidechain/Api/Routes/Golden/address-utxo-response.json"
            goldenAddressUtxoResult
        , goldenVsStringDiff
            "Golden test for MintingPolicyHashTxResult in JSON format"
            (\expected actual -> ["diff", "--color=always", expected, actual])
            "test/Spec/Marconi/Sidechain/Api/Routes/Golden/mintingpolicyhash-tx-response.json"
            goldenMintingPolicyHashTxResult
        , goldenVsStringDiff
            "Golden test for EpochStakePoolDelegationResult in JSON format"
            (\expected actual -> ["diff", "--color=always", expected, actual])
            "test/Spec/Marconi/Sidechain/Api/Routes/Golden/epoch-stakepooldelegation-response.json"
            goldenEpochStakePoolDelegationResult
        , goldenVsStringDiff
            "Golden test for EpochNonResult in JSON format"
            (\expected actual -> ["diff", "--color=always", expected, actual])
            "test/Spec/Marconi/Sidechain/Api/Routes/Golden/epoch-nonce-response.json"
            goldenEpochNonceResult
        ]
    ]

propJSONRountripCurrentSyncedBlockResult :: Property
propJSONRountripCurrentSyncedBlockResult = property $ do
  let genBlockInfo =
        BlockInfo
          <$> Gen.genSlotNo
          <*> Gen.genHashBlockHeader
          <*> Gen.genBlockNo
          <*> pure 0
          <*> Gen.genEpochNo
  blockInfo <-
    forAll $
      Gen.choice
        [ pure Origin
        , At <$> genBlockInfo
        ]
  tripping (GetCurrentSyncedBlockResult blockInfo) Aeson.encode Aeson.decode

propJSONRountripGetUtxosFromAddressParams :: Property
propJSONRountripGetUtxosFromAddressParams = property $ do
  r <-
    forAll $
      GetUtxosFromAddressParams
        <$> Gen.string (Range.linear 1 10) Gen.alphaNum
        <*> Gen.maybe (Gen.word64 (Range.linear 1 100))
        <*> Gen.word64 (Range.linear 101 200)
  tripping r Aeson.encode Aeson.decode

propJSONRountripGetUtxosFromAddressResult :: Property
propJSONRountripGetUtxosFromAddressResult = property $ do
  r <- fmap GetUtxosFromAddressResult $ forAll $ Gen.list (Range.linear 0 10) $ do
    hsd <- Gen.maybe CGen.genHashableScriptData
    AddressUtxoResult
      <$> Gen.genSlotNo
      <*> Gen.genHashBlockHeader
      <*> Gen.genBlockNo
      <*> fmap fromIntegral (Gen.word64 $ Range.linear 0 5)
      <*> CGen.genTxIn
      <*> pure (fmap C.hashScriptDataBytes hsd)
      <*> pure (fmap C.getScriptData hsd)
      <*> CGen.genValue CGen.genAssetId (CGen.genQuantity (Range.linear 0 5))
      <*> Gen.maybe genSpentInfo
      <*> Gen.list (Range.linear 0 10) (UtxoTxInput <$> CGen.genTxIn)

  tripping r Aeson.encode Aeson.decode

genSpentInfo :: Gen SpentInfoResult
genSpentInfo = do
  slotNo <- Gen.genSlotNo
  (C.TxIn txId _) <- CGen.genTxIn
  pure $ SpentInfoResult slotNo txId

propJSONRountripGetBurnTokenEventsParams :: Property
propJSONRountripGetBurnTokenEventsParams = property $ do
  r <-
    forAll $
      GetBurnTokenEventsParams
        <$> (C.PolicyId <$> CGen.genScriptHash)
        <*> (fmap fromString <$> Gen.maybe (Gen.string (Range.linear 1 10) Gen.alphaNum))
        <*> (Gen.maybe $ Gen.integral (Range.linear 1 10))
        <*> Gen.maybe CGen.genTxId
  tripping r Aeson.encode Aeson.decode

propJSONRountripGetBurnTokenEventsResult :: Property
propJSONRountripGetBurnTokenEventsResult = property $ do
  r <- fmap GetBurnTokenEventsResult $ forAll $ Gen.list (Range.linear 0 10) $ do
    hsd <- Gen.maybe CGen.genHashableScriptData
    AssetIdTxResult
      <$> Gen.genSlotNo
      <*> Gen.genHashBlockHeader
      <*> Gen.genBlockNo
      <*> CGen.genTxId
      <*> pure (fmap C.hashScriptDataBytes hsd)
      <*> pure (fmap C.getScriptData hsd)
      <*> CGen.genAssetName
      <*> Gen.genQuantity (Range.linear 0 10)
  tripping r Aeson.encode Aeson.decode

propJSONRountripEpochStakePoolDelegationResult :: Property
propJSONRountripEpochStakePoolDelegationResult = property $ do
  sdds <- fmap GetEpochActiveStakePoolDelegationResult $ forAll $ Gen.list (Range.linear 1 10) $ do
    ActiveSDDResult
      <$> Gen.genPoolId
      <*> CGen.genLovelace
      <*> Gen.genSlotNo
      <*> Gen.genHashBlockHeader
      <*> Gen.genBlockNo
  tripping sdds Aeson.encode Aeson.decode

propJSONRountripEpochNonceResult :: Property
propJSONRountripEpochNonceResult = property $ do
  nonce <- fmap GetEpochNonceResult $ forAll $ Gen.maybe $ do
    NonceResult
      <$> (Ledger.Nonce . Crypto.castHash . Crypto.hashWith id <$> Gen.bytes (Range.linear 0 32))
      <*> Gen.genSlotNo
      <*> Gen.genHashBlockHeader
      <*> Gen.genBlockNo
  tripping nonce Aeson.encode Aeson.decode

propJSONRountripSidechainValue :: Property
propJSONRountripSidechainValue = property $ do
  v <- forAll $ CGen.genValue CGen.genAssetId (CGen.genQuantity (Range.linear 1 100))
  tripping (SidechainValue v) Aeson.encode Aeson.decode

goldenCurrentChainPointGenesisResult :: IO ByteString
goldenCurrentChainPointGenesisResult = do
  pure $ Aeson.encodePretty $ GetCurrentSyncedBlockResult Origin

goldenCurrentChainPointResult :: IO ByteString
goldenCurrentChainPointResult = do
  let blockHeaderHashRawBytes = "6161616161616161616161616161616161616161616161616161616161616161"
      epochNo = C.EpochNo 6
      blockNo = C.BlockNo 64903
      blockTimestamp = 0
  blockHeaderHash <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex (C.AsHash (C.proxyToAsType $ Proxy @C.BlockHeader)) blockHeaderHashRawBytes

  pure $
    Aeson.encodePretty $
      GetCurrentSyncedBlockResult $
        At $
          BlockInfo (C.SlotNo 1) blockHeaderHash blockNo blockTimestamp epochNo

goldenAddressUtxoResult :: IO ByteString
goldenAddressUtxoResult = do
  let datum = C.ScriptDataNumber 34
  let txIdRawBytes = "ec7d3bd7c6a3a31368093b077af0db46ceac77956999eb842373e08c6420f000"
  txId <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex C.AsTxId txIdRawBytes

  let txId2RawBytes = "2f1f574c0365afd9865332eec4ff75e599d80c525afc7b7d6e38d27d0a01bf47"
  txId2 <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex C.AsTxId txId2RawBytes

  let blockHeaderHashRawBytes = "6161616161616161616161616161616161616161616161616161616161616161"
  blockHeaderHash <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex (C.AsHash (C.proxyToAsType $ Proxy @C.BlockHeader)) blockHeaderHashRawBytes

  let spentTxIdRawBytes = "2e19f40cdf462444234d0de049163d5269ee1150feda868560315346dd12807d"
  spentTxId <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex C.AsTxId spentTxIdRawBytes

  let utxos =
        [ AddressUtxoResult
            (C.SlotNo 1)
            blockHeaderHash
            (C.BlockNo 1)
            (TxIndexInBlock 0)
            (C.TxIn txId (C.TxIx 0))
            Nothing
            Nothing
            (C.valueFromList [(C.AdaAssetId, 10)])
            Nothing
            [UtxoTxInput $ C.TxIn txId2 (C.TxIx 1)]
        , AddressUtxoResult
            (C.SlotNo 1)
            blockHeaderHash
            (C.BlockNo 1)
            (TxIndexInBlock 0)
            (C.TxIn txId (C.TxIx 0))
            (Just $ C.hashScriptDataBytes $ C.unsafeHashableScriptData datum)
            (Just datum)
            (C.valueFromList [(C.AdaAssetId, 1)])
            (Just $ SpentInfoResult (C.SlotNo 12) spentTxId)
            [UtxoTxInput $ C.TxIn txId (C.TxIx 0)]
        ]
      result = GetUtxosFromAddressResult utxos
  pure $ Aeson.encodePretty result

goldenMintingPolicyHashTxResult :: IO ByteString
goldenMintingPolicyHashTxResult = do
  let redeemerData = C.ScriptDataNumber 34
  let txIdRawBytes = "ec7d3bd7c6a3a31368093b077af0db46ceac77956999eb842373e08c6420f000"
  txId <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex C.AsTxId txIdRawBytes

  let blockHeaderHashRawBytes = "6161616161616161616161616161616161616161616161616161616161616161"
  blockHeaderHash <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex (C.AsHash (C.proxyToAsType $ Proxy @C.BlockHeader)) blockHeaderHashRawBytes

  let mints =
        [ AssetIdTxResult
            (C.SlotNo 1)
            blockHeaderHash
            (C.BlockNo 1047)
            txId
            (Just $ C.hashScriptDataBytes $ C.unsafeHashableScriptData redeemerData)
            (Just redeemerData)
            (C.AssetName "")
            (C.Quantity 10)
        ]
      result = GetBurnTokenEventsResult mints
  pure $ Aeson.encodePretty result

goldenEpochStakePoolDelegationResult :: IO ByteString
goldenEpochStakePoolDelegationResult = do
  let blockHeaderHashRawBytes = "578f3cb70f4153e1622db792fea9005c80ff80f83df028210c7a914fb780a6f6"
  blockHeaderHash <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex (C.AsHash (C.proxyToAsType $ Proxy @C.BlockHeader)) blockHeaderHashRawBytes

  let poolIdsBech32 =
        [ "pool1z22x50lqsrwent6en0llzzs9e577rx7n3mv9kfw7udwa2rf42fa"
        , "pool1547tew8vmuj0g6vj3k5jfddudextcw6hsk2hwgg6pkhk7lwphe6"
        , "pool174mw7e20768e8vj4fn8y6p536n8rkzswsapwtwn354dckpjqzr8"
        ]
  poolIds <- forM poolIdsBech32 $ \poolIdBech32 -> do
    either
      (error . show)
      pure
      $ C.deserialiseFromBech32 (C.AsHash (C.proxyToAsType $ Proxy @C.StakePoolKey)) poolIdBech32

  let lovelace = C.Lovelace 100000000000000
      slotNo = C.SlotNo 1382422
      blockNo = C.BlockNo 64903

  let sdds = fmap (\poolId -> ActiveSDDResult poolId lovelace slotNo blockHeaderHash blockNo) poolIds
      result = GetEpochActiveStakePoolDelegationResult sdds
  pure $ Aeson.encodePretty result

goldenEpochNonceResult :: IO ByteString
goldenEpochNonceResult = do
  let blockHeaderHashRawBytes = "fdd5eb1b1e9fc278a08aef2f6c0fe9b576efd76966cc552d8c5a59271dc01604"
  blockHeaderHash <-
    either
      (error . show)
      pure
      $ C.deserialiseFromRawBytesHex (C.AsHash (C.proxyToAsType $ Proxy @C.BlockHeader)) blockHeaderHashRawBytes

  let nonce =
        Ledger.Nonce $
          Crypto.castHash $
            Crypto.hashWith id "162d29c4e1cf6b8a84f2d692e67a3ac6bc7851bc3e6e4afe64d15778bed8bd86"

  let result =
        GetEpochNonceResult $
          Just $
            NonceResult
              nonce
              (C.SlotNo 518400)
              blockHeaderHash
              (C.BlockNo 21645)
  pure $ Aeson.encodePretty result
