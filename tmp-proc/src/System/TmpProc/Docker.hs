{-# LANGUAGE AllowAmbiguousTypes    #-}
{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE NamedFieldPuns         #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE PolyKinds              #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE UndecidableInstances   #-}

{-|
Copyright   : (c) 2020-2021 Tim Emiola
SPDX-License-Identifier: BSD3
Maintainer  : Tim Emiola <adetokunbo@users.noreply.github.com >

Implements core data types and combinators for launching temporary processes as
docker images.

-}
module System.TmpProc.Docker
  (
    -- * type aliases
    HostIpAddress
  , SvcURI

    -- * @'Proc'@ and related functions
  , Proc(..)
  , startup
  , uriOf'
  , runArgs'
  , nameOf

    -- * @'Connectable'@ and related types and functions
  , Connectable(..)
  , connected
  , withTmpConn
  , withNamedConn

    -- * @'ProcHandle'@ and functions for using HLists of @'ProcHandle's@
  , ProcHandle(..)
  , imageTexts
  , startupAll
  , terminateAll
  , withTmpProcs
  , ixReset
  , ixPing
  , ixUriOf
  , named

    -- * type families and constraints
  , Proc2Handle
  , AreProcs
  , SomeProcs(..)
  , HasNamedHandle

    -- * Docker-related functions
  , hasDocker

    -- * module re-exports
  , module System.TmpProc.TypeLevel
  )
where

import           Control.Concurrent       (threadDelay)
import           Control.Exception        (IOException, bracket, catch,
                                           onException, throw)
import           Control.Monad            (void)
import qualified Data.ByteString.Char8    as C8
import           Data.List                (dropWhileEnd)
import           Data.Proxy               (Proxy (..))
import           Data.Text                (Text)
import qualified Data.Text                as Text
import qualified Data.Text.IO             as Text
import           GHC.TypeLits             (KnownSymbol, Symbol, symbolVal)
import           Numeric.Natural          (Natural)
import           System.Exit              (ExitCode (..))
import           System.IO                (stderr)
import           System.Process           (StdStream (..), proc, readProcess,
                                           std_err, std_out, waitForProcess,
                                           withCreateProcess)

import           System.TmpProc.TypeLevel (IsSubsetOf, SubsetOf, hSubset)
import           System.TmpProc.TypeLevel (HList (..), IsAbsent,
                                           KV (..),
                                           MemberGadt, selectG,
                                           selectTF)

{-| Determines if the docker daemon is accessible. -}
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


{-| Set up some @'Proc's@, run an action that uses them, then terminate them. -}
withTmpProcs
  :: AreProcs as
  => HList as
  -> (HList (Proc2Handle as) -> IO b)
  -> IO b
withTmpProcs procs = bracket (startupAll procs) terminateAll


{-| Provides access to a 'Proc' that has been started. -}
data ProcHandle a = ProcHandle
  { hProc :: !a
  , hPid  :: !String
  , hUri  :: !SvcURI
  , hAddr :: !HostIpAddress
  }


{-| Start up processes for each 'Proc' type. -}
startupAll :: AreProcs as => HList as -> IO (HList (Proc2Handle as))
startupAll = go procProof
  where
    go :: SomeProcs as -> HList as -> IO (HList (Proc2Handle as))
    go SomeProcsNil HNil = pure HNil
    go (SomeProcsCons cons) (x `HCons` y) = do
      h <- startup x
      others <- go cons y `onException` terminate h
      pure $ h `HCons` others


{-| Terminate all processes owned by some @'ProcHandle's@. -}
terminateAll :: AreProcs as => HList (Proc2Handle as) -> IO ()
terminateAll = go $ p2h procProof
  where
    go :: SomeHandles as -> HList as -> IO ()
    go SomeHandlesNil HNil = pure ()
    go (SomeHandlesCons cons) (x `HCons` y) = do
      terminate x
      go cons y


{-| Terminate the process owned by a @'ProcHandle's@. -}
terminate :: ProcHandle a -> IO ()
terminate handle = do
  let pid = hPid handle
  void $ readProcess "docker" [ "stop", pid ] ""
  void $ readProcess "docker" [ "rm", pid ] ""


imageTexts :: AreProcs as => HList as -> [Text]
imageTexts = go procProof
  where
    go :: SomeProcs as -> HList as -> [Text]
    go SomeProcsNil          HNil          = []
    go (SomeProcsCons cons)  (x `HCons` y) = imageText x : (go cons y)


{-| Specifies how to a get a connection to a 'Proc'. -}
class Proc a => Connectable a where
  {-| The connection type. -}
  type Conn a = (conn :: *) | conn -> a

  {-| Get a connection to the Proc via its 'ProcHandle', -}
  openConn :: ProcHandle a -> IO (Conn a)

  {-| Close a connection to a 'Proc', -}
  closeConn :: Conn a -> IO ()
  closeConn = const $ pure ()


{-| Specifies how to launch a temporary process using Docker. -}
class (KnownSymbol (Image a), KnownSymbol (Name a)) => Proc a where
  {-| The image name of the docker image. -}
  type Image a :: Symbol

  {-| A label to use when referencing the process created from this image. -}
  type Name a = (labelName :: Symbol) | labelName -> a

  {-| Additional arguments for launching the temporary process. -}
  runArgs :: [Text]
  runArgs = mempty

  {-| Resets the state of a temporary process. -}
  reset :: ProcHandle a -> IO ()

  {-| Determines the service URI of the process. -}
  uriOf :: HostIpAddress -> SvcURI

  {-| Checks if the temporary process started ok. -}
  ping :: ProcHandle a -> IO ()

  {-| Maximum number of pings to perform. -}
  pingCount :: Natural
  pingCount = 4

  {-| Number of milliseconds between pings. -}
  pingGap :: Natural
  pingGap = 1000000


{-| Image of process. -}
imageText :: forall a . (Proc a) => a -> Text
imageText _  = Text.pack $ symbolVal (Proxy :: Proxy (Image a))


{-| Name of a process. -}
nameOf :: forall a . (Proc a) => a -> Text
nameOf _  = Text.pack $ symbolVal (Proxy :: Proxy (Name a))


{-| Simplifies use of @'runArgs'. -}
runArgs' :: forall a . (Proc a) => a -> [Text]
runArgs' _  = runArgs @a

{-| Simplifies use of @'pingCount'. -}
pingCount' :: forall a . (Proc a) => a -> Natural
pingCount' _  = pingCount @a


{-| Simplifies use of @'pingGap'. -}
pingGap' :: forall a . (Proc a) => a -> Natural
pingGap' _  = pingGap @a


{-| Simplifies use of @'uriOf'. -}
uriOf' :: forall a . (Proc a) => a -> HostIpAddress -> SvcURI
uriOf' _ addr  = uriOf @a addr


{-| The full args of a @docker run@ command for starting up a 'Proc'. -}
dockerCmdArgs :: forall a . (Proc a) => [Text]
dockerCmdArgs = [
  "run"
  , "-d"
  ]
  <> runArgs @a
  <> [imageText' @a]


imageText' :: forall a . (Proc a) => Text
imageText' = Text.pack $ symbolVal (Proxy :: Proxy (Image a))


-- | The ip address of the virtual host.
type HostIpAddress = Text


-- | Connection string used to access the service once its running.
type SvcURI = C8.ByteString


{-| Starts a 'Proc'.

Returns the 'ProcHandle' used to control the started process.
-}
startup :: forall a . Proc a => a -> IO (ProcHandle a)
startup x = do
  let fullArgs = dockerCmdArgs @a
      isGarbage = flip elem ['\'', '\n']
      trim = dropWhileEnd isGarbage . dropWhile isGarbage
  hPid <- trim <$> readProcess "docker" (map Text.unpack fullArgs) ""
  hAddr <- (Text.pack . trim) <$> readProcess "docker"
    [ "inspect"
    , hPid
    , "--format"
    , "'{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'"
    ] ""
  let hUri = uriOf @a hAddr
      h = ProcHandle {hProc=x, hPid, hUri, hAddr }
  nPings h `onException` terminate h
  pure h


{-| Ping a ProcHandle several times. -}
nPings :: Proc a => ProcHandle a -> IO ()
nPings h@ProcHandle{hProc = p} =
  let
    errMsg = "tmp.proc: startup failed for " <> nameOf p

    go 0 =
      ping h `catch` (\(e :: IOException) -> do
                         Text.hPutStrLn stderr errMsg
                         throw e )
    go n =
      ping h `catch` (\(_ :: IOException) -> do
                             threadDelay $ fromEnum $ pingGap' p
                             go (n - 1) )
  in
    go $ fromEnum $ pingCount' p


{-| Constraint alias used to constrain types where a 'Name' looks up
  a type in an 'HList' of 'ProcHandle'.
-}
type HasNamedHandle s a xs =
  ( s ~ Name a
  , Proc a
  , AreProcs xs
  , MemberGadt s (ProcHandle a) (Handle2KV (Proc2Handle xs))
  )


{-| Obtains the handle with the given @'Name'@ from an 'HList' of 'ProcHandle'. -}
named
  :: HasNamedHandle s a xs
  => Proxy s -> HList (Proc2Handle xs) -> ProcHandle a
named proxy xs = named' proxy $ toKVs xs


{-| Liked 'named', but constrains the handle to be 'Connectable'. -}
connected
  :: (HasNamedHandle s a xs, Connectable a)
  => Proxy s -> HList (Proc2Handle xs) -> ProcHandle a
connected proxy xs = named' proxy $ toKVs xs


{-| Liked 'connected', but provides the 'Conn' to a callback. -}
withNamedConn
  :: (HasNamedHandle s a xs, Connectable a)
  => Proxy s -> HList (Proc2Handle xs) -> (Conn a -> IO b) -> IO b
withNamedConn proxy xs action = flip withTmpConn action $ named' proxy $ toKVs xs


{-| Run an action on a 'Connectable' handle as a callback on its 'Conn' -}
withTmpConn :: Connectable a => ProcHandle a -> (Conn a -> IO b) -> IO b
withTmpConn handle action = bracket (openConn handle) closeConn action

named'
  :: forall (s :: Symbol) a (xs :: [*]) .
     ( KnownSymbol s
     , MemberGadt s (ProcHandle a) xs)
  => Proxy s -> HList xs -> ProcHandle a
named' _ kvs = selectG @s @(ProcHandle a) kvs


{-| Resets the handle with the given @'Name'@ in a list of Handles. -}
ixReset
  :: HasNamedHandle s a xs
  => Proxy s -> HList (Proc2Handle xs) -> IO ()
ixReset proxy xs = ixReset' proxy $ toKVs xs

ixReset'
  :: forall (s :: Symbol) a (xs :: [*]) .
     ( Proc a
     , s ~ Name a
     , MemberGadt s (ProcHandle a) xs)
  => Proxy s -> HList xs -> IO ()
ixReset' _ kvs = reset $ selectG @s @(ProcHandle a) kvs


{-| Pings the handle with the given @'Name'@ in a list of Handles. -}
ixPing
  :: HasNamedHandle s a xs
  => Proxy s -> HList (Proc2Handle xs) -> IO ()
ixPing proxy xs = ixPing' proxy $ toKVs xs

ixPing'
  :: forall (s :: Symbol) a (xs :: [*]) .
     ( Proc a
     , s ~ Name a
     , MemberGadt s (ProcHandle a) xs)
  => Proxy s -> HList xs -> IO ()
ixPing' _ kvs = ping $ selectG @s @(ProcHandle a) kvs


{-| URI for the handle with the given @'Name'@ in a list of Handles. -}
ixUriOf
  :: HasNamedHandle s a xs
  => Proxy s -> HList (Proc2Handle xs) -> SvcURI
ixUriOf proxy xs = ixUriOf' proxy $ toKVs xs

ixUriOf'
  :: forall (s :: Symbol) a (xs :: [*]) .
     ( Proc a
     , s ~ Name a
     , MemberGadt s (ProcHandle a) xs)
  => Proxy s -> HList xs -> SvcURI
ixUriOf' _ kvs = hUri $ selectG @s @(ProcHandle a) kvs


{-| Create a 'HList' of @'KV's@ from a 'HList' of @'ProcHandle's@. -}
toKVs :: AreProcs xs => HList (Proc2Handle xs) -> HList (Handle2KV (Proc2Handle xs))
toKVs = go $ p2h procProof
  where
    go :: SomeHandles as -> HList as -> HList (Handle2KV as)
    go SomeHandlesNil         HNil          = HNil
    go (SomeHandlesCons cons) (x `HCons` y) = toKV x `HCons` go cons y


{-| Convert a 'ProcHandle' to a 'KV'. -}
toKV :: Proc a => ProcHandle a -> KV (Name a) (ProcHandle a)
toKV h = V h


{-| Converts list of types to the corresponding 'ProcHandle' types. -}
type family Proc2Handle (as :: [*]) = (handleTys :: [*]) | handleTys -> as where
  Proc2Handle '[]        = '[]
  Proc2Handle (a ':  as) = ProcHandle a ': Proc2Handle as


{-| Convert a list of 'ProcHandle' types to corresponding 'KV' types. -}
type family Handle2KV (ts :: [*]) = (kvTys :: [*]) | kvTys -> ts where
  Handle2KV '[]                   = '[]
  Handle2KV (ProcHandle t ':  ts) = KV (Name t) (ProcHandle t) ': Handle2KV ts


{-| Used by @'AreProcs'@ to prove a list of types just contains @'Proc's@. -}
data SomeProcs (as :: [*]) where
  SomeProcsNil  :: SomeProcs '[]
  SomeProcsCons :: (Proc a, IsAbsent a as) => SomeProcs as -> SomeProcs (a ': as)


{-| Declares a proof that a list of types only contains @'Proc's@. -}
class AreProcs as where
  procProof :: SomeProcs as

instance AreProcs '[] where
  procProof = SomeProcsNil

instance (Proc a, AreProcs as, IsAbsent a as) => AreProcs (a ': as) where
  procProof = SomeProcsCons procProof


{-| Used to prove a list of types just contains @'ProcHandle's@. -}
data SomeHandles (as :: [*]) where
  SomeHandlesNil  :: SomeHandles '[]
  SomeHandlesCons :: Proc a => SomeHandles as -> SomeHandles (ProcHandle a ': as)


p2h :: SomeProcs as -> SomeHandles (Proc2Handle as)
p2h SomeProcsNil         = SomeHandlesNil
p2h (SomeProcsCons cons) = SomeHandlesCons (p2h cons)
