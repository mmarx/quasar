module Quasar.Observable.ObservablePrioritySpec (spec) where

import Quasar.Core
import Quasar.Observable
import Quasar.Observable.ObservablePriority (ObservablePriority)
import Quasar.Observable.ObservablePriority qualified as OP

import Control.Monad (void)
import Data.IORef
import Prelude
import Test.Hspec


spec :: Spec
spec = do
  describe "ObservablePriority" $ parallel $ do
    it "can be created" $ do
      void $ OP.create
    specify "retrieveIO returns the value with the highest priority" $ do
      (op :: ObservablePriority Int String) <- OP.create
      p2 <- OP.insertValue op 2 "p2"
      retrieveIO op `shouldReturn` Just "p2"
      p1 <- OP.insertValue op 1 "p1"
      retrieveIO op `shouldReturn` Just "p2"
      disposeIO p2
      retrieveIO op `shouldReturn` Just "p1"
      disposeIO p1
      retrieveIO op `shouldReturn` Nothing
    it "sends updates when its value changes" $ do
      result <- newIORef []
      let mostRecentShouldBe = (head <$> readIORef result `shouldReturn`)

      (op :: ObservablePriority Int String) <- OP.create
      _s <- subscribe op (modifyIORef result . (:))
      readIORef result `shouldReturn` [(Current, Nothing)]
      p2 <- OP.insertValue op 2 "p2"

      mostRecentShouldBe (Update, Just "p2")
      p1 <- OP.insertValue op 1 "p1"
      mostRecentShouldBe (Update, Just "p2")
      disposeIO p2
      mostRecentShouldBe (Update, Just "p1")
      disposeIO p1
      mostRecentShouldBe (Update, Nothing)

      length <$> readIORef result `shouldReturn` 4