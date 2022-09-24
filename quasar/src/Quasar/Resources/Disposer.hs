{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.Disposer (
  Resource(..),
  Disposer,
  dispose,
  disposeEventuallySTM,
  disposeEventuallySTM_,
  newUnmanagedPrimitiveDisposer,
  newUnmanagedIODisposer,
  newUnmanagedSTMDisposer,
  trivialDisposer,

  TDisposer,
  disposeTDisposer,

  -- * Resource manager
  ResourceManager,
  newUnmanagedResourceManagerSTM,
  attachResource,
) where


import Control.Monad (foldM)
import Control.Monad.Catch
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import Quasar.Async.Fork
import Quasar.Async.STMHelper
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO
import Quasar.Utils.TOnce


class Resource a where
  toDisposer :: a -> Disposer

  isDisposed :: a -> Future ()
  isDisposed r = isDisposed (toDisposer r)

  isDisposing :: a -> Future ()
  isDisposing r = isDisposing (toDisposer r)



newtype Disposer = Disposer [DisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Resource Disposer where
  toDisposer = id
  isDisposed (Disposer ds) = foldMap isDisposed ds
  isDisposing (Disposer ds) = awaitAny $ isDisposing <$> ds

newtype TDisposer = TDisposer [TDisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Resource TDisposer where
  toDisposer (TDisposer ds) = toDisposer ds


type DisposerState = TOnce DisposeFn (Future ())

data DisposerElement
  = IODisposer Unique TIOWorker ExceptionSink DisposerState Finalizers
  | STMDisposer TDisposerElement
  | ResourceManagerDisposer ResourceManager

instance Resource DisposerElement where
  toDisposer disposer = Disposer [disposer]

  isDisposed (IODisposer _ _ _ state _) = join (toFuture state)
  isDisposed (STMDisposer tdisposer) = isDisposed tdisposer
  isDisposed (ResourceManagerDisposer resourceManager) = resourceManagerIsDisposed resourceManager

  isDisposing (IODisposer _ _ _ state _) = void (toFuture state)
  isDisposing (STMDisposer tdisposer) = isDisposing tdisposer
  isDisposing (ResourceManagerDisposer resourceManager) = resourceManagerIsDisposing resourceManager


type DisposeFn = ShortIO (Future ())


type STMDisposerState = TOnce (STM ()) (Future ())

data TDisposerElement = TDisposerElement Unique TIOWorker ExceptionSink STMDisposerState Finalizers

newUnmanagedSTMDisposer :: STM () -> TIOWorker -> ExceptionSink -> STM TDisposer
newUnmanagedSTMDisposer fn worker sink = do
  key <- newUniqueSTM
  element <-  TDisposerElement key worker sink <$> newTOnce fn <*> newFinalizers
  pure $ TDisposer [element]

instance Resource TDisposerElement where
  toDisposer disposer = Disposer [STMDisposer disposer]
  isDisposed (TDisposerElement _ _ _ state _) = join (toFuture state)
  isDisposing (TDisposerElement _ _ _ state _) = void (toFuture state)

instance Resource [TDisposerElement] where
  toDisposer tds = Disposer (STMDisposer <$> tds)
  isDisposed tds = isDisposed (toDisposer tds)
  isDisposing tds = isDisposing (toDisposer tds)

disposeTDisposer :: TDisposer -> STM ()
disposeTDisposer (TDisposer elements) = mapM_ go elements
  where
    go (TDisposerElement _ _ sink state finalizers) = do
      future <- mapFinalizeTOnce state startDisposeFn
      -- Elements can also be disposed by a resource manager (on a dedicated thread).
      -- In that case that thread has to be awaited (otherwise this is a no-op).
      awaitSTM future
      where
        startDisposeFn :: STM () -> STM (Future ())
        startDisposeFn disposeFn = do
          disposeFn `catchAll` throwToExceptionSink sink
          runFinalizers finalizers
          pure $ pure ()

beginDisposeSTMDisposer :: TDisposerElement -> STM (Future ())
beginDisposeSTMDisposer (TDisposerElement _ worker sink state finalizers) =
  mapFinalizeTOnce state startDisposeFn
  where
    startDisposeFn :: STM () -> STM (Future ())
    startDisposeFn fn = do
      awaitableVar <- newPromiseSTM
      startShortIOSTM_ (runDisposeFn awaitableVar disposeFn) worker sink
      pure $ join (toFuture awaitableVar)
      where
        disposeFn :: ShortIO (Future ())
        disposeFn = unsafeShortIO $ atomically $
          -- Spawn a thread only if the transaction retries
          (pure <$> fn) `orElse` forkAsyncSTM (atomically fn) worker sink

    runDisposeFn :: Promise (Future ()) -> DisposeFn -> ShortIO ()
    runDisposeFn awaitableVar disposeFn = mask_ $ handleAll exceptionHandler do
      awaitable <- disposeFn
      fulfillPromiseShortIO awaitableVar awaitable
      runFinalizersAfter finalizers awaitable
      where
        -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
        exceptionHandler :: SomeException -> ShortIO ()
        exceptionHandler ex = do
          fulfillPromiseShortIO awaitableVar (pure ())
          runFinalizersShortIO finalizers
          throwM $ DisposeException ex



-- | A trivial disposer that does not perform any action when disposed.
trivialDisposer :: Disposer
trivialDisposer = mempty

newUnmanagedPrimitiveDisposer :: ShortIO (Future ()) -> TIOWorker -> ExceptionSink -> STM Disposer
newUnmanagedPrimitiveDisposer fn worker exChan = toDisposer <$> do
  key <- newUniqueSTM
  IODisposer key worker exChan <$> newTOnce fn <*> newFinalizers

newUnmanagedIODisposer :: IO () -> TIOWorker -> ExceptionSink -> STM Disposer
-- TODO change TIOWorker behavior for spawning threads, so no `unsafeShortIO` is necessary
newUnmanagedIODisposer fn worker exChan = newUnmanagedPrimitiveDisposer (unsafeShortIO $ forkFuture fn exChan) worker exChan



dispose :: (MonadIO m, Resource r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventuallySTM resource)

disposeEventuallySTM :: Resource r => r -> STM (Future ())
disposeEventuallySTM (toDisposer -> Disposer ds) = mconcat <$> mapM f ds
  where
    f :: DisposerElement -> STM (Future ())
    f (IODisposer _ worker exChan state finalizers) =
      beginDisposeFnDisposer worker exChan state finalizers
    f (STMDisposer disposer) = beginDisposeSTMDisposer disposer
    f (ResourceManagerDisposer resourceManager) =
      beginDisposeResourceManager resourceManager

disposeEventuallySTM_ :: Resource r => r -> STM ()
disposeEventuallySTM_ resource = void $ disposeEventuallySTM resource




beginDisposeFnDisposer :: TIOWorker -> ExceptionSink -> DisposerState -> Finalizers -> STM (Future ())
beginDisposeFnDisposer worker exChan disposeState finalizers =
  mapFinalizeTOnce disposeState startDisposeFn
  where
    startDisposeFn :: DisposeFn -> STM (Future ())
    startDisposeFn disposeFn = do
      awaitableVar <- newPromiseSTM
      startShortIOSTM_ (runDisposeFn awaitableVar disposeFn) worker exChan
      pure $ join (toFuture awaitableVar)

    runDisposeFn :: Promise (Future ()) -> DisposeFn -> ShortIO ()
    runDisposeFn awaitableVar disposeFn = mask_ $ handleAll exceptionHandler do
      awaitable <- disposeFn
      fulfillPromiseShortIO awaitableVar awaitable
      runFinalizersAfter finalizers awaitable
      where
        -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
        exceptionHandler :: SomeException -> ShortIO ()
        exceptionHandler ex = do
          fulfillPromiseShortIO awaitableVar (pure ())
          runFinalizersShortIO finalizers
          throwM $ DisposeException ex

disposerKey :: DisposerElement -> Unique
disposerKey (IODisposer key _ _ _ _) = key
disposerKey (STMDisposer (TDisposerElement key _ _ _ _)) = key
disposerKey (ResourceManagerDisposer resourceManager) = resourceManagerKey resourceManager


disposerFinalizers :: DisposerElement -> Finalizers
disposerFinalizers (IODisposer _ _ _ _ finalizers) = finalizers
disposerFinalizers (STMDisposer (TDisposerElement _ _ _ _ finalizers)) = finalizers
disposerFinalizers (ResourceManagerDisposer rm) = resourceManagerFinalizers rm


data DisposeResult
  = DisposeResultAwait (Future ())
  | DisposeResultDependencies DisposeDependencies

data DisposeDependencies = DisposeDependencies Unique (Future [DisposeDependencies])


-- * Resource manager

data ResourceManager = ResourceManager {
  resourceManagerKey :: Unique,
  resourceManagerState :: TVar ResourceManagerState,
  resourceManagerFinalizers :: Finalizers
}

data ResourceManagerState
  = ResourceManagerNormal (TVar (HashMap Unique DisposerElement)) TIOWorker ExceptionSink
  | ResourceManagerDisposing (Future [DisposeDependencies])
  | ResourceManagerDisposed

instance Resource ResourceManager where
  toDisposer rm = Disposer [ResourceManagerDisposer rm]
  isDisposed = resourceManagerIsDisposed
  isDisposing = resourceManagerIsDisposing


newUnmanagedResourceManagerSTM :: TIOWorker -> ExceptionSink -> STM ResourceManager
newUnmanagedResourceManagerSTM worker exChan = do
  resourceManagerKey <- newUniqueSTM
  attachedResources <- newTVar mempty
  resourceManagerState <- newTVar (ResourceManagerNormal attachedResources worker exChan)
  resourceManagerFinalizers <- newFinalizers
  pure ResourceManager {
    resourceManagerKey,
    resourceManagerState,
    resourceManagerFinalizers
  }


attachResource :: Resource a => ResourceManager -> a -> STM ()
attachResource resourceManager (toDisposer -> Disposer ds) =
  mapM_ (attachDisposer resourceManager) ds

attachDisposer :: ResourceManager -> DisposerElement -> STM ()
attachDisposer resourceManager disposer = do
  readTVar (resourceManagerState resourceManager) >>= \case
    ResourceManagerNormal attachedResources _ _ -> do
      alreadyAttached <- isJust . HM.lookup key <$> readTVar attachedResources
      unless alreadyAttached do
        -- Returns false if the disposer is already finalized
        attachedFinalizer <- registerFinalizer (disposerFinalizers disposer) finalizer
        when attachedFinalizer $ modifyTVar attachedResources (HM.insert key disposer)
    _ -> throwM $ userError "failed to attach resource" -- TODO throw proper exception
  where
    key :: Unique
    key = disposerKey disposer
    finalizer :: STM ()
    finalizer = readTVar (resourceManagerState resourceManager) >>= \case
      ResourceManagerNormal attachedResources _ _ -> modifyTVar attachedResources (HM.delete key)
      -- No finalization required in other states, since all resources are disposed soon
      -- (and awaiting each resource is cheaper than modifying a HashMap until it is empty).
      _ -> pure ()


beginDisposeResourceManager :: ResourceManager -> STM (Future ())
beginDisposeResourceManager rm = do
  void $ beginDisposeResourceManagerInternal rm
  pure $ resourceManagerIsDisposed rm

beginDisposeResourceManagerInternal :: ResourceManager -> STM DisposeDependencies
beginDisposeResourceManagerInternal rm = do
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal attachedResources worker exChan -> do
      dependenciesVar <- newPromiseSTM
      writeTVar (resourceManagerState rm) (ResourceManagerDisposing (toFuture dependenciesVar))
      attachedDisposers <- HM.elems <$> readTVar attachedResources
      startShortIOSTM_ (void $ forkIOShortIO (disposeThread dependenciesVar attachedDisposers)) worker exChan
      pure $ DisposeDependencies rmKey (toFuture dependenciesVar)
    ResourceManagerDisposing deps -> pure $ DisposeDependencies rmKey deps
    ResourceManagerDisposed -> pure $ DisposeDependencies rmKey mempty
  where
    disposeThread :: Promise [DisposeDependencies] -> [DisposerElement] -> IO ()
    disposeThread dependenciesVar attachedDisposers = do
      -- Begin to dispose all attached resources
      results <- mapM (atomically . resourceManagerBeginDispose) attachedDisposers
      -- Await direct resource awaitables and collect indirect dependencies
      dependencies <- await (collectDependencies results)
      -- Publish "direct dependencies complete"-status
      fulfillPromise dependenciesVar dependencies
      -- Await indirect dependencies
      awaitDisposeDependencies $ DisposeDependencies rmKey (pure dependencies)
      -- Set state to disposed and run finalizers
      atomically do
        writeTVar (resourceManagerState rm) ResourceManagerDisposed
        runFinalizers (resourceManagerFinalizers rm)

    rmKey :: Unique
    rmKey = resourceManagerKey rm

    resourceManagerBeginDispose :: DisposerElement -> STM DisposeResult
    resourceManagerBeginDispose (IODisposer _ worker exChan state finalizers) =
      DisposeResultAwait <$> beginDisposeFnDisposer worker exChan state finalizers
    resourceManagerBeginDispose (STMDisposer disposer) =
      DisposeResultAwait <$> beginDisposeSTMDisposer disposer
    resourceManagerBeginDispose (ResourceManagerDisposer resourceManager) =
      DisposeResultDependencies <$> beginDisposeResourceManagerInternal resourceManager

    collectDependencies :: [DisposeResult] -> Future [DisposeDependencies]
    collectDependencies (DisposeResultAwait awaitable : xs) = awaitable >> collectDependencies xs
    collectDependencies (DisposeResultDependencies deps : xs) = (deps : ) <$> collectDependencies xs
    collectDependencies [] = pure []

    awaitDisposeDependencies :: DisposeDependencies -> IO ()
    awaitDisposeDependencies = void . go mempty
      where
        go :: HashSet Unique -> DisposeDependencies -> IO (HashSet Unique)
        go keys (DisposeDependencies key deps)
          | HashSet.member key keys = pure keys -- loop detection: dependencies were already handled
          | otherwise = do
              dependencies <- await deps
              foldM go (HashSet.insert key keys) dependencies


resourceManagerIsDisposed :: ResourceManager -> Future ()
resourceManagerIsDisposed rm = unsafeAwaitSTM $
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerDisposed -> pure ()
    _ -> retry

resourceManagerIsDisposing :: ResourceManager -> Future ()
resourceManagerIsDisposing rm = unsafeAwaitSTM $
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal {} -> retry
    _ -> pure ()



-- * Implementation internals

newtype Finalizers = Finalizers (TMVar [STM ()])

newFinalizers :: STM Finalizers
newFinalizers = do
  Finalizers <$> newTMVar []

registerFinalizer :: Finalizers -> STM () -> STM Bool
registerFinalizer (Finalizers finalizerVar) finalizer =
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> do
      putTMVar finalizerVar (finalizer : finalizers)
      pure True
    Nothing -> pure False

runFinalizers :: Finalizers -> STM ()
runFinalizers (Finalizers finalizerVar) = do
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> sequence_ finalizers
    Nothing -> throwM $ userError "runFinalizers was called multiple times (it must only be run once)"

runFinalizersShortIO :: Finalizers -> ShortIO ()
runFinalizersShortIO finalizers = unsafeShortIO $ atomically $ runFinalizers finalizers

runFinalizersAfter :: Finalizers -> Future () -> ShortIO ()
runFinalizersAfter finalizers awaitable = do
  -- Peek awaitable to ensure trivial disposers always run without forking
  isCompleted <- isJust <$> peekFutureShortIO awaitable
  if isCompleted
    then
      runFinalizersShortIO finalizers
    else
      void $ forkIOShortIO do
        await awaitable
        atomically $ runFinalizers finalizers