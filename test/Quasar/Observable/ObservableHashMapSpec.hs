module Quasar.Observable.ObservableHashMapSpec (spec) where


import Control.Monad (void)
import Data.HashMap.Strict qualified as HM
import Data.IORef
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Observable
import Quasar.Observable.Delta
import Quasar.Observable.ObservableHashMap qualified as OM
import Quasar.Prelude
import Quasar.ResourceManager
import Test.Hspec

shouldReturnM :: (Eq a, Show a, MonadIO m) => m a -> a -> m ()
shouldReturnM action expected = do
  result <- action
  liftIO $ result `shouldBe` expected

spec :: Spec
spec = pure ()
--spec = parallel $ do
--  describe "retrieve" $ do
--    it "returns the contents of the map" $ io $ withRootResourceManager do
--      om :: OM.ObservableHashMap String String <- OM.new
--      (retrieve om >>= await) `shouldReturnM` HM.empty
--      -- Evaluate unit for coverage
--      () <- OM.insert "key" "value" om
--      (retrieve om >>= await) `shouldReturnM` HM.singleton "key" "value"
--      OM.insert "key2" "value2" om
--      (retrieve om >>= await) `shouldReturnM` HM.fromList [("key", "value"), ("key2", "value2")]
--
--  describe "subscribe" $ do
--    xit "calls the callback with the contents of the map" $ io $ withRootResourceManager do
--      lastCallbackValue <- liftIO $ newIORef unreachableCodePath
--
--      om :: OM.ObservableHashMap String String <- OM.new
--      subscriptionHandle <- captureDisposable_ $ observe om $ liftIO . writeIORef lastCallbackValue
--      let lastCallbackShouldBe expected = liftIO do
--            (ObservableUpdate update) <- readIORef lastCallbackValue
--            update `shouldBe` expected
--
--      lastCallbackShouldBe HM.empty
--      OM.insert "key" "value" om
--      lastCallbackShouldBe (HM.singleton "key" "value")
--      OM.insert "key2" "value2" om
--      lastCallbackShouldBe (HM.fromList [("key", "value"), ("key2", "value2")])
--
--      dispose subscriptionHandle
--      lastCallbackShouldBe (HM.fromList [("key", "value"), ("key2", "value2")])
--
--      OM.insert "key3" "value3" om
--      lastCallbackShouldBe (HM.fromList [("key", "value"), ("key2", "value2")])
--
--  describe "subscribeDelta" $ do
--    it "calls the callback with changes to the map" $ io $ withRootResourceManager do
--      lastDelta <- liftIO $ newIORef unreachableCodePath
--
--      om :: OM.ObservableHashMap String String <- OM.new
--      subscriptionHandle <- subscribeDelta om $ writeIORef lastDelta
--      let lastDeltaShouldBe = liftIO . (readIORef lastDelta `shouldReturn`)
--
--      lastDeltaShouldBe $ Reset HM.empty
--      OM.insert "key" "value" om
--      lastDeltaShouldBe $ Insert "key" "value"
--      OM.insert "key" "changed" om
--      lastDeltaShouldBe $ Insert "key" "changed"
--      OM.insert "key2" "value2" om
--      lastDeltaShouldBe $ Insert "key2" "value2"
--
--      dispose subscriptionHandle
--      lastDeltaShouldBe $ Insert "key2" "value2"
--
--      OM.insert "key3" "value3" om
--      lastDeltaShouldBe $ Insert "key2" "value2"
--
--      void $ subscribeDelta om $ writeIORef lastDelta
--      lastDeltaShouldBe $ Reset $ HM.fromList [("key", "changed"), ("key2", "value2"), ("key3", "value3")]
--
--      OM.delete "key2" om
--      lastDeltaShouldBe $ Delete "key2"
--
--      OM.lookupDelete "key" om `shouldReturnM` Just "changed"
--      lastDeltaShouldBe $ Delete "key"
--
--      (retrieve om >>= await) `shouldReturnM` HM.singleton "key3" "value3"
--
--  describe "observeKey" $ do
--    xit "calls key callbacks with the correct value" $ io $ withRootResourceManager do
--      value1 <- liftIO $ newIORef undefined
--      value2 <- liftIO $ newIORef undefined
--
--      om :: OM.ObservableHashMap String String <- OM.new
--
--      void $ observe (OM.observeKey "key1" om) (liftIO . writeIORef value1)
--      let v1ShouldBe expected = liftIO do
--            (ObservableUpdate update) <- readIORef value1
--            update `shouldBe` expected
--
--      v1ShouldBe $ Nothing
--
--      OM.insert "key1" "value1" om
--      v1ShouldBe $ Just "value1"
--
--      OM.insert "key2" "value2" om
--      v1ShouldBe $ Just "value1"
--
--      handle2 <- captureDisposable_ $ observe (OM.observeKey "key2" om) (liftIO . writeIORef value2)
--      let v2ShouldBe expected = liftIO do
--            (ObservableUpdate update) <- readIORef value2
--            update `shouldBe` expected
--
--      v1ShouldBe $ Just "value1"
--      v2ShouldBe $ Just "value2"
--
--      OM.insert "key2" "changed" om
--      v1ShouldBe $ Just "value1"
--      v2ShouldBe $ Just "changed"
--
--      OM.delete "key1" om
--      v1ShouldBe $ Nothing
--      v2ShouldBe $ Just "changed"
--
--      -- Delete again (should have no effect)
--      OM.delete "key1" om
--      v1ShouldBe $ Nothing
--      v2ShouldBe $ Just "changed"
--
--      (retrieve om >>= await) `shouldReturnM` HM.singleton "key2" "changed"
--      dispose handle2
--
--      OM.lookupDelete "key2" om `shouldReturnM` Just "changed"
--      v2ShouldBe $ Just "changed"
--
--      OM.lookupDelete "key2" om `shouldReturnM` Nothing
--
--      OM.lookupDelete "key1" om `shouldReturnM` Nothing
--      v1ShouldBe $ Nothing
--
--      (retrieve om >>= await) `shouldReturnM` HM.empty
