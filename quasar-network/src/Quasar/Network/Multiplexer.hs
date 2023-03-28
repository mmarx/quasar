module Quasar.Network.Multiplexer (
  -- * Channel type
  RawChannel(quasar),

  -- * Sending and receiving messages
  MessageId,

  -- ** Sending messages
  ChannelMessage(..),
  SentMessageResources(..),
  AbortSend(..),
  channelMessage,
  sendRawChannelMessage,
  sendRawChannelMessageDeferred,
  unsafeQueueRawChannelMessage,
  unsafeQueueRawChannelMessageSimple,
  sendSimpleRawChannelMessage,
  sendSimpleRawChannelMessageDeferred,

  -- ** Receiving messages
  ReceivedMessageResources(..),
  MessageLength,
  RawChannelHandler,
  rawChannelSetHandler,
  binaryHandler,
  simpleBinaryHandler,
  byteStringHandler,
  simpleByteStringHandler,
  rawChannelSetByteStringHandler,
  rawChannelSetSimpleByteStringHandler,
  rawChannelSetBinaryHandler,
  rawChannelSetSimpleBinaryHandler,

  -- ** Exception handling
  MultiplexerException(..),
  MultiplexerDirection(..),
  ConnectionLostReason(..),
  ChannelException(..),
  channelReportProtocolError,
  channelReportException,

  -- * Create or run a multiplexer
  MultiplexerSide(..),
  runMultiplexer,
  newMultiplexer,
) where


import Control.Monad.Catch
import Control.Monad.State (StateT, evalStateT)
import Control.Monad.State qualified as State
import Control.Monad.Trans (lift)
import Control.Monad.Writer.Strict (WriterT, execWriterT, tell)
import Data.Bifunctor (first)
import Data.Binary (Binary, Put)
import Data.Binary qualified as Binary
import Data.Binary.Get (Get, Decoder(..), runGetIncremental, pushChunk)
import Data.Binary.Put qualified as Binary
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.HashMap.Strict qualified as HM
import Quasar
import Quasar.Exceptions
import Quasar.Network.Connection
import Quasar.Prelude
import System.Timeout (timeout)

-- * Types

-- | Designed for long-running processes
type ChannelId = Word64
type MessageId = Word64
type MessageLength = Word64

-- | Amount of created sub-channels
type NewChannelCount = Word32

-- ** Wire format

magicBytes :: BS.ByteString
magicBytes = "qso\0dev\0"

-- | Low level network protocol control message
data MultiplexerMessage
  = ChannelMessageHeader NewChannelCount MessageLength
  | SwitchChannel ChannelId
  | CloseChannel
  | MultiplexerProtocolError String
  | ChannelProtocolError String
  | InternalError String
  deriving stock (Generic, Show)
  deriving anyclass Binary


-- ** Multiplexer

data OutboxMessage
  = OutboxSendMessage ChannelId NewChannelCount BSL.ByteString
  | OutboxCloseChannel ChannelId
  deriving stock Show

data Multiplexer = Multiplexer {
  side :: MultiplexerSide,
  disposer :: Disposer,
  multiplexerException :: Promise MultiplexerException,
  multiplexerResult :: Promise (Maybe MultiplexerException),
  receiveThreadCompleted :: Future (),
  -- Set to true after magic bytes have been received
  receivedHeader :: TVar Bool,
  outbox :: TVar [OutboxMessage],
  outboxGuard :: MVar (),
  channelsVar :: TVar (HM.HashMap ChannelId RawChannel),
  nextReceiveChannelId :: TVar ChannelId,
  nextSendChannelId :: TVar ChannelId
}
instance Disposable Multiplexer where
  getDisposer multiplexer = multiplexer.disposer

-- | 'MultiplexerSideA' describes the initiator of a connection, i.e. the client in most cases.
--
-- Side A will send multiplexer headers before the server sends a response.
--
-- In cases where there is no clear initiator or client/server relation, the side which usually sends the first message
-- should be side A.
data MultiplexerSide = MultiplexerSideA | MultiplexerSideB
  deriving stock (Eq, Show)

data MultiplexerException
  = ConnectionLost ConnectionLostReason
  | InvalidMagicBytes BS.ByteString
  | LocalException MultiplexerDirection SomeException
  | RemoteException String
  | ProtocolException String
  | ReceivedProtocolException String
  | ChannelProtocolException ChannelId String
  | ReceivedChannelProtocolException ChannelId String
  deriving stock Show

instance Exception MultiplexerException where
  displayException (InvalidMagicBytes received) =
    mconcat ["Magic bytes don't match: Expected ", show magicBytes, ", got ", show received]
  displayException (LocalException direction inner) =
    mconcat ["Multiplexer failed due to a local exception (", show direction, "):\n", displayException inner]
  displayException ex = show ex

