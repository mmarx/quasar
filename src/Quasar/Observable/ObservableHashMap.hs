{-# LANGUAGE ViewPatterns #-}

module Quasar.Observable.ObservableHashMap (
  ObservableHashMap,
  new,
  observeKey,
  insert,
  delete,
  lookup,
  lookupDelete,
) where

import Data.HashMap.Strict qualified as HM
import Data.Maybe (isJust)
import Language.Haskell.TH.Syntax (mkName, nameBase)
import Lens.Micro.Platform
import Quasar.Core
import Quasar.Observable
import Quasar.Observable.Delta
import Quasar.Prelude hiding (lookup, lookupDelete)
import Quasar.Utils.ExtraT


newtype ObservableHashMap k v = ObservableHashMap (MVar (Handle k v))
data Handle k v = Handle {
  keyHandles :: HM.HashMap k (KeyHandle v),
  subscribers :: HM.HashMap Unique (ObservableMessage (HM.HashMap k v) -> IO ()),
  deltaSubscribers :: HM.HashMap Unique (Delta k v -> IO ())
}

data KeyHandle v = KeyHandle {
  value :: Maybe v,
  keySubscribers :: HM.HashMap Unique (ObservableMessage (Maybe v) -> IO ())
}

makeLensesWith (lensField .~ (\_ _ -> pure . TopName . mkName . ("_" <>) . nameBase) $ lensRules) ''Handle
makeLensesWith (lensField .~ (\_ _ -> pure . TopName . mkName . ("_" <>) . nameBase) $ lensRules) ''KeyHandle

instance IsRetrievable (HM.HashMap k v) (ObservableHashMap k v) where
  retrieve (ObservableHashMap mvar) = liftIO $ HM.mapMaybe value . keyHandles <$> readMVar mvar
instance IsObservable (HM.HashMap k v) (ObservableHashMap k v) where
  subscribe ohm callback = modifyHandle update ohm
    where
      update :: Handle k v -> IO (Handle k v, Disposable)
      update handle = do
        callback (Current, toHashMap handle)
        unique <- newUnique
        let handle' = handle & set (_subscribers . at unique) (Just callback)
        pure (handle', synchronousDisposable (unsubscribe unique))
      unsubscribe :: Unique -> IO ()
      unsubscribe unique = modifyHandle_ (pure . set (_subscribers . at unique) Nothing) ohm

instance IsDeltaObservable k v (ObservableHashMap k v) where
  subscribeDelta ohm callback = modifyHandle update ohm
    where
      update :: Handle k v -> IO (Handle k v, Disposable)
      update handle = do
        callback (Reset $ toHashMap handle)
        unique <- newUnique
        let handle' = handle & set (_deltaSubscribers . at unique) (Just callback)
        pure (handle', synchronousDisposable (unsubscribe unique))
      unsubscribe :: Unique -> IO ()
      unsubscribe unique = modifyHandle_ (pure . set (_deltaSubscribers . at unique) Nothing) ohm


toHashMap :: Handle k v -> HM.HashMap k v
toHashMap = HM.mapMaybe value . keyHandles

modifyHandle :: (Handle k v -> IO (Handle k v, a)) -> ObservableHashMap k v -> IO a
modifyHandle f (ObservableHashMap mvar) = modifyMVar mvar f

modifyHandle_ :: (Handle k v -> IO (Handle k v)) -> ObservableHashMap k v -> IO ()
modifyHandle_ f = modifyHandle (fmap (,()) . f)

modifyKeyHandle :: (Eq k, Hashable k) => (KeyHandle v -> IO (KeyHandle v, a)) -> k -> ObservableHashMap k v -> IO a
modifyKeyHandle f k = modifyHandle (updateKeyHandle f k)

modifyKeyHandle_ :: forall k v. (Eq k, Hashable k) => (KeyHandle v -> IO (KeyHandle v)) -> k -> ObservableHashMap k v -> IO ()
modifyKeyHandle_ f = modifyKeyHandle (fmap (,()) . f)

updateKeyHandle :: forall k v a. (Eq k, Hashable k) => (KeyHandle v -> IO (KeyHandle v, a)) -> k -> Handle k v -> IO (Handle k v, a)
updateKeyHandle f k = runExtraT . (_keyHandles (HM.alterF updateMaybe k))
  where
    updateMaybe :: Maybe (KeyHandle v) -> ExtraT a IO (Maybe (KeyHandle v))
    updateMaybe = fmap toMaybe . (ExtraT . f) . fromMaybe emptyKeyHandle
    emptyKeyHandle :: KeyHandle v
    emptyKeyHandle = KeyHandle Nothing HM.empty
    toMaybe :: KeyHandle v -> Maybe (KeyHandle v)
    toMaybe (KeyHandle Nothing (HM.null -> True)) = Nothing
    toMaybe keyHandle = Just keyHandle

modifyKeyHandleNotifying :: (Eq k, Hashable k) => (KeyHandle v -> IO (KeyHandle v, (Maybe (Delta k v), a))) -> k -> ObservableHashMap k v -> IO a
modifyKeyHandleNotifying f k = modifyHandle $ \handle -> do
  (newHandle, (delta, result)) <- updateKeyHandle f k handle
  notifySubscribers newHandle delta
  pure (newHandle, result)

modifyKeyHandleNotifying_ :: (Eq k, Hashable k) => (KeyHandle v -> IO (KeyHandle v, Maybe (Delta k v))) -> k -> ObservableHashMap k v -> IO ()
modifyKeyHandleNotifying_ f k = modifyHandle_ $ \handle -> do
  (newHandle, delta) <- updateKeyHandle f k handle
  notifySubscribers newHandle delta
  pure newHandle

notifySubscribers :: Handle k v -> Maybe (Delta k v) -> IO ()
notifySubscribers _ Nothing = pure ()
notifySubscribers handle@Handle{deltaSubscribers, subscribers} (Just delta) = do
  mapM_ ($ delta) $ HM.elems deltaSubscribers
  mapM_ ($ (Update, toHashMap handle)) $ HM.elems subscribers

modifyKeySubscribers :: (HM.HashMap Unique (ObservableMessage (Maybe v) -> IO ()) -> HM.HashMap Unique (ObservableMessage (Maybe v) -> IO ())) -> KeyHandle v -> KeyHandle v
modifyKeySubscribers = over _keySubscribers

new :: IO (ObservableHashMap k v)
new = ObservableHashMap <$> newMVar Handle{keyHandles=HM.empty, subscribers=HM.empty, deltaSubscribers=HM.empty}

observeKey :: forall k v. (Eq k, Hashable k) => k -> ObservableHashMap k v -> Observable (Maybe v)
observeKey key ohm@(ObservableHashMap mvar) = Observable FnObservable{getValueFn, subscribeFn}
  where
    getValueFn :: AsyncIO (Maybe v)
    getValueFn = liftIO $ join . preview (_keyHandles . at key . _Just . _value) <$> readMVar mvar
    subscribeFn :: ((ObservableMessage (Maybe v) -> IO ()) -> IO Disposable)
    subscribeFn callback = do
      subscriptionKey <- newUnique
      modifyKeyHandle_ (subscribeFn' subscriptionKey) key ohm
      pure $ synchronousDisposable (unsubscribe subscriptionKey)
      where
        subscribeFn' :: Unique -> KeyHandle v -> IO (KeyHandle v)
        subscribeFn' subKey keyHandle@KeyHandle{value} = do
          callback (Current, value)
          pure $ modifyKeySubscribers (HM.insert subKey callback) keyHandle
        unsubscribe :: Unique -> IO ()
        unsubscribe subKey = modifyKeyHandle_ (pure . modifyKeySubscribers (HM.delete subKey)) key ohm

insert :: forall k v. (Eq k, Hashable k) => k -> v -> ObservableHashMap k v -> IO ()
insert key value = modifyKeyHandleNotifying_ fn key
  where
    fn :: KeyHandle v -> IO (KeyHandle v, Maybe (Delta k v))
    fn keyHandle@KeyHandle{keySubscribers} = do
      mapM_ ($ (Update, Just value)) $ HM.elems keySubscribers
      pure (keyHandle{value=Just value}, Just (Insert key value))

delete :: forall k v. (Eq k, Hashable k) => k -> ObservableHashMap k v -> IO ()
delete key = modifyKeyHandleNotifying_ fn key
  where
    fn :: KeyHandle v -> IO (KeyHandle v, Maybe (Delta k v))
    fn keyHandle@KeyHandle{value=oldValue, keySubscribers} = do
      mapM_ ($ (Update, Nothing)) $ HM.elems keySubscribers
      let delta = if isJust oldValue then Just (Delete key) else Nothing
      pure (keyHandle{value=Nothing}, delta)

lookup :: forall k v. (Eq k, Hashable k) => k -> ObservableHashMap k v -> IO (Maybe v)
lookup key (ObservableHashMap mvar) = do
  Handle{keyHandles} <- readMVar mvar
  pure $ join $ value <$> HM.lookup key keyHandles

lookupDelete :: forall k v. (Eq k, Hashable k) => k -> ObservableHashMap k v -> IO (Maybe v)
lookupDelete key = modifyKeyHandleNotifying fn key
  where
    fn :: KeyHandle v -> IO (KeyHandle v, (Maybe (Delta k v), Maybe v))
    fn keyHandle@KeyHandle{value=oldValue, keySubscribers} = do
      mapM_ ($ (Update, Nothing)) $ HM.elems keySubscribers
      let delta = if isJust oldValue then Just (Delete key) else Nothing
      pure (keyHandle{value=Nothing}, (delta, oldValue))