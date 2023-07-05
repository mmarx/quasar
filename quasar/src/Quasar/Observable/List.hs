{-# OPTIONS_GHC -Wno-orphans #-}

module Quasar.Observable.List (
  ObservableList(..),
  ToObservableList,
  toObservableList,
  ObservableListDelta(..),
  ObservableListOperation(..),
) where

import Data.Binary (Binary)
import Data.Sequence (Seq(Empty, (:<|), (:|>)))
import Data.Sequence qualified as Seq
import Quasar.Observable.Core
import Quasar.Prelude


data ObservableListDelta v
  = ObservableListUpdate (Seq (ObservableListOperation v))
  | ObservableListReplace (Seq v)
  deriving Generic

instance Binary v => Binary (ObservableListDelta v)

data ObservableListOperation v
  deriving Generic

instance Binary v => Binary (ObservableListOperation v)

instance ObservableContainer Seq v where
  type ContainerConstraint canLoad exceptions Seq v a = IsObservableList canLoad exceptions v a
  type Delta Seq = ObservableListDelta
  type EvaluatedDelta Seq v = (ObservableListDelta v, Seq v)
  type Key Seq v = Int
  type DeltaContext Seq v = Word32
  applyDelta _delta _state = undefined
  mergeDelta _old _new = undefined
  updateDeltaContext = undefined
  toInitialDelta = undefined
  toInitialDeltaContext = undefined
  initializeFromDelta = undefined
  toDelta = fst
  toEvaluatedDelta = (,)
  toEvaluatedContent = snd

instance ContainerCount Seq where
  containerCount# x = fromIntegral (length x)
  containerIsEmpty# x = null x


type ToObservableList canLoad exceptions v a = ToObservableT canLoad exceptions Seq v a

toObservableList :: ToObservableList canLoad exceptions v a => a -> ObservableList canLoad exceptions v
toObservableList x = ObservableList (toObservableCore x)

newtype ObservableList canLoad exceptions v
  = ObservableList (ObservableT canLoad exceptions Seq v)

instance ToObservableT canLoad exceptions Seq v (ObservableList canLoad exceptions v) where
  toObservableCore (ObservableList x) = x

instance IsObservableCore canLoad exceptions Seq v (ObservableList canLoad exceptions v) where
  readObservable# (ObservableList x) = readObservable# x
  attachObserver# (ObservableList x) = attachObserver# x
  attachEvaluatedObserver# (ObservableList x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableList x) = isCachedObservable# x

instance IsObservableList canLoad exceptions v (ObservableList canLoad exceptions v) where
  --member# (ObservableList (ObservableT x)) = member# x
  --listLookupValue# (ObservableList x) = listLookupValue# x


class IsObservableCore canLoad exceptions Seq v a => IsObservableList canLoad exceptions v a where
  member# :: Ord v => a -> v -> Observable canLoad exceptions Bool
  member# = undefined

  listLookupValue# :: Ord v => a -> Selector k -> Observable canLoad exceptions (Maybe v)
  listLookupValue# x selector = undefined

  query# :: a -> ObservableList canLoad exceptions (Bounds k) -> ObservableList canLoad exceptions v
  query# = undefined


instance IsObservableList canLoad exceptions v (ObservableState canLoad (ObservableResult exceptions Seq) v) where