data MultiplexerDirection = Sending | Receiving
  deriving stock Show

data ConnectionLostReason
  = SendFailed SomeException
  | ReceiveFailed SomeException
  | CloseTimeoutReached -- "Multiplexer reached timeout while closing connection"
  deriving stock Show

instance Exception ConnectionLostReason where
  displayException (SendFailed ex) = displayException ex
  displayException (ReceiveFailed ex) = "Failed to send: " <> displayException ex
  displayException CloseTimeoutReached = "Multiplexer reached timeout while closing connection"

protocolException :: MonadThrow m => String -> m a
protocolException = throwM . ProtocolException

-- ** Channel

data RawChannel = RawChannel {
  multiplexer :: Multiplexer,
  quasar :: Quasar,
  channelId :: ChannelId,
  channelHandler :: TVar (Maybe RawChannelHandler),
  parent :: Maybe RawChannel,
  children :: TVar (HM.HashMap ChannelId RawChannel),
  nextSendMessageId :: TVar MessageId,
  nextReceiveMessageId :: TVar MessageId,
  receivedCloseMessage :: TVar Bool,
  sentCloseMessage :: TVar Bool
}

instance Disposable RawChannel where
  getDisposer channel = getDisposer channel.quasar

newRootChannel :: Multiplexer -> QuasarIO RawChannel
newRootChannel multiplexer = do
  quasar <- askQuasar
  channel <- liftIO do
    channelHandler <- newTVarIO Nothing
    children <- newTVarIO mempty
    nextSendMessageId <- newTVarIO 0
    nextReceiveMessageId <- newTVarIO 0
    receivedCloseMessage <- newTVarIO False
    sentCloseMessage <- newTVarIO False

    pure RawChannel {
      multiplexer,
      quasar,
      channelId = 0,
      channelHandler,
      parent = Nothing,
      children,
      nextSendMessageId,
      nextReceiveMessageId,
      receivedCloseMessage,
      sentCloseMessage
    }

  registerSimpleDisposeTransactionIO_ $ sendChannelCloseMessage channel

  pure channel

newChannel :: RawChannel -> ChannelId -> STMc NoRetry '[ChannelException] RawChannel
newChannel parent@RawChannel{multiplexer, quasar=parentQuasar} channelId =
  handleSTMc @NoRetry @'[ChannelException, FailedToAttachResource] (\FailedToAttachResource -> throwC ChannelNotConnected) do
    -- Channels inherit their parents close state
    parentReceivedCloseMessage <- readTVar parent.receivedCloseMessage
    parentSentCloseMessage <- readTVar parent.sentCloseMessage

    quasar <- newResourceScopeSTM parentQuasar
    channelHandler <- newTVar Nothing
    children <- newTVar mempty
    nextSendMessageId <- newTVar 0
    nextReceiveMessageId <- newTVar 0
    receivedCloseMessage <- newTVar parentReceivedCloseMessage
    sentCloseMessage <- newTVar parentSentCloseMessage

    let channel = RawChannel {
      multiplexer,
      quasar,
      channelId,
      channelHandler,
      parent = Just parent,
      children,
      nextSendMessageId,
      nextReceiveMessageId,
      receivedCloseMessage,
      sentCloseMessage
    }

    -- Attach to parent
    modifyTVar parent.children $ HM.insert channelId channel

    runQuasarSTMc @NoRetry @'[FailedToAttachResource] quasar do
      registerSimpleDisposeTransaction_ $ sendChannelCloseMessage channel

    modifyTVar multiplexer.channelsVar $ HM.insert channelId channel

    pure channel

sendChannelCloseMessage :: RawChannel -> STMc NoRetry '[] ()
sendChannelCloseMessage channel = do
  alreadySent <- readTVar channel.sentCloseMessage
  unless alreadySent do
    modifyTVar channel.multiplexer.outbox (OutboxCloseChannel channel.channelId :)
    -- Mark as closed and propagate close state to children
    markAsClosed channel
    cleanupChannel channel
  where
    markAsClosed :: RawChannel -> STMc NoRetry '[] ()
    markAsClosed markChannel = do
      writeTVar markChannel.sentCloseMessage True
      children <- readTVar markChannel.children
      mapM_ markAsClosed children

setReceivedChannelCloseMessage :: RawChannel -> STMc NoRetry '[] ()
setReceivedChannelCloseMessage channel = do
  writeTVar channel.receivedCloseMessage True
  children <- readTVar channel.children
  mapM_ setReceivedChannelCloseMessage children
  cleanupChannel channel

