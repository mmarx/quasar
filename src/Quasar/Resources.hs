module Quasar.Resources (
  -- * Resources
  Resource(..),
  dispose,
  isDisposing,
  isDisposed,

  -- * Resource management in the `Quasar` monad
  registerResource,
  registerNewResource,
  registerDisposeAction,
  registerDisposeAction_,
  registerDisposeTransaction,
  registerDisposeTransaction_,
  disposeEventually,
  disposeEventually_,
  captureResources,
  captureResources_,

  -- * STM
  disposeEventuallySTM,
  disposeEventuallySTM_,

  -- * Types to implement resources
  -- ** Disposer
  Disposer,
  newUnmanagedIODisposerSTM,
  newUnmanagedSTMDisposerSTM,

  -- ** Resource manager
  ResourceManager,
  newUnmanagedResourceManagerSTM,
  attachResource,
) where


import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Future
import Quasar.Async.Fork
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.ShortIO


newUnmanagedIODisposerSTM :: IO () -> TIOWorker -> ExceptionSink -> STM Disposer
newUnmanagedIODisposerSTM fn worker exChan = newUnmanagedPrimitiveDisposer (forkAsyncShortIO fn exChan) worker exChan

newUnmanagedSTMDisposerSTM :: STM () -> TIOWorker -> ExceptionSink -> STM Disposer
newUnmanagedSTMDisposerSTM fn worker exChan = newUnmanagedPrimitiveDisposer disposeFn worker exChan
  where
    disposeFn :: ShortIO (Awaitable ())
    disposeFn = unsafeShortIO $ atomically $
      -- Spawn a thread only if the transaction retries
      (pure <$> fn) `orElse` forkAsyncSTM (atomically fn) worker exChan


registerResource :: (Resource a, MonadQuasar m) => a -> m ()
registerResource resource = do
  rm <- askResourceManager
  ensureSTM $ attachResource rm resource

registerDisposeAction :: MonadQuasar m => IO () -> m Disposer
registerDisposeAction fn = do
  worker <- askIOWorker
  exChan <- askExceptionSink
  rm <- askResourceManager
  ensureSTM do
    disposer <- newUnmanagedIODisposerSTM fn worker exChan
    attachResource rm disposer
    pure disposer

registerDisposeAction_ :: MonadQuasar m => IO () -> m ()
registerDisposeAction_ fn = void $ registerDisposeAction fn

registerDisposeTransaction :: MonadQuasar m => STM () -> m Disposer
registerDisposeTransaction fn = do
  worker <- askIOWorker
  exChan <- askExceptionSink
  rm <- askResourceManager
  ensureSTM do
    disposer <- newUnmanagedSTMDisposerSTM fn worker exChan
    attachResource rm disposer
    pure disposer

registerDisposeTransaction_ :: MonadQuasar m => STM () -> m ()
registerDisposeTransaction_ fn = void $ registerDisposeTransaction fn

registerNewResource :: forall a m. (Resource a, MonadQuasar m) => m a -> m a
registerNewResource fn = do
  rm <- askResourceManager
  disposing <- isJust <$> ensureSTM (peekAwaitableSTM (isDisposing rm))
  -- Bail out before creating the resource _if possible_
  when disposing $ throwM AlreadyDisposing

  maskIfRequired do
    resource <- fn
    registerResource resource `catchAll` \ex -> do
      -- When the resource cannot be registered (because resource manager is now disposing), destroy it to prevent leaks
      disposeEventually_ resource
      case ex of
        (fromException -> Just FailedToAttachResource) -> throwM AlreadyDisposing
        _ -> throwM ex
    pure resource


disposeEventually :: (Resource r, MonadQuasar m) => r -> m (Awaitable ())
disposeEventually res = ensureSTM $ disposeEventuallySTM res

disposeEventually_ :: (Resource r, MonadQuasar m) => r -> m ()
disposeEventually_ res = ensureSTM $ disposeEventuallySTM_ res


captureResources :: MonadQuasar m => m a -> m (a, Disposer)
captureResources fn = do
  quasar <- newQuasar
  localQuasar quasar do
    result <- fn
    pure (result, getDisposer (quasarResourceManager quasar))

captureResources_ :: MonadQuasar m => m () -> m Disposer
captureResources_ fn = snd <$> captureResources fn
