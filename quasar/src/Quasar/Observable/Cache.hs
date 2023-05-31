{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Cache (
  cacheObservable,
  observeCachedObservable,
) where

import Control.Applicative
import Control.Monad.Except
import Data.Functor.Identity
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry

-- * Cache

newtype CachedObservable canWait exceptions c v = CachedObservable (TVar (CacheState canWait exceptions c v))

data CacheState canWait exceptions c v
  = forall a. IsObservable canWait exceptions c v a => CacheIdle a
  | forall a. IsObservable canWait exceptions c v a =>
    CacheAttached
      a
      TSimpleDisposer
      (CallbackRegistry (Final, EvaluatedObservableChange canWait exceptions c v))
      (ObserverState canWait exceptions c v)
  | CacheFinalized (ObservableState canWait exceptions c v)

instance ObservableContainer c v => ToObservable canWait exceptions c v (CachedObservable canWait exceptions c v)

instance ObservableContainer c v => IsObservable canWait exceptions c v (CachedObservable canWait exceptions c v) where
  readObservable# (CachedObservable var) = do
    readTVar var >>= \case
      CacheIdle x -> readObservable# x
      CacheAttached _x _disposer _registry state -> pure (False, toObservableState state)
      CacheFinalized state -> pure (True, state)
  attachEvaluatedObserver# (CachedObservable var) callback = do
    readTVar var >>= \case
      CacheIdle upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeCacheListener
        (upstreamDisposer, final, state) <- attachEvaluatedObserver# upstream updateCache
        writeTVar var (CacheAttached upstream upstreamDisposer registry (createObserverState state))
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, final, state)
      CacheAttached _ _ registry value -> do
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, False, toObservableState value)
      CacheFinalized value -> pure (mempty, True, value)
    where
      removeCacheListener :: STMc NoRetry '[] ()
      removeCacheListener = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer _ _ -> do
            writeTVar var (CacheIdle upstream)
            disposeTSimpleDisposer upstreamDisposer
          CacheFinalized _ -> pure ()
      updateCache :: Final -> EvaluatedObservableChange canWait exceptions c v -> STMc NoRetry '[] ()
      updateCache final change = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer registry oldState -> do
            let mstate = applyEvaluatedObservableChange change oldState
            if final
              then do
                writeTVar var (CacheFinalized (toObservableState (fromMaybe oldState mstate)))
                callCallbacks registry (final, change)
                clearCallbackRegistry registry
              else do
                forM_ mstate \state -> do
                  writeTVar var (CacheAttached upstream upstreamDisposer registry state)
                  callCallbacks registry (final, change)
          CacheFinalized _ -> pure () -- Upstream implementation error

  isCachedObservable# _ = True

cacheObservable :: (ToObservable canWait exceptions c v a, MonadSTMc NoRetry '[] m) => a -> m (Observable canWait exceptions c v)
cacheObservable x =
  case toObservable x of
    c@(ConstObservable _) -> pure c
    y@(Observable f) ->
      if isCachedObservable# f
        then pure y
        else Observable . CachedObservable <$> newTVar (CacheIdle f)


-- ** Embedded cache in the Observable monad

data CacheObservableOperation canWait exceptions w e c v = forall a. ToObservable w e c v a => CacheObservableOperation a

instance ToObservable canWait exceptions Identity (Observable w e c v) (CacheObservableOperation canWait exceptions w e c v)

instance IsObservable canWait exceptions Identity (Observable w e c v) (CacheObservableOperation canWait exceptions w e c v) where
  readObservable# (CacheObservableOperation x) = do
    cache <- cacheObservable x
    pure (True, ObservableStateLive (Right (Identity cache)))
  attachObserver# (CacheObservableOperation x) _callback = do
    cache <- cacheObservable x
    pure (mempty, True, ObservableStateLive (Right (Identity cache)))

-- | Cache an observable in the `ObservableI` monad. Use with care! A new cache
-- is recreated whenever the result of this function is reevaluated.
observeCachedObservable :: forall canWait exceptions w e c v a. ToObservable w e c v a => a -> ObservableI canWait exceptions (Observable w e c v)
observeCachedObservable x =
  case toObservable x of
    c@(ConstObservable _) -> pure c
    (Observable f) -> Observable (CacheObservableOperation @canWait @exceptions f)