cleanupChannel :: RawChannel -> STMc NoRetry '[] ()
cleanupChannel channel = do
  whenM (readTVar channel.sentCloseMessage) do
    whenM (readTVar channel.receivedCloseMessage) do
      -- Deregister from multiplexer
      modifyTVar channel.multiplexer.channelsVar $ HM.delete channel.channelId

      -- Deregister from parent
      case channel.parent of
        Just parent -> modifyTVar parent.children $ HM.delete channel.channelId
        Nothing -> pure ()

      -- Children are closed implicitly, so they have to be cleaned up as well
      mapM_ cleanupChannel =<< readTVar channel.children

verifyChannelIsConnected :: RawChannel -> STMc NoRetry '[ChannelException] ()
verifyChannelIsConnected channel = do
  whenM (readTVar channel.sentCloseMessage) $ throwC ChannelNotConnected
  whenM (readTVar channel.receivedCloseMessage) $ throwC ChannelNotConnected

data ChannelException = ChannelNotConnected
  deriving stock Show
  deriving anyclass Exception

-- ** Channel message interface

newtype RawChannelHandler = RawChannelHandler (ReceivedMessageResources -> IO InternalMessageHandler)

runChannelHandler :: RawChannelHandler -> ReceivedMessageResources -> IO InternalMessageHandler
runChannelHandler (RawChannelHandler fn) = fn

newtype InternalMessageHandler = InternalMessageHandler (Maybe BS.ByteString -> IO InternalMessageHandler)

data ChannelMessage a = ChannelMessage {
  payload :: a,
  closeChannel :: Bool,
  createChannels :: NewChannelCount
}

instance Functor ChannelMessage where
  fmap fn ChannelMessage{payload = px, closeChannel, createChannels} =
    ChannelMessage{payload = fn px, closeChannel, createChannels}

channelMessage :: a -> ChannelMessage a
channelMessage payload = ChannelMessage {
  payload,
  closeChannel = False,
  createChannels = 0
}

data SentMessageResources = SentMessageResources {
  messageId :: MessageId,
  createdChannels :: [RawChannel]
  --unixFds :: Undefined
}
data ReceivedMessageResources = ReceivedMessageResources {
  channel :: RawChannel,
  messageLength :: MessageLength,
  messageId :: MessageId,
  createdChannels :: [RawChannel]
  --unixFds :: Undefined
}


-- * Implementation

-- | Starts a new multiplexer on the provided connection and blocks until it is closed.
-- The channel is provided to a setup action and can be closed by calling `dispose`; otherwise the multiplexer will run until the underlying connection is closed.
runMultiplexer :: (MonadQuasar m, MonadIO m) => MultiplexerSide -> (RawChannel -> QuasarIO ()) -> Connection -> m ()
runMultiplexer side channelSetupHook connection = liftQuasarIO $ mask_ do
  (rootChannel, result) <- newMultiplexerInternal side connection
  runQuasarIO rootChannel.quasar $ channelSetupHook rootChannel
  mException <- await result
  mapM_ throwM mException

-- | Starts a new multiplexer on an existing connection (e.g. on a connected TCP socket).
newMultiplexer :: (MonadQuasar m, MonadIO m) => MultiplexerSide -> Connection -> m RawChannel
newMultiplexer side connection = liftQuasarIO $ mask_ do
  exceptionSink <- askExceptionSink
  (rootChannel, result) <- newMultiplexerInternal side connection
  -- TODO review the uninterruptibleMask (currently ensures the exception is delivered - can be improved by properly using the ExceptionSink now)
  async_ $ liftIO $ uninterruptibleMask_ do
    mException <- await result
    mapM_ (atomically . throwToExceptionSink exceptionSink) mException
  pure rootChannel

