{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE OverloadedLists #-}

module Quasar.Observable.ListSpec (spec) where

import Data.FingerTree (Measured)
import Data.FingerTree qualified as FT
import Data.Sequence qualified as Seq
import GHC.IsList (IsList, Item)
import GHC.IsList qualified as IsList
import GHC.Stack (withFrozenCallStack)
import Quasar.Observable.Core
import Quasar.Observable.List
import Quasar.Prelude
import Test.Hspec


instance Measured v a => IsList (FingerTree v a) where
  type Item (FingerTree v a) = a
  fromList = FT.fromList
  toList = toList


spec :: Spec
spec = parallel do
  describe "applyDelta" do
    it "empty delta" do
      applyDelta @Seq @Int (ListDelta mempty) [] `shouldBe` []
      applyDelta @Seq @Int (ListDelta mempty) [1, 2, 3] `shouldBe` []

    it "keep elements" do
      applyDelta @Seq @Int (ListDelta [ListKeep 3]) [1, 2, 3] `shouldBe` [1, 2, 3]
      applyDelta @Seq @Int (ListDelta [ListKeep 100]) [1, 2, 3] `shouldBe` [1, 2, 3]

    it "discards elements that are not kept" do
      applyDelta @Seq @Int (ListDelta [ListKeep 3]) [1, 2, 3, 42] `shouldBe` [1, 2, 3]

    it "empty insert" do
      applyDelta @Seq @Int (ListDelta [ListSplice []]) [] `shouldBe` []
      applyDelta @Seq @Int (ListDelta [ListSplice []]) [1, 2, 3] `shouldBe` []

    it "can insert element to empty list" do
      applyDelta @Seq @Int (ListDelta [ListSplice [42]]) [] `shouldBe` [42]

    it "can insert element at end of list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 3, ListSplice [42]]) [1, 2, 3] `shouldBe` [1, 2, 3, 42]

    it "can insert element after end of list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 21, ListSplice [42]]) [] `shouldBe` [42]
      applyDelta @Seq @Int (ListDelta [ListKeep 21, ListSplice [42]]) [1, 2, 3] `shouldBe` [1, 2, 3, 42]

    it "can insert element at start of list" do
      applyDelta @Seq @Int (ListDelta [ListSplice [42], ListKeep 3]) [1, 2, 3] `shouldBe` [42, 1, 2, 3]

    it "can insert element in the middle of the list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 2, ListSplice [42], ListKeep 2]) [1, 2, 3, 4] `shouldBe` [1, 2, 42, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListKeep 2, ListSplice [41, 42], ListKeep 2]) [1, 2, 3, 4] `shouldBe` [1, 2, 41, 42, 3, 4]

    it "empty delete" do
      applyDelta @Seq @Int (ListDelta [ListDrop 0, ListKeep 100]) [1, 2, 3] `shouldBe` [1, 2, 3]

    it "can delete elements" do
      applyDelta @Seq @Int (ListDelta [ListDrop 1, ListKeep 100]) [42, 1, 2, 3, 4] `shouldBe` [1, 2, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListKeep 2, ListDrop 1, ListKeep 100]) [1, 2, 42, 3, 4] `shouldBe` [1, 2, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListKeep 2, ListDrop 2, ListKeep 100]) [1, 2, 42, 43, 3, 4] `shouldBe` [1, 2, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListKeep 4, ListDrop 1, ListKeep 100]) [1, 2, 3, 4, 42] `shouldBe` [1, 2, 3, 4]

    it "can clip delete operations at the end of the list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 4, ListDrop 21]) [1, 2, 3, 4, 42] `shouldBe` [1, 2, 3, 4]

    it "ignores delete operations after the end of the list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 42, ListDrop 21]) [1, 2, 3, 4] `shouldBe` [1, 2, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListDrop 13]) [] `shouldBe` []

    it "applies complex operations" do
      let
        ops :: [ListDeltaOperation Int]
        ops = [
            ListKeep 1,
            ListSplice [42, 43],
            ListKeep 1,
            ListDrop 1,
            ListSplice [44],
            ListKeep 42, -- clipped to length of list
            ListDrop 2 -- no-op
          ]
      applyDelta @Seq @Int (ListDelta ops) [1, 2, 3, 4] `shouldBe` [1, 42, 43, 2, 44, 4]

  describe "validateDelta" do
    it "empty delta" do
      testUpdateDeltaContext [] (ListDelta []) Nothing

    it "keep empty list" do
      testUpdateDeltaContext [] (ListDelta [ListKeep 42]) Nothing

    it "keep empty list" do
      testUpdateDeltaContext [] (ListDelta [ListKeep 42]) Nothing

    it "keep elements" do
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListKeep 3]) (Just (ValidatedListDelta [ListKeep 3]))
      testUpdateDeltaContext [1, 2, 3, 4] (ListDelta [ListKeep 3]) (Just (ValidatedListDelta [ListKeep 3]))

    it "keep is clipped to end of list" do
      testUpdateDeltaContext [1, 2] (ListDelta [ListKeep 3]) (Just (ValidatedListDelta [ListKeep 2]))

    it "delete empty list" do
      testUpdateDeltaContext [] (ListDelta [ListDrop 42]) Nothing

    it "insert to empty list" do
      testUpdateDeltaContext [] (ListDelta [ListSplice [1]]) (Just (ValidatedListDelta [ListSplice [1]]))

    it "insert" do
      testUpdateDeltaContext [2, 3] (ListDelta [ListSplice [1]]) (Just (ValidatedListDelta [ListSplice [1]]))
      testUpdateDeltaContext [1, 3] (ListDelta [ListKeep 1, ListSplice [2], ListKeep 1]) (Just (ValidatedListDelta [ListKeep 1, ListSplice [2], ListKeep 1]))
      testUpdateDeltaContext [1, 2, 3, 7] (ListDelta [ListKeep 3, ListSplice [4, 5, 6], ListKeep 1]) (Just (ValidatedListDelta [ListKeep 3, ListSplice [4, 5, 6], ListKeep 1]))

    it "insert after end of list" do
      testUpdateDeltaContext [] (ListDelta [ListKeep 42, ListSplice [1]]) (Just (ValidatedListDelta [ListSplice [1]]))
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListKeep 42, ListSplice [4]]) (Just (ValidatedListDelta [ListKeep 3, ListSplice [4]]))

    it "trailing drop is removed" do
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListDrop 1, ListKeep 2]) (Just (ValidatedListDelta [ListDrop 1, ListKeep 2]))
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListDrop 2, ListKeep 1]) (Just (ValidatedListDelta [ListDrop 2, ListKeep 1]))

    it "trailing drop is removed" do
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListDrop 42]) Nothing
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListDrop 21, ListDrop 21]) Nothing
      testUpdateDeltaContext [1, 2, 3, 4, 5] (ListDelta [ListDrop 1, ListDrop 1, ListDrop 1, ListDrop 1, ListKeep 1]) (Just (ValidatedListDelta [ListDrop 4, ListKeep 1]))
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListDrop 1]) Nothing
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListKeep 1, ListDrop 1]) (Just (ValidatedListDelta [ListKeep 1]))
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListKeep 1, ListDrop 42]) (Just (ValidatedListDelta [ListKeep 1]))

    it "duplicate drops are merged" do
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListDrop 1, ListDrop 1, ListKeep 1]) (Just (ValidatedListDelta [ListDrop 2, ListKeep 1]))

    it "empty drop is removed" do
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListKeep 1, ListDrop 0, ListKeep 2]) (Just (ValidatedListDelta [ListKeep 3]))
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListKeep 1, ListDrop 0, ListKeep 42]) (Just (ValidatedListDelta [ListKeep 3]))

    it "empty drop is merged" do
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListKeep 1, ListDrop 0, ListDrop 1, ListKeep 1]) (Just (ValidatedListDelta [ListKeep 1, ListDrop 1, ListKeep 1]))
      testUpdateDeltaContext [1, 2, 3] (ListDelta [ListKeep 1, ListDrop 1, ListDrop 0, ListKeep 1]) (Just (ValidatedListDelta [ListKeep 1, ListDrop 1, ListKeep 1]))

    it "duplicate inserts are merged" do
      testUpdateDeltaContext [] (ListDelta [ListSplice [1, 2], ListSplice [3]]) (Just (ValidatedListDelta [ListSplice [1, 2, 3]]))

  describe "mergeDelta" do
    it "keeps keep operation" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListKeep 42]) (ListDelta [ListKeep 42]) `shouldBe` ValidatedListDelta [ListKeep 42]

    it "clips original delta" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListKeep 100]) (ListDelta [ListKeep 42]) `shouldBe` ValidatedListDelta [ListKeep 42]

    it "clips incoming keep" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListKeep 42]) (ListDelta [ListKeep 100]) `shouldBe` ValidatedListDelta [ListKeep 42]

    it "keeps drop operation" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListDrop 5, ListKeep 42]) (ListDelta [ListKeep 42]) `shouldBe` ValidatedListDelta [ListDrop 5, ListKeep 42]
      mergeDelta @Seq @Int (ValidatedListDelta [ListKeep 2, ListDrop 5, ListKeep 40]) (ListDelta [ListKeep 42]) `shouldBe` ValidatedListDelta [ListKeep 2, ListDrop 5, ListKeep 40]
      mergeDelta @Seq @Int (ValidatedListDelta [ListKeep 2, ListDrop 5, ListKeep 100]) (ListDelta [ListKeep 42]) `shouldBe` ValidatedListDelta [ListKeep 2, ListDrop 5, ListKeep 40]

    it "keeps insert operation" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListSplice [1, 2, 3], ListKeep 42]) (ListDelta [ListKeep 42]) `shouldBe` ValidatedListDelta [ListSplice [1, 2, 3], ListKeep 39]

    it "clips insert operation" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListSplice [1, 2, 3, 4, 5]]) (ListDelta [ListKeep 3]) `shouldBe` ValidatedListDelta [ListSplice [1, 2, 3]]
      mergeDelta @Seq @Int (ValidatedListDelta [ListKeep 10, ListSplice [1, 2, 3, 4, 5]]) (ListDelta [ListKeep 13]) `shouldBe` ValidatedListDelta [ListKeep 10, ListSplice [1, 2, 3]]

    it "clips incoming keep but applies later insert operation" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListKeep 42]) (ListDelta [ListKeep 100, ListSplice [1, 2, 3]]) `shouldBe` ValidatedListDelta [ListKeep 42, ListSplice [1, 2, 3]]

    it "clips deletes at end of delta in complex scenario" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListDrop 13, ListKeep 1]) (ListDelta [ListKeep 1, ListDrop 42]) `shouldBe` ValidatedListDelta [ListDrop 13, ListKeep 1]

    it "normalization" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListSplice [1, 2, 3, 4, 5]]) (ListDelta [ListKeep 3, ListSplice [42]]) `shouldBe` ValidatedListDelta [ListSplice [1, 2, 3, 42]]

    it "normalization 2" do
      mergeDelta @Seq @Int (ValidatedListDelta [ListSplice [1, 2, 3, 4, 5]]) (ListDelta [ListKeep 100, ListSplice [42]]) `shouldBe` ValidatedListDelta [ListSplice [1, 2, 3, 4, 5, 42]]

testUpdateDeltaContext :: HasCallStack => Seq Int -> ListDelta Int -> Maybe (ValidatedListDelta Int) -> IO ()
testUpdateDeltaContext list delta expectedDelta = withFrozenCallStack do
  let
    expectedLength = maybe 0 validatedListDeltaLength expectedDelta
    validatedDelta = validateDelta @Seq (fromIntegral (Seq.length list)) delta
  validatedDelta `shouldBe` expectedDelta
  maybe 0 validatedListDeltaLength validatedDelta `shouldBe` expectedLength
  Seq.length (applyDelta delta list) `shouldBe` fromIntegral expectedLength
