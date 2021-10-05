module Quasar.DisposableSpec (spec) where

import Control.Concurrent
import Quasar.Prelude
import Test.Hspec
import Quasar.Awaitable
import Quasar.Disposable

spec :: Spec
spec = parallel $ do
  describe "Disposable" $ do
    describe "noDisposable" $ do
      it "can be disposed" $ io do
        await =<< dispose noDisposable

      it "can be awaited" $ io do
        await (isDisposed noDisposable)

    describe "newDisposable" $ do
      it "signals it's disposed state" $ io do
        disposable <- newDisposable $ pure $ pure ()
        void $ forkIO $ threadDelay 100000 >> disposeAndAwait disposable
        await (isDisposed disposable)

      it "can be disposed multiple times" $ io do
        disposable <- newDisposable $ pure $ pure ()
        disposeAndAwait disposable
        disposeAndAwait disposable
        await (isDisposed disposable)

      it "can be disposed in parallel" $ do
        disposable <- newDisposable $ pure () <$ threadDelay 100000
        void $ forkIO $ disposeAndAwait disposable
        disposeAndAwait disposable
        await (isDisposed disposable)