newMultiplexerInternal :: MultiplexerSide -> Connection -> QuasarIO (RawChannel, Future (Maybe MultiplexerException))
newMultiplexerInternal side connection = disposeOnError do
  -- The multiplexer returned by `askResourceManager` is created by `disposeOnError`, so it can be used as a disposable
  -- without accidentally disposing external resources.
  resourceManager <- askResourceManager

  outbox <- liftIO $ newTVarIO []
  multiplexerException <- newPromiseIO
  multiplexerResult <- newPromiseIO
  outboxGuard <- liftIO $ newMVar ()
  receivedHeader <- liftIO $ newTVarIO False
  nextReceiveChannelId <- liftIO $ newTVarIO $ if side == MultiplexerSideA then 2 else 1
  nextSendChannelId <- liftIO $ newTVarIO $ if side == MultiplexerSideA then 1 else 2

  rootChannel <- mfix \rootChannel -> do
    channelsVar <- liftIO $ newTVarIO $ HM.singleton 0 rootChannel

    multiplexer <- mfix \multiplexer -> do
      sendingExSink <- catchSink (multiplexerExceptionHandler multiplexer Sending) <$> askExceptionSink
      receivingExSink <- catchSink (multiplexerExceptionHandler multiplexer Receiving) <$> askExceptionSink

      receiveTask <- unmanagedAsync receivingExSink $
        receiveThread multiplexer (receiveCheckEOF connection)
      sendTask <- unmanagedAsync sendingExSink $
        sendThread multiplexer connection.send

      let
        sendThreadCompleted = void $ toFuture sendTask
        receiveThreadCompleted = void $ toFuture receiveTask

      registerDisposeActionIO_ do
        -- NOTE The network connection should be closed automatically when the root channel is closed.
        -- This action exists to ensure the network connection is not blocking a resource manager for an unbounded
        -- amount of time while having enough time to perform a graceful close.

        -- Valid reasons to abort the multiplexer threads:
        r <- timeout 2000000 $ await
          -- Send *and* receive thread have terminated on their own, which happens after final messages (i.e. root
          -- channel closed or error messages) have been exchanged.
          (sendThreadCompleted >> receiveThreadCompleted)

        -- Timeout reached
        when (isNothing r) do
          fulfillPromiseIO multiplexerException $ ConnectionLost CloseTimeoutReached

        sf <- disposeEventuallyIO sendTask
        rf <- disposeEventuallyIO receiveTask
        await $ sf <> rf

        connection.close

        fulfillPromiseIO multiplexerResult =<< peekFutureIO (toFuture multiplexerException)

      pure Multiplexer {
        side,
        disposer = getDisposer resourceManager,
        multiplexerException,
        multiplexerResult,
        receiveThreadCompleted,
        outbox,
        outboxGuard,
        receivedHeader,
        channelsVar,
        nextReceiveChannelId,
        nextSendChannelId
      }

    newRootChannel multiplexer

  pure (rootChannel, toFuture multiplexerResult)


multiplexerExceptionHandler :: MonadSTMc NoRetry '[] m => Multiplexer -> MultiplexerDirection -> SomeException -> m ()
multiplexerExceptionHandler multiplexer direction (toMultiplexerException direction -> ex) = liftSTMc @NoRetry @'[] do
  unlessM (tryFulfillPromise multiplexer.multiplexerException ex) do
    queueLogError $ "Multiplexer ignored exception: " <> displayException ex <> "\nMultiplexer already failed with: " <> displayException ex
  disposeEventually_ multiplexer

toMultiplexerException :: MultiplexerDirection -> SomeException -> MultiplexerException
-- Exception is a MultiplexerException already
toMultiplexerException _ (fromException -> Just ex) = ex
-- Otherwise it's a local exception (usually from application code) (may be on a multiplexer thread)
toMultiplexerException direction (fromException -> Just (AsyncException ex)) =
  LocalException direction ex
toMultiplexerException direction ex = LocalException direction ex


sendThread :: Multiplexer -> (BSL.ByteString -> IO ()) -> IO ()
sendThread multiplexer sendFn = do
  case multiplexer.side of
    MultiplexerSideA -> send $ Binary.putByteString magicBytes
    MultiplexerSideB -> do
      -- Block sending until magic bytes have been received
      atomically $ check =<< readTVar multiplexer.receivedHeader
  evalStateT sendLoop 0
  where
    send :: MonadIO m => Put -> m ()
    send chunks = liftIO $ sendFn (Binary.runPut chunks) `catchAll` (throwM . ConnectionLost . SendFailed)

    sendLoop :: StateT ChannelId IO ()
    sendLoop = do
      join $ liftIO $ atomically do
        peekFuture (toFuture multiplexer.multiplexerException) >>= \case
          -- Send exception (if required for that exception type) and then terminate send loop
          Just fatalException -> pure $ sendException fatalException
          Nothing -> do
            messages <- swapTVar multiplexer.outbox []
            case messages of
              -- Exit when the receive thread has stopped and there is no error and no message left to send
              [] -> pure () <$ readFuture multiplexer.receiveThreadCompleted
              _ -> pure do
                bytes <- execWriterT do
                  -- outbox is a list that is used as a queue, so it has to be reversed to preserve the correct order
                  mapM_ formatMessage (reverse messages)
                liftIO $ send bytes
                sendLoop

    sendException :: MultiplexerException -> StateT ChannelId IO ()
    sendException (ConnectionLost _) = pure ()
    sendException (InvalidMagicBytes _) = pure ()
    sendException (LocalException _ ex) = liftIO $ send $ Binary.put $ InternalError $ displayException ex
    sendException (RemoteException _) = pure ()
    sendException (ProtocolException message) = liftIO $ send $ Binary.put $ MultiplexerProtocolError message
    sendException (ReceivedProtocolException _) = pure ()
    sendException (ChannelProtocolException channelId message) = do
      msg <- execWriterT do
        switchToChannel channelId
        tell $ Binary.put $ ChannelProtocolError message
      send msg
    sendException (ReceivedChannelProtocolException _ _) = pure ()

    formatMessage :: OutboxMessage -> WriterT Put (StateT ChannelId IO) ()
    formatMessage (OutboxSendMessage channelId newChannelCount message) = do
      switchToChannel channelId
      tell do
        Binary.put (ChannelMessageHeader newChannelCount messageLength)
        Binary.putLazyByteString message
      where
        messageLength = fromIntegral $ BSL.length message
    formatMessage (OutboxCloseChannel channelId) = do
      switchToChannel channelId
      tell $ Binary.put CloseChannel

    switchToChannel :: ChannelId -> WriterT Put (StateT ChannelId IO) ()
    switchToChannel channelId = do
      currentChannelId <- State.get
      when (channelId /= currentChannelId) do
        tell $ Binary.put $ SwitchChannel channelId
        State.put channelId


