module Quasar.Network.Runtime (
  -- * Client
  Client,

  withClientTCP,
  newClientTCP,
  withClientUnix,
  newClientUnix,
  withClient,
  newClient,

  -- * Server
  Server,
  Listener(..),
  runServer,
  addListener,
  addListener_,
  withLocalClient,
  newLocalClient,
  listenTCP,
  listenUnix,
  listenOnBoundSocket,

  -- * Stream
  Stream,
  streamSend,
  streamSetHandler,
  streamClose,

  -- * Test implementation
  withStandaloneClient,

  -- * Internal runtime interface
  RpcProtocol(..),
  HasProtocolImpl(..),
  clientSend,
  clientRequest,
  clientReportProtocolError,
  newStream,
) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad.Catch
import Data.Binary (Binary, encode, decodeOrFail)
import Data.ByteString.Lazy qualified as BSL
import Data.HashMap.Strict qualified as HM
import Network.Socket qualified as Socket
import Quasar.Async
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Prelude
import Quasar.ResourceManager
import System.Posix.Files (getFileStatus, isSocket, fileExist, removeLink)


class (Binary (ProtocolRequest p), Binary (ProtocolResponse p)) => RpcProtocol p where
  -- "Up"
  type ProtocolRequest p
  -- "Down"
  type ProtocolResponse p

type ProtocolResponseWrapper p = (MessageId, ProtocolResponse p)

class RpcProtocol p => HasProtocolImpl p where
  type ProtocolImpl p
  handleRequest :: ProtocolImpl p -> Channel -> ProtocolRequest p -> [Channel] -> ResourceManagerIO (Maybe (Awaitable (ProtocolResponse p)))


data Client p = Client {
  channel :: Channel,
  callbacksVar :: TVar (HM.HashMap MessageId (ProtocolResponse p -> IO ()))
}

instance IsDisposable (Client p) where
  toDisposable client = toDisposable client.channel

clientSend :: forall p m. (MonadIO m, RpcProtocol p) => Client p -> MessageConfiguration -> ProtocolRequest p -> m SentMessageResources
clientSend client config req = liftIO $ channelSend_ client.channel config (encode req)

clientRequest :: forall p m a. (MonadIO m, RpcProtocol p) => Client p -> (ProtocolResponse p -> Maybe a) -> MessageConfiguration -> ProtocolRequest p -> m (Awaitable a, SentMessageResources)
clientRequest client checkResponse config req = do
  resultAsync <- newAsyncVar
  sentMessageResources <- liftIO $ channelSend client.channel config (encode req) \msgId ->
    modifyTVar client.callbacksVar $ HM.insert msgId (requestCompletedCallback resultAsync msgId)
  pure (toAwaitable resultAsync, sentMessageResources)
  where
    requestCompletedCallback :: AsyncVar a -> MessageId -> ProtocolResponse p -> IO ()
    requestCompletedCallback resultAsync msgId response = do
      -- Remove callback
      atomically $ modifyTVar client.callbacksVar $ HM.delete msgId

      case checkResponse response of
        Nothing -> clientReportProtocolError client "Invalid response"
        Just result -> putAsyncVar_ resultAsync result

-- TODO use new direct decoder api instead
clientHandleChannelMessage :: forall p. (RpcProtocol p) => Client p -> ReceivedMessageResources -> ProtocolResponseWrapper p -> ResourceManagerIO ()
clientHandleChannelMessage client resources resp = liftIO $ clientHandleResponse resp
  where
    clientHandleResponse :: ProtocolResponseWrapper p -> IO ()
    clientHandleResponse (requestId, resp) = do
      unless (null resources.createdChannels) (channelReportProtocolError client.channel "Received unexpected new channel during a rpc response")
      join $ atomically $ stateTVar client.callbacksVar $ \oldCallbacks -> do
        let (callbacks, mCallback) = lookupDelete requestId oldCallbacks
        case mCallback of
          Just callback -> (callback resp, callbacks)
          Nothing -> (channelReportProtocolError client.channel ("Received response with invalid request id " <> show requestId), callbacks)

clientReportProtocolError :: Client p -> String -> IO a
clientReportProtocolError client = channelReportProtocolError client.channel


