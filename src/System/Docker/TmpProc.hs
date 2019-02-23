{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module System.Docker.TmpProc
  ( -- * data types
    TmpProc(..)
  , Owner(..)
  , OwnerHandle
  , UnknownProc

    -- * type aliases
  , Port
  , ProcName
  , ProcURI
  , DockerPid
  , DockerIpAddress

    -- * functions
  , hasDocker
  , withTmpProcOwner
  , withTmpProcs
  , setup
  , setupProcs
  , cleanup
  , doNothing
  , reset
  , resetIO
  , procURI
  )
where

import           Control.Concurrent    (newEmptyMVar, putMVar, takeMVar,
                                        threadDelay)
import           Control.Exception     (Exception, IOException, bracket,
                                        onException, throwIO)
import           Control.Monad         (foldM, forM_, void)
import qualified Data.ByteString.Char8 as C8
import           Data.List             (dropWhileEnd)
import           Data.Text             (Text)
import qualified Data.Text             as Text
import           System.Exit           (ExitCode (..))
import           System.Process        (StdStream (..), proc, readProcess,
                                        std_err, std_out, waitForProcess,
                                        withCreateProcess)
import           UnliftIO              (async, cancel, catch, liftIO,
                                        waitEither)


-- | 'TmpProc' defines functions used for starting and coordinating support
-- processes running on Docker. It's intended to simplify their use as resources
-- when writing tests.
data TmpProc = TmpProc
  { -- | The docker image to run.
    procImageName :: Text

    -- | Additional arguments to the docker run command.
  , procRunArgs   :: [Text]

    -- | Determines the connection string used to access the process.
  , procMkUri     :: DockerIpAddress -> ProcURI

    -- | Resets the process state.
  , procReset     :: ProcURI -> IO ()

    -- | Determines if the process has been successfully started.
  , procPing      :: ProcURI -> IO ()
  }


-- | Permits controlled usage of a 'TmpProc'.
data TmpProcHandle = TmpProcHandle
  { -- | The process-specific uri used by clients of the tmp process for
    -- accessing it directly if needed. For testing, @handleCleanup@ and
    -- @handleReset@ should cover the more general use cases.
    handleURI   :: ProcURI

    -- | An action that will cleanup specific data owned by the process. It is
    -- intended to by multiple test cases. It's behaviour is determined by
    -- @procReset@.
  , handleReset :: IO ()
  }


-- | A process accessed on a given port that accesses some 'TmpProc's through
-- their 'ProcURI's.
data Owner a = Owner
  { -- | Starts some @TmpProcs@ under followed by a server, followed by a
    -- 'ready' action.
    ownerMain    :: OwnerHandle -> Port -> IO () -> IO ()

    -- | Determines if @ownerMain@ being started successfully.
  , ownerStarted :: Port -> IO (Either a ())
  }


-- | Provides control over an 'Owner' and its @TmpProcs@.
data OwnerHandle = OwnerHandle
  { -- | Stops the owning process, and any @TmpProc@ it is running. In tests,
    -- this should be invoked to cleanup up.
    ownerCleanup :: IO ()

    -- | The handles owned by the owner. They are currently keyed by the image
    -- name.
  , ownerHandles :: [(Text, TmpProcHandle)]
  }


-- | TCP port number
type Port = Int


-- | Connection string used to access the service once its running.
type ProcURI = C8.ByteString


-- | A process id of a process running on Docker.
type DockerPid = String


-- | The ip address of the docker process.
type DockerIpAddress = String


-- | The name used to refer to a 'TmpProc'.
--
-- Currently this is the docker image name of the temporary process.
type ProcName = Text


-- | Exception used when an unknown 'ProcName' is used.
data UnknownProc = Unknown ProcName
  deriving (Eq, Show)

instance Exception UnknownProc


-- | Determines the 'ProcURI' for a given 'ProcName'.
procURI :: ProcName -> OwnerHandle -> Either UnknownProc ProcURI
procURI name (OwnerHandle { ownerHandles }) =
  let
    theHandle = lookup name ownerHandles
    throwError = Left $ Unknown name
  in
    maybe throwError (Right . handleURI) theHandle


-- | Runs the configured reset action for named 'TmpProc'.
--
-- Raises 'UnknownProc' if the 'ProcName' is not known.
reset :: ProcName -> OwnerHandle -> IO ()
reset name (OwnerHandle { ownerHandles }) =
  let
    theHandle = lookup name ownerHandles
    throwError = throwIO $ Unknown name
  in
    maybe throwError handleReset theHandle



-- | Determines if the docker daemon is accessible.
hasDocker :: IO Bool
hasDocker = do
  let rawSystemNoStdout cmd args = withCreateProcess
        (proc cmd args) { std_out = CreatePipe , std_err = CreatePipe }
        (\_ _ _ -> waitForProcess)
        `catch`
        (\(_ :: IOError) -> return (ExitFailure 127))
      succeeds ExitSuccess = True
      succeeds _           = False

  succeeds <$> rawSystemNoStdout "docker" ["ps"]


-- | Combinator for running 'reset' with an 'OwnerHandle' from the @IO@ monad.
resetIO :: ProcName -> IO OwnerHandle -> IO ()
resetIO name x = x >>= reset name


-- | Runs an action that uses an 'Owner' that uses some 'TmpProc's as
-- resources and cleans it up afterwards.
withTmpProcOwner :: Owner a -> [TmpProc] -> Port -> (OwnerHandle -> IO()) -> IO ()
withTmpProcOwner owner procs port action =
  bracket
  (setup owner procs port)
  cleanup
  action


-- | Shuts down an 'Owner' and any 'TmpProc' services that it is using.
cleanup :: OwnerHandle -> IO ()
cleanup = ownerCleanup


-- | Used for @procReset@ and @procPing@ when no action is needed.
doNothing :: ProcURI -> IO ()
doNothing _ = pure ()


-- | Starts an 'Owner' process after ensuring that the @TmpProcs@ it depends on
-- are started.
--
-- If any @TmpProc@ fails to start, the remaining are not started, and the ones
-- that were successfully started earlier are stopped.
--
-- If the owner is never becomes healthy, all its @TmpProc@ are stopped.
setup
  :: Owner a
  -> [TmpProc]
  -> Port
  -> IO OwnerHandle
setup owner procs port = liftIO $ do
  let Owner { ownerMain, ownerStarted } = owner
  (pids, ownerHandles) <- setupResources procs
  signal <- newEmptyMVar
  let res = OwnerHandle { ownerHandles , ownerCleanup = pure () }
      cleanupNow = cleanupPids pids
  aServer <- async (ownerMain res port (putMVar signal res))
  aConfirm <- async (takeMVar signal)
  waitEither aServer aConfirm >>= \case
    Left _ -> do
      cleanupNow
      error "setup: server thread stopped unexpectedly"
    Right _ -> do
      checkHealth maxHealthPings $ ownerStarted port `onException` cleanupNow
      pure $ res { ownerCleanup = cleanupNow >> cancel aServer }


-- | Starts some @TmpProcs@.
--
-- If any @TmpProc@ fails to start, the remaining are not started, and the ones
-- that were successfully started earlier are stopped.
setupProcs :: [TmpProc] -> IO OwnerHandle
setupProcs procs = liftIO $ do
  (pids, ownerHandles) <- setupResources procs
  pure $ OwnerHandle { ownerHandles , ownerCleanup = cleanupPids pids}


-- | Runs an action that uses some 'TmpProc's as resources and cleans them
-- afterwards.
withTmpProcs :: [TmpProc] -> (OwnerHandle -> IO a) -> IO a
withTmpProcs procs action =
  bracket
  (setupProcs procs)
  cleanup
  action


setupResources :: [TmpProc] -> IO ([DockerPid], [(ProcName, TmpProcHandle)])
setupResources procs = do
  xs <- foldM setupResource' [] procs
  let pids = map (\(pid, _ , _) -> pid) xs
      handleAssoc = map (\(_, n, h) -> (n, h)) xs
  pure $ (pids, handleAssoc)


type TmpProcResult = (DockerPid, ProcName, TmpProcHandle)


setupResource' :: [TmpProcResult] -> TmpProc -> IO [TmpProcResult]
setupResource' acc tp = do
  let handler = cleanupPids $ map (\(pid, _ , _) -> pid) acc
      addResource = setupResource tp >>= (pure . flip (:) acc)
  addResource `onException` handler


setupResource :: TmpProc -> IO TmpProcResult
setupResource tp@(TmpProc { procReset, procImageName, procRunArgs, procMkUri }) = do
  let fullRunArgs = [ "run" , "-d" ] <> procRunArgs <> [ procImageName ]
  pid <- trim <$> readProcess "docker" (map Text.unpack fullRunArgs) ""
  handleURI <- (procMkUri . trim) <$> readProcess "docker"
    [ "inspect"
    , pid
    , "--format"
    , "'{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'"
    ] ""
  pingResource tp handleURI
  return (pid, procImageName, TmpProcHandle
           { handleURI
           , handleReset = procReset handleURI
           })
  where
    isGarbage = flip elem ['\'', '\n']
    trim = dropWhileEnd isGarbage . dropWhile isGarbage


cleanupPids :: [DockerPid] -> IO ()
cleanupPids pids = forM_  pids $ \pid -> do
  void $ readProcess "docker" [ "stop", pid ] ""
  void $ readProcess "docker" [ "rm", pid ] ""


pingResource
  :: TmpProc
  -> ProcURI
  -> IO ()
pingResource (TmpProc { procPing }) u =
  let
    go 0 = error
      $ "resource setup: failed to connect to " ++ C8.unpack u
    go n =
      procPing u `catch` (\(_ :: IOException) -> do
                             threadDelay pingPeriod
                             go (n - 1) )
  in
    go maxHealthPings


checkHealth :: Int -> IO (Either a b) -> IO ()
checkHealth tries h = go tries
  where
    go 0 = error "healthy: server isn't healthy"
    go n = h >>= \case
      Left  _ -> threadDelay pingPeriod >> go (n - 1)
      Right _ -> pure ()


-- | Number of times to retry a service ping.
maxHealthPings :: Int
maxHealthPings = 10


-- | Gap between service pings in milliseconds.
pingPeriod :: Int
pingPeriod = 1000000


-- Type-level proposal
--
--
-- What's the goal? Remove the need for UnknownProc exception by enhancing the types of OwnerHandle.
--
-- We probably want to use some form of HList, with tags or symbols indicating
-- the different types of TmpProc.
--
-- There should be various typefamilies, but essentially, the list of TmpProc should all distint tags
-- The tag should be used instead of Text to access the ProcURI and invoke reset
--
-- There is a typefamily and function that prevents us from adding using the same tag in a TmpProc twice.
-- already present to the list TmpProcs
-- a list of TmpProcHandle, with a type that is a list tags matching the tags of the TmpProc that created them

-- a function takes a tags and a list of TmpProcHandle and executes reset for a tag that is included in the list of TmpProcHandle
-- a function that takes a list of TmpProcHandle, and returns the ProcURI (without tag) for the given tag.
-- a function that takes a list of TmpProcs and generates the list of TmpProcHandle
--
-- Ready or not
--
-- Can we force the 'ready' action to be run using types ?
-- the main reason for it is that there is hook in Wai that takes a ready.
-- It'd be nice if we made it so that only services that need a ready get a ready.
-- How can we signal that a service will take a 'ready' action ?