-- | Internal state of the `receiveThread` function.
type ReceiveThreadState = Maybe RawChannel

receiveThread :: Multiplexer -> IO BS.ByteString -> IO ()
receiveThread multiplexer readFn = do
  rootChannel <- lookupChannel 0
  chunk <- case multiplexer.side of
    MultiplexerSideA -> readBytes
    MultiplexerSideB -> checkMagicBytes
  evalStateT (multiplexerLoop rootChannel) chunk
  where
    readBytes :: IO BS.ByteString
    readBytes = readFn `catchAll` \ex -> throwM $ ConnectionLost $ ReceiveFailed ex

    -- Reads and verifies magic bytes. Returns bytes left over from the received chunk(s).
    checkMagicBytes :: IO BS.ByteString
    checkMagicBytes = checkMagicBytes' ""
      where
        magicBytesLength = BS.length magicBytes
        checkMagicBytes' :: BS.ByteString -> IO BS.ByteString
        checkMagicBytes' chunk@((< magicBytesLength) . BS.length -> True) = do
          next <- readBytes `catchAll` \_ -> throwM (InvalidMagicBytes chunk)
          checkMagicBytes' $ chunk <> next
        checkMagicBytes' (BS.splitAt magicBytesLength -> (bytes, leftovers)) = do
          when (bytes /= magicBytes) $ throwM $ InvalidMagicBytes bytes
          -- Confirm magic bytes
          atomically $ writeTVar multiplexer.receivedHeader True
          pure leftovers

    multiplexerLoop :: ReceiveThreadState -> StateT BS.ByteString IO ()
    multiplexerLoop prevState = do
      msg <- getMultiplexerMessage
      mNextState <- execReceivedMultiplexerMessage prevState msg
      mapM_ multiplexerLoop mNextState

    lookupChannel :: ChannelId -> IO (Maybe RawChannel)
    lookupChannel channelId = do
      HM.lookup channelId <$> readTVarIO multiplexer.channelsVar

    runGet :: forall a. Get a -> (forall b. String -> IO b) -> StateT BS.ByteString IO a
    runGet get errorHandler = do
      stateStateM $ liftIO . stepDecoder . pushChunk (runGetIncremental get)
      where
        stepDecoder :: Decoder a -> IO (a, BS.ByteString)
        stepDecoder (Fail _ _ errMsg) = errorHandler errMsg
        stepDecoder (Partial feedFn) = stepDecoder . feedFn . Just =<< readBytes
        stepDecoder (Done leftovers _ msg) = pure (msg, leftovers)

    getMultiplexerMessage :: StateT BS.ByteString IO MultiplexerMessage
    getMultiplexerMessage =
      runGet Binary.get \errMsg ->
        protocolException $ "Failed to parse protocol message: " <> errMsg

    execReceivedMultiplexerMessage :: ReceiveThreadState -> MultiplexerMessage -> StateT BS.ByteString IO (Maybe ReceiveThreadState)
    execReceivedMultiplexerMessage Nothing (ChannelMessageHeader _ _) = undefined
    execReceivedMultiplexerMessage state@(Just channel) (ChannelMessageHeader newChannelCount messageLength) = do
      join $ liftIO $ atomicallyC do
        closedByRemote <- readTVar channel.receivedCloseMessage
        sentClose <- readTVar channel.sentCloseMessage
        -- Create channels even if the current channel has been closed, to stay in sync with the remote side
        createdChannelIds <- stateTVar multiplexer.nextReceiveChannelId (createChannelIds newChannelCount)
        createdChannels <- mapM (newChannel channel) createdChannelIds
        pure do
          -- Receiving messages after the remote side closed a channel is a protocol error
          when closedByRemote $ protocolException $
            mconcat ["Received message for invalid channel ", show channel.channelId, " (channel is closed)"]
          if sentClose
            -- Drop received messages when the channel has been closed on the local side
            then dropBytes messageLength
            else receiveChannelMessage channel createdChannels messageLength
          pure $ Just state

    execReceivedMultiplexerMessage _ (SwitchChannel channelId) = liftIO do
      lookupChannel channelId >>= \case
        Nothing -> protocolException $
          mconcat ["Failed to switch to channel ", show channelId, " (invalid id)"]
        Just channel -> do
          receivedClose <- readTVarIO channel.receivedCloseMessage
          when receivedClose $ protocolException $
            mconcat ["Failed to switch to channel ", show channelId, " (channel is closed)"]
          pure (Just (Just channel))

    execReceivedMultiplexerMessage Nothing CloseChannel = undefined
    execReceivedMultiplexerMessage (Just channel) CloseChannel = liftIO do
      atomicallyC do
        setReceivedChannelCloseMessage channel
        sendChannelCloseMessage channel
      disposeEventuallyIO_ channel
      pure if channel.channelId /= 0
        then Just Nothing
        -- Terminate receive thread
        else Nothing

    execReceivedMultiplexerMessage _ (MultiplexerProtocolError msg) = throwM $ RemoteException $
      "Remote closed connection because of a multiplexer protocol error: " <> msg
    execReceivedMultiplexerMessage Nothing (ChannelProtocolError msg) = undefined
    execReceivedMultiplexerMessage (Just channel) (ChannelProtocolError msg) =
      throwM $ ChannelProtocolException channel.channelId msg
    execReceivedMultiplexerMessage _ (InternalError msg) =
      throwM $ RemoteException msg

    receiveChannelMessage :: RawChannel -> [RawChannel] -> MessageLength -> StateT BS.ByteString IO ()
    receiveChannelMessage channel createdChannels messageLength = do
      modifyStateM \chunk -> liftIO do
        messageId <- atomically $ stateTVar channel.nextReceiveMessageId (\x -> (x, x + 1))
        -- NOTE blocks until a channel handler is set
        handler <- atomically $ maybe retry (pure . runChannelHandler) =<< readTVar channel.channelHandler

        messageHandler <- handler ReceivedMessageResources {
          channel,
          createdChannels,
          messageId,
          messageLength
        }
        runHandler messageHandler messageLength chunk
      where
        runHandler :: InternalMessageHandler -> MessageLength -> BS.ByteString -> IO BS.ByteString
        -- Signal to handler, that receiving is completed
        runHandler (InternalMessageHandler fn) 0 leftovers = leftovers <$ fn Nothing
        -- Read more data
        runHandler handler remaining (BS.null -> True) = runHandler handler remaining =<< readBytes
        -- Feed remaining data into handler
        runHandler (InternalMessageHandler fn) remaining chunk
          | chunkLength <= remaining = do
            next <- fn (Just chunk)
            runHandler next (remaining - chunkLength) ""
          | otherwise = do
            let (finalChunk, leftovers) = BS.splitAt (fromIntegral remaining) chunk
            next <- fn (Just finalChunk)
            runHandler next 0 leftovers
          where
            chunkLength = fromIntegral $ BS.length chunk

    dropBytes :: MessageLength -> StateT BS.ByteString IO ()
    dropBytes = modifyStateM . go
      where
        go :: MessageLength -> BS.ByteString -> IO BS.ByteString
        go remaining chunk
          | chunkLength <= remaining = do
            go (remaining - chunkLength) =<< readBytes
          | otherwise = do
            pure $ BS.drop (fromIntegral remaining) chunk
          where
            chunkLength = fromIntegral $ BS.length chunk