serverHandleChannelMessage :: forall p. (HasProtocolImpl p) => ProtocolImpl p -> Channel -> ReceivedMessageResources -> ProtocolRequest p -> ResourceManagerIO ()
serverHandleChannelMessage protocolImpl channel resources req = liftIO $ serverHandleChannelRequest resources.createdChannels req
  where
    serverHandleChannelRequest :: [Channel] -> ProtocolRequest p -> IO ()
    serverHandleChannelRequest channels req = do
      -- TODO runUnlimitedAsync should be replaced with a per-connection limited async context
      onResourceManager channel do
        handleRequest @p protocolImpl channel req channels >>= \case
          Nothing -> pure ()
          Just task -> do
            response <- await task
            liftIO $ serverSendResponse response
    serverSendResponse :: ProtocolResponse p -> IO ()
    serverSendResponse response = channelSendSimple channel (encode wrappedResponse)
      where
        wrappedResponse :: ProtocolResponseWrapper p
        wrappedResponse = (resources.messageId, response)


newtype Stream up down = Stream Channel
  deriving newtype (IsDisposable, IsResourceManager)

newStream :: MonadIO m => Channel -> m (Stream up down)
newStream = liftIO . pure . Stream

streamSend :: (Binary up, MonadIO m) => Stream up down -> up -> m ()
streamSend (Stream channel) value = liftIO $ channelSendSimple channel (encode value)

streamSetHandler :: (Binary down, MonadIO m) => Stream up down -> (down -> ResourceManagerIO ()) -> m ()
streamSetHandler (Stream channel) handler = liftIO $ channelSetSimpleBinaryHandler channel handler

