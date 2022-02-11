{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.Disposer (
  Resource(..),
  Disposer,
  dispose,
  disposeEventuallySTM,
  disposeEventuallySTM_,
  isDisposed,
  newPrimitiveDisposer,

  -- * Resource manager
  ResourceManager,
  newResourceManagerSTM,
  attachResource,
) where


import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (foldM)
import Control.Monad.Catch
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import Quasar.Async.STMHelper
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.TOnce


class Resource a where
  getDisposer :: a -> Disposer


type DisposerState = TOnce DisposeFn (Awaitable ())

data Disposer
  = FnDisposer Unique TIOWorker ExceptionChannel DisposerState Finalizers
  | ResourceManagerDisposer ResourceManager

instance Resource Disposer where
  getDisposer = id

type DisposeFn = IO (Awaitable ())


-- TODO document: IO has to be "short"
newPrimitiveDisposer :: TIOWorker -> ExceptionChannel -> IO (Awaitable ()) -> STM Disposer
newPrimitiveDisposer worker exChan fn = do
  key <- newUniqueSTM
  FnDisposer key worker exChan <$> newTOnce fn <*> newFinalizers


dispose :: (MonadIO m, Resource r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventuallySTM resource)

disposeEventuallySTM :: Resource r => r -> STM (Awaitable ())
disposeEventuallySTM resource =
  case getDisposer resource of
    FnDisposer _ worker exChan state finalizers -> do
      beginDisposeFnDisposer worker exChan state finalizers
    ResourceManagerDisposer resourceManager ->
      beginDisposeResourceManager resourceManager

disposeEventuallySTM_ :: Resource r => r -> STM ()
disposeEventuallySTM_ resource = void $ disposeEventuallySTM resource


isDisposed :: Resource a => a -> Awaitable ()
isDisposed resource =
  case getDisposer resource of
    FnDisposer _ _ _ state _ -> join (toAwaitable state)
    ResourceManagerDisposer resourceManager -> resourceManagerIsDisposed resourceManager


beginDisposeFnDisposer :: TIOWorker -> ExceptionChannel -> DisposerState -> Finalizers -> STM (Awaitable ())
beginDisposeFnDisposer worker exChan disposeState finalizers =
  mapFinalizeTOnce disposeState startDisposeFn
  where
    startDisposeFn :: DisposeFn -> STM (Awaitable ())
    startDisposeFn disposeFn = do
      awaitableVar <- newAsyncVarSTM
      startShortIO_ worker exChan (runDisposeFn awaitableVar disposeFn)
      pure $ join (toAwaitable awaitableVar)

    runDisposeFn :: AsyncVar (Awaitable ()) -> DisposeFn -> IO ()
    runDisposeFn awaitableVar disposeFn = mask_ $ handleAll exceptionHandler do
      awaitable <- disposeFn
      putAsyncVar_ awaitableVar awaitable
      runFinalizersAfter finalizers awaitable
      where
        exceptionHandler :: SomeException -> IO ()
        exceptionHandler ex = do
          -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
          putAsyncVar_ awaitableVar (pure ())
          atomically $ runFinalizers finalizers
          throwIO $ DisposeException ex

disposerKey :: Disposer -> Unique
disposerKey (FnDisposer key _ _ _ _) = key
disposerKey (ResourceManagerDisposer resourceManager) = resourceManagerKey resourceManager


disposerFinalizers :: Disposer -> Finalizers
disposerFinalizers (FnDisposer _ _ _ _ finalizers) = finalizers
disposerFinalizers (ResourceManagerDisposer rm) = resourceManagerFinalizers rm



data DisposeResult
  = DisposeResultAwait (Awaitable ())
  | DisposeResultDependencies DisposeDependencies

data DisposeDependencies = DisposeDependencies Unique (Awaitable [DisposeDependencies])


-- * Resource manager

data ResourceManager = ResourceManager {
  resourceManagerKey :: Unique,
  resourceManagerState :: TVar ResourceManagerState,
  resourceManagerFinalizers :: Finalizers
}

data ResourceManagerState
  = ResourceManagerNormal (TVar (HashMap Unique Disposer)) TIOWorker
  | ResourceManagerDisposing (Awaitable [DisposeDependencies])
  | ResourceManagerDisposed

instance Resource ResourceManager where
  getDisposer = ResourceManagerDisposer


newResourceManagerSTM :: TIOWorker -> ExceptionChannel -> STM ResourceManager
newResourceManagerSTM worker exChan = do
  resourceManagerKey <- newUniqueSTM
  attachedResources <- newTVar mempty
  resourceManagerState <- newTVar (ResourceManagerNormal attachedResources worker)
  resourceManagerFinalizers <- newFinalizers
  pure ResourceManager {
    resourceManagerKey,
    resourceManagerState,
    resourceManagerFinalizers
  }


attachResource :: Resource a => ResourceManager -> a -> STM ()
attachResource resourceManager resource =
  attachDisposer resourceManager (getDisposer resource)

attachDisposer :: ResourceManager -> Disposer -> STM ()
attachDisposer resourceManager disposer = do
  readTVar (resourceManagerState resourceManager) >>= \case
    ResourceManagerNormal attachedResources _ -> do
      alreadyAttached <- isJust . HM.lookup key <$> readTVar attachedResources
      unless alreadyAttached do
        -- Returns false if the disposer is already finalized
        attachedFinalizer <- registerFinalizer (disposerFinalizers disposer) finalizer
        when attachedFinalizer $ modifyTVar attachedResources (HM.insert key disposer)
    _ -> undefined -- failed to attach resource; arguably this should just dispose?
  where
    key :: Unique
    key = disposerKey disposer
    finalizer :: STM ()
    finalizer = readTVar (resourceManagerState resourceManager) >>= \case
      ResourceManagerNormal attachedResources _ -> modifyTVar attachedResources (HM.delete key)
      -- No finalization required in other states, since all resources are disposed soon
      -- (and awaiting each resource is cheaper than modifying a HashMap until it is empty).
      _ -> pure ()


beginDisposeResourceManager :: ResourceManager -> STM (Awaitable ())
beginDisposeResourceManager rm = do
  void $ beginDisposeResourceManagerInternal rm
  pure $ resourceManagerIsDisposed rm

beginDisposeResourceManagerInternal :: ResourceManager -> STM DisposeDependencies
beginDisposeResourceManagerInternal rm = do
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal attachedResources worker -> do
      dependenciesVar <- newAsyncVarSTM
      writeTVar (resourceManagerState rm) (ResourceManagerDisposing (toAwaitable dependenciesVar))
      attachedDisposers <- HM.elems <$> readTVar attachedResources
      startShortIO_ worker undefined (void $ forkIO (disposeThread dependenciesVar attachedDisposers))
      pure $ DisposeDependencies rmKey (toAwaitable dependenciesVar)
    ResourceManagerDisposing deps -> pure $ DisposeDependencies rmKey deps
    ResourceManagerDisposed -> pure $ DisposeDependencies rmKey mempty
  where
    disposeThread :: AsyncVar [DisposeDependencies] -> [Disposer] -> IO ()
    disposeThread dependenciesVar attachedDisposers = do
      -- Begin to dispose all attached resources
      results <- mapM (atomically . resourceManagerBeginDispose) attachedDisposers
      -- Await direct resource awaitables and collect indirect dependencies
      dependencies <- await (collectDependencies results)
      -- Publish "direct dependencies complete"-status
      putAsyncVar_ dependenciesVar dependencies
      -- Await indirect dependencies
      awaitDisposeDependencies $ DisposeDependencies rmKey (pure dependencies)
      -- Set state to disposed and run finalizers
      atomically do
        writeTVar (resourceManagerState rm) ResourceManagerDisposed
        runFinalizers (resourceManagerFinalizers rm)

    rmKey :: Unique
    rmKey = resourceManagerKey rm

    resourceManagerBeginDispose :: Disposer -> STM DisposeResult
    resourceManagerBeginDispose (FnDisposer _ worker exChan state finalizers) =
      DisposeResultAwait <$> beginDisposeFnDisposer worker exChan state finalizers
    resourceManagerBeginDispose (ResourceManagerDisposer resourceManager) =
      DisposeResultDependencies <$> beginDisposeResourceManagerInternal resourceManager

    collectDependencies :: [DisposeResult] -> Awaitable [DisposeDependencies]
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


resourceManagerIsDisposed :: ResourceManager -> Awaitable ()
resourceManagerIsDisposed rm = unsafeAwaitSTM $
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerDisposed -> pure ()
    _ -> retry


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

runFinalizersAfter :: Finalizers -> Awaitable () -> IO ()
runFinalizersAfter finalizers awaitable = do
  -- Peek awaitable to ensure trivial disposables always run without forking
  isCompleted <- isJust <$> peekAwaitable awaitable
  if isCompleted
    then
      atomically $ runFinalizers finalizers
    else
      void $ forkIO do
        await awaitable
        atomically $ runFinalizers finalizers