data AbortSend = AbortSend
  deriving stock (Eq, Show)
  deriving anyclass Exception


sendRawChannelMessage :: MonadIO m => RawChannel -> ChannelMessage BSL.ByteString -> m SentMessageResources
sendRawChannelMessage channel@RawChannel{multiplexer} message = liftIO do
  -- Locking the 'outboxGuard' guarantees fairness when sending messages concurrently (it also prevents unnecessary
  -- STM retries)
  (res, ()) <- withMVar multiplexer.outboxGuard \_ ->
    atomicallyC $ sendRawChannelMessageInternal blockUntilReadyBehavior channel (const (pure (message, ())))
  pure res

sendRawChannelMessageDeferred :: MonadIO m => RawChannel -> (MessageId -> STMc NoRetry '[AbortSend] (ChannelMessage BSL.ByteString, a)) -> m (SentMessageResources, a)
sendRawChannelMessageDeferred channel@RawChannel{multiplexer} msgHook = liftIO do
  -- Locking the 'outboxGuard' guarantees fairness when sending messages concurrently (it also prevents unnecessary
  -- STM retries)
  withMVar multiplexer.outboxGuard \_ ->
    atomicallyC $ sendRawChannelMessageInternal blockUntilReadyBehavior channel msgHook

-- | Unsafely queue a network message to an unbounded send queue. This function does not block, even if `sendChannelMessage` would block. Queued messages will cause concurrent or following `sendChannelMessage`-calls to block until the queue is flushed.
unsafeQueueRawChannelMessage :: RawChannel -> ChannelMessage BSL.ByteString -> STMc NoRetry '[AbortSend, ChannelException, MultiplexerException] SentMessageResources
unsafeQueueRawChannelMessage channel msg = do
  (res, ()) <- sendRawChannelMessageInternal unboundedQueueBehavior channel (const (pure (msg, ())))
  pure res

unsafeQueueRawChannelMessageSimple :: MonadSTMc NoRetry '[AbortSend, ChannelException, MultiplexerException] m => RawChannel -> BSL.ByteString -> m ()
unsafeQueueRawChannelMessageSimple channel payload = liftSTMc do
  unsafeQueueRawChannelMessage channel (channelMessage payload) >>=
    \case
      -- Pattern match verifies no channels are created due to a bug
      SentMessageResources{createdChannels=[]} -> pure ()
      _ -> unreachableCodePath


blockUntilReadyBehavior :: Bool -> STMc Retry exceptions ()
blockUntilReadyBehavior = check

unboundedQueueBehavior :: Bool -> STMc NoRetry exceptions ()
unboundedQueueBehavior _ = pure ()

sendRawChannelMessageInternal :: (Bool -> STMc canRetry '[AbortSend, ChannelException, MultiplexerException] ()) -> RawChannel -> (MessageId -> STMc NoRetry '[AbortSend] (ChannelMessage BSL.ByteString, a)) -> STMc canRetry '[AbortSend, ChannelException, MultiplexerException] (SentMessageResources, a)
sendRawChannelMessageInternal queueBehavior channel@RawChannel{multiplexer} msgHook = do
  -- NOTE At most one message can be queued per STM transaction, so `sendChannelMessage` cannot be changed to STM

  -- Abort if the multiplexer is finished or currently cleaning up
  mapM_ throwC =<< peekFuture (toFuture multiplexer.multiplexerException)

  -- Abort if the channel is closed
  liftSTMc $ verifyChannelIsConnected channel

  msgs <- readTVar multiplexer.outbox

  -- Block until all previously queued messages have been sent, if requested
  queueBehavior (null msgs)

  messageId <- stateTVar channel.nextSendMessageId (\x -> (x, x + 1))

  (ChannelMessage{payload, closeChannel, createChannels}, returnData) <- liftSTMc (msgHook messageId)

  -- Put the message into the outbox. It will be picked up by the send thread.
  let msg = OutboxSendMessage channel.channelId createChannels payload
  writeTVar multiplexer.outbox (msg:msgs)

  liftSTMc $ when closeChannel do
    sendChannelCloseMessage channel
    disposeEventually_ channel

  createdChannelIds <- stateTVar multiplexer.nextSendChannelId (createChannelIds createChannels)
  createdChannels <- liftSTMc $ mapM (newChannel channel) createdChannelIds

  let res = SentMessageResources {
    messageId,
    createdChannels
  }

  pure (res, returnData)

createChannelIds :: NewChannelCount -> ChannelId -> ([ChannelId], ChannelId)
createChannelIds amount firstId = (channelIds, nextId)
  where
    channelIds = take (fromIntegral amount) [firstId, firstId + 2..]
    nextId = firstId + fromIntegral amount * 2

sendSimpleRawChannelMessage :: MonadIO m => RawChannel -> BSL.ByteString -> m ()
sendSimpleRawChannelMessage channel payload = liftIO do
  -- Pattern match verifies no channels are created due to a bug
  SentMessageResources{createdChannels=[]} <- sendRawChannelMessage channel (channelMessage payload)
  pure ()

sendSimpleRawChannelMessageDeferred :: MonadIO m => RawChannel -> (MessageId -> STMc NoRetry '[AbortSend] (BSL.ByteString, a)) -> m a
sendSimpleRawChannelMessageDeferred channel msgHook = liftIO do
  -- Pattern match verifies no channels are created due to a bug
  (SentMessageResources{createdChannels=[]}, returnData) <- sendRawChannelMessageDeferred channel (first channelMessage <<$>> msgHook)
  pure returnData

channelReportProtocolError :: MonadIO m => RawChannel -> String -> m b
channelReportProtocolError = undefined

channelReportException :: MonadIO m => RawChannel -> SomeException -> m b
channelReportException = undefined


rawChannelSetHandler :: MonadIO m => RawChannel -> RawChannelHandler -> m ()
rawChannelSetHandler channel handler = liftIO $ atomically $ writeTVar channel.channelHandler (Just handler)


simpleByteStringHandler :: (BSL.ByteString -> QuasarIO ()) -> RawChannelHandler
simpleByteStringHandler fn = byteStringHandler \case
  ReceivedMessageResources{createdChannels=[]} -> fn
  resources -> const $ throwM $ ChannelProtocolException resources.channel.channelId "Unexpectedly received new channels"


byteStringHandler :: (ReceivedMessageResources -> BSL.ByteString -> QuasarIO ()) -> RawChannelHandler
byteStringHandler fn = RawChannelHandler handler
  where
    handler :: ReceivedMessageResources -> IO InternalMessageHandler
    handler resources = pure $ InternalMessageHandler $ go []
      where
        go :: [BS.ByteString] -> Maybe BS.ByteString -> IO InternalMessageHandler
        go accum (Just chunk) = pure $ InternalMessageHandler $ go (chunk:accum)
        go accum Nothing =
          InternalMessageHandler (const unreachableCodePathM) <$ do
            -- When the channel/multiplexer is currently closing, running the
            -- callback might no longer be possible.
            handle (\FailedToAttachResource -> pure ()) do
              execForeignQuasarIO resources.channel.quasar do
                fn resources $ BSL.fromChunks (reverse accum)

rawChannelSetByteStringHandler :: MonadIO m => RawChannel -> (ReceivedMessageResources -> BSL.ByteString -> QuasarIO ()) -> m ()
rawChannelSetByteStringHandler channel fn = rawChannelSetHandler channel (byteStringHandler fn)


rawChannelSetSimpleByteStringHandler :: MonadIO m => RawChannel -> (BSL.ByteString -> QuasarIO ()) -> m ()
rawChannelSetSimpleByteStringHandler channel fn = rawChannelSetHandler channel (simpleByteStringHandler fn)


binaryHandler :: forall a. Binary a => (ReceivedMessageResources -> a -> QuasarIO ()) -> RawChannelHandler
binaryHandler fn = RawChannelHandler handler
  where
    handler :: ReceivedMessageResources -> IO InternalMessageHandler
    handler resources = pure $ InternalMessageHandler $ stepDecoder $ runGetIncremental Binary.get
      where
        stepDecoder :: Decoder a -> Maybe BS.ByteString -> IO InternalMessageHandler
        stepDecoder (Fail _ _ errMsg) _ = throwM $ ChannelProtocolException resources.channel.channelId $ "Failed to parse channel message: " <> errMsg
        stepDecoder (Partial feedFn) chunk@(Just _) = pure $ InternalMessageHandler $ stepDecoder (feedFn chunk)
        stepDecoder (Partial _feedFn) Nothing = throwM $ ChannelProtocolException resources.channel.channelId $ "End of message has been reached but decoder expects more data"
        stepDecoder (Done "" _ result) Nothing = InternalMessageHandler (const unreachableCodePathM) <$ runHandler result
        stepDecoder (Done _ bytesRead _msg) _ = throwM $ ChannelProtocolException resources.channel.channelId $
          mconcat ["Decoder failed to consume complete message (", show (fromIntegral resources.messageLength - bytesRead), " bytes left)"]

        runHandler :: a -> IO ()
        runHandler result =
          -- When the channel/multiplexer is currently closing, running the
          -- callback might no longer be possible.
          handle (\FailedToAttachResource -> pure ()) do
            execForeignQuasarIO resources.channel.quasar (fn resources result)


rawChannelSetBinaryHandler :: forall a m. (Binary a, MonadIO m) => RawChannel -> (ReceivedMessageResources -> a -> QuasarIO ()) -> m ()
rawChannelSetBinaryHandler channel fn = rawChannelSetHandler channel (binaryHandler fn)

simpleBinaryHandler :: forall a. Binary a => (a -> QuasarIO ()) -> RawChannelHandler
simpleBinaryHandler fn = binaryHandler \case
  ReceivedMessageResources{createdChannels=[]} -> fn
  resources -> const $ throwM $ ChannelProtocolException resources.channel.channelId "Unexpectedly received new channels"

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
rawChannelSetSimpleBinaryHandler :: forall a m. (Binary a, MonadIO m) => RawChannel -> (a -> QuasarIO ()) -> m ()
rawChannelSetSimpleBinaryHandler channel fn = rawChannelSetHandler channel (simpleBinaryHandler fn)



-- * State utilities

modifyStateM :: Monad m => (s -> m s) -> StateT s m ()
modifyStateM fn = State.put =<< lift . fn =<< State.get

stateStateM :: Monad m => (s -> m (a, s)) -> StateT s m a
stateStateM fn = do
  old <- State.get
  (result, new) <- lift $ fn old
  result <$ State.put new