-- | Alias for `dispose`.
streamClose :: MonadIO m => Stream up down -> m ()
streamClose = dispose
{-# DEPRECATED streamClose "Use `dispose` instead." #-}

-- ** Running client and server

withClientTCP :: (RpcProtocol p, MonadResourceManager m) => Socket.HostName -> Socket.ServiceName -> (Client p -> m a) -> m a
withClientTCP host port = withClientBracket (newClientTCP host port)

newClientTCP :: (RpcProtocol p, MonadResourceManager m) => Socket.HostName -> Socket.ServiceName -> m (Client p)
newClientTCP host port = newClient =<< connectTCP host port


withClientUnix :: (RpcProtocol p, MonadResourceManager m) => FilePath -> (Client p -> m a) -> m a
withClientUnix socketPath = withClientBracket (newClientUnix socketPath)

newClientUnix :: (MonadResourceManager m, RpcProtocol p) => FilePath -> m (Client p)
newClientUnix socketPath =
  bracketOnError
    do liftIO $ Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
    do liftIO . Socket.close
    \sock -> do
      liftIO do
        Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
        Socket.connect sock $ Socket.SockAddrUnix socketPath
      newClient sock


withClient :: forall p a m b. (IsConnection a, RpcProtocol p, MonadResourceManager m) => a -> (Client p -> m b) -> m b
withClient connection = withClientBracket (newClient connection)

newClient :: forall p a m. (IsConnection a, RpcProtocol p, MonadResourceManager m) => a -> m (Client p)
newClient connection = newChannelClient =<< newMultiplexer MultiplexerSideA (toSocketConnection connection)

withClientBracket :: (MonadResourceManager m) => m (Client p) -> (Client p -> m a) -> m a
withClientBracket createClient = bracket createClient dispose


newChannelClient :: MonadIO m => RpcProtocol p => Channel -> m (Client p)
newChannelClient channel = do
  callbacksVar <- liftIO $ newTVarIO mempty
  let client = Client {
    channel,
    callbacksVar
  }
  channelSetBinaryHandler channel (clientHandleChannelMessage client)
  pure client

data Listener =
  TcpPort (Maybe Socket.HostName) Socket.ServiceName |
  UnixSocket FilePath |
  ListenSocket Socket.Socket

data Server p = Server {
  resourceManager :: ResourceManager,
  protocolImpl :: ProtocolImpl p
}

instance IsResourceManager (Server p) where
  toResourceManager server = server.resourceManager

instance IsDisposable (Server p) where
  toDisposable = toDisposable . toResourceManager


newServer :: forall p m. (HasProtocolImpl p, MonadResourceManager m) => ProtocolImpl p -> [Listener] -> m (Server p)
newServer protocolImpl listeners = do
  resourceManager <- newResourceManager
  let server = Server { resourceManager, protocolImpl }
  mapM_ (addListener_ server) listeners
  pure server

addListener :: (HasProtocolImpl p, MonadIO m) => Server p -> Listener -> m Disposable
addListener server listener =
  onResourceManager server $
    captureDisposable_ $
      async_ $ runListener listener
  where
    runListener :: MonadResourceManager f => Listener -> f a
    runListener (TcpPort mhost port) = runTCPListener server mhost port
    runListener (UnixSocket path) = runUnixSocketListener server path
    runListener (ListenSocket socket) = runListenerOnBoundSocket server socket

addListener_ :: (HasProtocolImpl p, MonadIO m) => Server p -> Listener -> m ()
addListener_ server listener = void $ addListener server listener

runServer :: forall p m. (HasProtocolImpl p, MonadResourceManager m) => ProtocolImpl p -> [Listener] -> m ()
runServer _ [] = throwM $ userError "Tried to start a server without any listeners attached"
runServer protocolImpl listener = do
  server <- newServer @p protocolImpl listener
  await $ isDisposed server

listenTCP :: forall p m. (HasProtocolImpl p, MonadResourceManager m) => ProtocolImpl p -> Maybe Socket.HostName -> Socket.ServiceName -> m ()
listenTCP impl mhost port = runServer @p impl [TcpPort mhost port]

runTCPListener :: forall p a m. (HasProtocolImpl p, MonadResourceManager m) => Server p -> Maybe Socket.HostName -> Socket.ServiceName -> m a
runTCPListener server mhost port = do
  addr <- liftIO resolve
  bracket (liftIO (open addr)) (liftIO . Socket.close) (runListenerOnBoundSocket server)
  where
    resolve :: IO Socket.AddrInfo
    resolve = do
      let hints = Socket.defaultHints {Socket.addrFlags=[Socket.AI_PASSIVE], Socket.addrSocketType=Socket.Stream}
      (addr:_) <- Socket.getAddrInfo (Just hints) mhost (Just port)
      pure addr
    open :: Socket.AddrInfo -> IO Socket.Socket
    open addr = bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
      Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
      Socket.bind sock (Socket.addrAddress addr)
      pure sock

listenUnix :: forall p m. (HasProtocolImpl p, MonadResourceManager m) => ProtocolImpl p -> FilePath -> m ()
listenUnix impl path = runServer @p impl [UnixSocket path]

runUnixSocketListener :: forall p a m. (HasProtocolImpl p, MonadResourceManager m) => Server p -> FilePath -> m a
runUnixSocketListener server socketPath = do
  bracket create (liftIO . Socket.close) (runListenerOnBoundSocket server)
  where
    create :: m Socket.Socket
    create = liftIO do
      fileExistsAtPath <- fileExist socketPath
      when fileExistsAtPath $ do
        fileStatus <- getFileStatus socketPath
        if isSocket fileStatus
          then removeLink socketPath
          else fail "Cannot bind socket: Socket path is not empty"

      bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
        Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
        Socket.bind sock (Socket.SockAddrUnix socketPath)
        pure sock

-- | Listen and accept connections on an already bound socket.
listenOnBoundSocket :: forall p m. (HasProtocolImpl p, MonadResourceManager m) => ProtocolImpl p -> Socket.Socket -> m ()
listenOnBoundSocket protocolImpl socket = runServer @p protocolImpl [ListenSocket socket]

runListenerOnBoundSocket :: forall p a m. (HasProtocolImpl p, MonadResourceManager m) => Server p -> Socket.Socket -> m a
runListenerOnBoundSocket server sock = do
  liftIO $ Socket.listen sock 1024
  forever $ mask_ $ do
    (conn, _sockAddr) <- liftIO $ Socket.accept sock
    connectToServer server conn

connectToServer :: forall p a m. (HasProtocolImpl p, IsConnection a, MonadResourceManager m) => Server p -> a -> m ()
connectToServer server conn =
  onResourceManager server do
    asyncWithHandler_ (\ex -> traceIO ("Client connection failed:\n" <> (displayException ex))) do
      withRootResourceManager do
        runMultiplexer MultiplexerSideB registerChannelServerHandler $ conn
  where
    connection :: Connection
    connection = toSocketConnection conn

    registerChannelServerHandler :: Channel -> ResourceManagerIO ()
    registerChannelServerHandler channel = liftIO do
      channelSetBinaryHandler channel (serverHandleChannelMessage @p server.protocolImpl channel)


withLocalClient :: forall p a m. (HasProtocolImpl p, MonadResourceManager m) => Server p -> (Client p -> m a) -> m a
withLocalClient server action =
  withScopedResourceManager do
    client <- newLocalClient server
    action client

newLocalClient :: forall p m. (HasProtocolImpl p, MonadResourceManager m) => Server p -> m (Client p)
newLocalClient server = mask_ do
  (clientSocket, serverSocket) <- newConnectionPair
  connectToServer server serverSocket
  newClient @p clientSocket

-- ** Test implementation

withStandaloneClient :: forall p a m. (HasProtocolImpl p, MonadResourceManager m) => ProtocolImpl p -> (Client p -> m a) -> m a
withStandaloneClient impl runClientHook = do
  server <- newServer impl []
  withLocalClient server runClientHook
