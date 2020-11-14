{-# LANGUAGE UndecidableInstances #-}

module Qd.Observable (
  Observable(..),
  IsGettable(..),
  IsObservable(..),
  unsafeGetValue,
  subscribe',
  SubscriptionHandle(..),
  RegistrationHandle(..),
  IsSettable(..),
  IsDisposable(..),
  ObservableCallback,
  ObservableMessage,
  MessageReason(..),
  ObservableVar,
  newObservableVar,
  withObservableVar,
  modifyObservableVar,
  modifyObservableVar_,
  bindObservable,
  joinObservable,
  joinObservableMaybe,
  joinObservableMaybe',
  joinObservableEither,
  joinObservableEither',
  mergeObservable,
  mergeObservableMaybe,
  constObservable,
  FnObservable(..),
) where

import Qd.Prelude

import Control.Concurrent.MVar
import Control.Exception (Exception)
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Data.Binary (Binary)
import qualified Data.HashMap.Strict as HM
import Data.IORef
import Data.Unique

data MessageReason = Current | Update
  deriving (Eq, Show, Generic)
instance Binary MessageReason

type ObservableMessage v = (MessageReason, v)

mapObservableMessage :: Monad m => (a -> m b) -> ObservableMessage a -> m (ObservableMessage b)
mapObservableMessage f (r, s) = (r, ) <$> f s

newtype SubscriptionHandle = SubscriptionHandle { unsubscribe :: IO () }
newtype RegistrationHandle = RegistrationHandle { deregister :: IO () }

class IsDisposable a where
  dispose :: a -> IO ()
instance IsDisposable SubscriptionHandle where
  dispose = unsubscribe
instance IsDisposable RegistrationHandle where
  dispose = deregister
instance IsDisposable a => IsDisposable (Maybe a) where
  dispose = mapM_ dispose


class IsGettable v a | a -> v where
  getValue :: a -> IO v


class IsGettable v o => IsObservable v o | o -> v where
  subscribe :: o -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  toObservable :: o -> Observable v
  toObservable = Observable
  mapObservable :: (v -> a) -> o -> Observable a
  mapObservable f = mapObservableM (return . f)
  mapObservableM :: (v -> IO a) -> o -> Observable a
  mapObservableM f = Observable . MappedObservable f

-- | Variant of `getValue` that throws exceptions instead of returning them.
unsafeGetValue :: (Exception e, IsObservable (Either e v) o) => o -> IO v
unsafeGetValue = either throw return <=< getValue

-- | A variant of `subscribe` that passes the `SubscriptionHandle` to the callback.
subscribe' :: IsObservable v o => o -> (SubscriptionHandle -> ObservableMessage v -> IO ()) -> IO SubscriptionHandle
subscribe' observable callback = mfix $ \subscription -> subscribe observable (callback subscription)

type ObservableCallback v = ObservableMessage v -> IO ()


instance IsGettable v o => IsGettable v (IO o) where
  getValue :: IO o -> IO v
  getValue getGettable = getValue =<< getGettable
instance IsObservable v o => IsObservable v (IO o) where
  subscribe :: IO o -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  subscribe getObservable callback = do
    observable <- getObservable
    subscribe observable callback


class IsSettable v a | a -> v where
  setValue :: a -> v -> IO ()


-- | Existential quantification wrapper for the IsObservable type class.
data Observable v = forall o. IsObservable v o => Observable o
instance IsGettable v (Observable v) where
  getValue (Observable o) = getValue o
instance IsObservable v (Observable v) where
  subscribe (Observable o) = subscribe o
  toObservable = id
  mapObservable f (Observable o) = mapObservable f o
  mapObservableM f (Observable o) = mapObservableM f o

instance Functor Observable where
  fmap f = mapObservable f
  x <$ _ = constObservable x
instance Applicative Observable where
  pure = constObservable
  liftA2 = mergeObservable
  _ *> x = x
  x <* _ = x
instance Monad Observable where
  (>>=) = bindObservable
  _ >> x = x


data MappedObservable b = forall a o. IsObservable a o => MappedObservable (a -> IO b) o
instance IsGettable v (MappedObservable v) where
  getValue (MappedObservable f observable) = f =<< getValue observable
instance IsObservable v (MappedObservable v) where
  subscribe (MappedObservable f observable) callback = subscribe observable (callback <=< mapObservableMessage f)
  mapObservableM f1 (MappedObservable f2 upstream) = Observable $ MappedObservable (f1 <=< f2) upstream


newtype ObservableVar v = ObservableVar (MVar (v, HM.HashMap Unique (ObservableCallback v)))
instance IsGettable v (ObservableVar v) where
  getValue (ObservableVar mvar) = fst <$> readMVar mvar
instance IsObservable v (ObservableVar v) where
  subscribe (ObservableVar mvar) callback = do
    key <- newUnique
    modifyMVar_ mvar $ \(state, subscribers) -> do
      -- Call listener
      callback (Current, state)
      return (state, HM.insert key callback subscribers)
    return $ SubscriptionHandle $ unsubscribe' key
    where
      unsubscribe' :: Unique -> IO ()
      unsubscribe' key = modifyMVar_ mvar $ \(state, subscribers) -> return (state, HM.delete key subscribers)

instance IsSettable v (ObservableVar v) where
  setValue (ObservableVar mvar) value = modifyMVar_ mvar $ \(_, subscribers) -> do
    mapM_ (\callback -> callback (Update, value)) subscribers
    return (value, subscribers)


newObservableVar :: v -> IO (ObservableVar v)
newObservableVar initialValue = do
  ObservableVar <$> newMVar (initialValue, HM.empty)


modifyObservableVar :: ObservableVar v -> (v -> IO (v, a)) -> IO a
modifyObservableVar (ObservableVar mvar) f =
  modifyMVar mvar $ \(oldState, subscribers) -> do
    (newState, result) <- f oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    return ((newState, subscribers), result)

modifyObservableVar_ :: ObservableVar v -> (v -> IO v) -> IO ()
modifyObservableVar_ (ObservableVar mvar) f =
  modifyMVar_ mvar $ \(oldState, subscribers) -> do
    newState <- f oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    return (newState, subscribers)

withObservableVar :: ObservableVar a -> (a -> IO b) -> IO b
withObservableVar (ObservableVar mvar) f = withMVar mvar (f . fst)



bindObservable :: (IsObservable a ma, IsObservable b mb) => ma -> (a -> mb) -> Observable b
bindObservable x fy = joinObservable $ mapObservable fy x


newtype JoinedObservable o = JoinedObservable o
instance forall o i v. (IsGettable i o, IsGettable v i) => IsGettable v (JoinedObservable o) where
  getValue :: JoinedObservable o -> IO v
  getValue (JoinedObservable outer) = getValue =<< getValue outer
instance forall o i v. (IsObservable i o, IsObservable v i) => IsObservable v (JoinedObservable o) where
  subscribe :: (JoinedObservable o) -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  subscribe (JoinedObservable outer) callback = do
    innerSubscriptionMVar <- newMVar dummySubscription
    outerSubscription <- subscribe outer (outerCallback innerSubscriptionMVar)
    return $ SubscriptionHandle{unsubscribe = unsubscribe outerSubscription >> readMVar innerSubscriptionMVar >>= dispose}
      where
        dummySubscription = SubscriptionHandle { unsubscribe = return () }
        outerCallback innerSubscriptionMVar = outerSubscription'
          where
            outerSubscription' (_, inner) = do
              unsubscribe =<< takeMVar innerSubscriptionMVar
              innerSubscription <- subscribe inner callback
              putMVar innerSubscriptionMVar innerSubscription

joinObservable :: (IsObservable i o, IsObservable v i) => o -> Observable v
joinObservable = Observable . JoinedObservable


joinObservableMaybe :: forall o i v. (IsObservable (Maybe i) o, IsObservable v i) => o -> Observable (Maybe v)
joinObservableMaybe = runMaybeT . join . fmap (MaybeT . fmap Just . toObservable) . MaybeT . toObservable

joinObservableMaybe' :: (IsObservable (Maybe i) o, IsObservable (Maybe v) i) => o -> Observable (Maybe v)
joinObservableMaybe' = runMaybeT . join . fmap (MaybeT . toObservable) . MaybeT . toObservable


joinObservableEither :: (IsObservable (Either e i) o, IsObservable v i) => o -> Observable (Either e v)
joinObservableEither = runExceptT . join . fmap (ExceptT . fmap Right . toObservable) . ExceptT . toObservable

joinObservableEither' :: (IsObservable (Either e i) o, IsObservable (Either e v) i) => o -> Observable (Either e v)
joinObservableEither' = runExceptT . join . fmap (ExceptT . toObservable) . ExceptT . toObservable


data MergedObservable o0 v0 o1 v1 r = MergedObservable (v0 -> v1 -> r) o0 o1
instance forall o0 v0 o1 v1 r. (IsGettable v0 o0, IsGettable v1 o1) => IsGettable r (MergedObservable o0 v0 o1 v1 r) where
  getValue (MergedObservable merge obs0 obs1) = do
    x0 <- getValue obs0
    x1 <- getValue obs1
    return $ merge x0 x1
instance forall o0 v0 o1 v1 r. (IsObservable v0 o0, IsObservable v1 o1) => IsObservable r (MergedObservable o0 v0 o1 v1 r) where
  subscribe (MergedObservable merge obs0 obs1) callback = do
    currentValuesTupleRef <- newIORef (Nothing, Nothing)
    sub0 <- subscribe obs0 (mergeCallback currentValuesTupleRef . fmap Left)
    sub1 <- subscribe obs1 (mergeCallback currentValuesTupleRef . fmap Right)
    return $ SubscriptionHandle{unsubscribe = unsubscribe sub0 >> unsubscribe sub1}
    where
      mergeCallback :: IORef (Maybe v0, Maybe v1) -> (MessageReason, Either v0 v1) -> IO ()
      mergeCallback currentValuesTupleRef (reason, state) = do
        currentTuple <- atomicModifyIORef' currentValuesTupleRef (dup . updateTuple state)
        case currentTuple of
          (Just l, Just r) -> callback (reason, uncurry merge (l, r))
          _ -> return () -- Start only once both values have been received
      updateTuple :: Either v0 v1 -> (Maybe v0, Maybe v1) -> (Maybe v0, Maybe v1)
      updateTuple (Left l) (_, r) = (Just l, r)
      updateTuple (Right r) (l, _) = (l, Just r)


-- | Merge two observables using a given merge function. Whenever the value of one of the inputs changes, the resulting observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
mergeObservable :: (IsObservable v0 o0, IsObservable v1 o1) => (v0 -> v1 -> r) -> o0 -> o1 -> Observable r
mergeObservable merge x y = Observable $ MergedObservable merge x y

-- | Similar to `mergeObservable`, but built to operator on `Maybe` values: If either input value is `Nothing`, the resulting value will be `Nothing`.
mergeObservableMaybe :: (IsObservable (Maybe v0) o0, IsObservable (Maybe v1) o1) => (v0 -> v1 -> r) -> o0 -> o1 -> Observable (Maybe r)
mergeObservableMaybe merge x y = Observable $ MergedObservable (liftA2 merge) x y


-- | Data type that can be used as an implementation for the `IsObservable` interface that works by directly providing functions for `getValue` and `subscribe`.
data FnObservable v = FnObservable {
  getValueFn :: IO v,
  subscribeFn :: (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
}
instance IsGettable v (FnObservable v) where
  getValue o = getValueFn o
instance IsObservable v (FnObservable v) where
  subscribe o = subscribeFn o
  mapObservableM f FnObservable{getValueFn, subscribeFn} = Observable $ FnObservable {
    getValueFn = getValueFn >>= f,
    subscribeFn = \listener -> subscribeFn (mapObservableMessage f >=> listener)
  }


newtype ConstObservable a = ConstObservable a
instance IsGettable a (ConstObservable a) where
  getValue (ConstObservable x) = return x
instance IsObservable a (ConstObservable a) where
  subscribe (ConstObservable x) callback = do
    callback (Current, x)
    return $ SubscriptionHandle { unsubscribe = return () }
-- | Create an observable that contains a constant value.
constObservable :: a -> Observable a
constObservable = Observable . ConstObservable


-- TODO implement
_cacheObservable :: IsObservable v o => o -> Observable v
_cacheObservable = Observable
