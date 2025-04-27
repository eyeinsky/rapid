-- |
-- Copyright:  (c) 2016 Ertugrul Söylemez
-- License:    BSD3
-- Maintainer: Markus Läll <markus.l2ll@gmail.com>
-- Stability:  experimental
--
-- This module provides a rapid prototyping suite for GHCi that can be
-- used standalone or integrated into editors.  You can hot-reload
-- individual running components as you make changes to their code.  It
-- is designed to shorten the development cycle during the development
-- of long-running programs like servers, web applications and
-- interactive user interfaces.
--
-- It can also be used in the context of batch-style programs:  Keep
-- resources that are expensive to create in memory and reuse them
-- across module reloads instead of reloading/recomputing them after
-- every code change.
--
-- Technically this package is a safe and convenient wrapper around
-- <https://hackage.haskell.org/package/foreign-store foreign-store>.
--
-- __Read the "Safety and securty" section before using this module!__

{-# LANGUAGE RankNTypes #-}

module Rapid
    ( -- * Introduction
      -- $intro

      -- ** Communication
      -- $communication

      -- ** Reusing expensive resources
      -- $reusing

      -- ** Cabal notes
      -- $cabal

      -- ** Emacs integration
      -- $emacs

      -- ** Safety and security
      -- $safety

      -- * Hot code reloading
      Rapid,
      rapid,

      -- * Threads
      restart,
      restartWith,
      start,
      startWith,
      stop,

      -- * Communication
      createRef,
      deleteRef,
      writeRef
    )
    where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Data.Dynamic
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Word
import Foreign.Store


-- | Handle to the current Rapid state.

data Rapid k =
    Rapid {
      rLock    :: TVar Bool,               -- ^ Lock on the current state.
      rRefs    :: TVar (Map k Dynamic),    -- ^ Mutable variables.
      rThreads :: TVar (Map k (Async ()))  -- ^ Active threads.
    }


-- | Cancel the given thread and wait for it to finish.

cancelAndWait :: Async a -> IO ()
cancelAndWait tv = do
    cancel tv
    () <$ waitCatch tv


-- | Get the value of the mutable variable with the given name.  If it
-- does not exist, it is created and initialised with the value returned
-- by the given action.
--
-- Mutable variables should only be used with values that can be
-- garbage-collected, for example communication primitives like
-- 'Control.Concurrent.MVar.MVar' and 'TVar', but also pure run-time
-- information that is expensive to generate, for example the parsed
-- contents of a file.

createRef
    :: (Ord k, Typeable a)
    => Rapid k  -- ^ Rapid state handle.
    -> k        -- ^ Name of the mutable variable.
    -> IO a     -- ^ Action to create.
    -> IO a
createRef r k gen =
    withRef r k $ \mxd ->
        case mxd of
          Nothing -> fmap (\x -> (Just (toDyn x), x)) gen
          Just xd
              | Just x <- fromDynamic xd -> pure (Just xd, x)
              | otherwise -> throwIO (userError "createRef: Wrong reference type")


-- | Delete the mutable variable with the given name, if it exists.

deleteRef
    :: (Ord k)
    => Rapid k  -- ^ Rapid state handle.
    -> k        -- ^ Name of the mutable variable.
    -> IO ()
deleteRef r k =
    withRef r k (\_ -> pure (Nothing, ()))


-- | Retrieve the current Rapid state handle, and pass it to the given
-- continuation.  If the state handle doesn't exist, it is created.  The
-- key type @k@ is used for naming reloadable services like threads.
--
-- __Warning__: The key type must not change during a session.  If you
-- need to change the key type, currently the safest option is to
-- restart GHCi.
--
-- This function uses the
-- <https://hackage.haskell.org/package/foreign-store foreign-store library>
-- to establish a state handle that survives GHCi reloads and is
-- suitable for hot reloading.
--
-- The first argument is the 'Store' index.  If you do not use the
-- /foreign-store/ library in your development workflow, just use 0,
-- otherwise use any unused index.

rapid
    :: forall k r.
       Word32             -- ^ Store index (if in doubt, use 0).
    -> (Rapid k -> IO r)  -- ^ Action on the Rapid state.
    -> IO r
rapid stNum k =
    mask $ \unmask ->
        lookupStore stNum >>=
        maybe (storeAction store create)
              (\_ -> readStore store) >>=
        pass unmask

    where
    create =
        pure Rapid
        <*> newTVarIO False
        <*> newTVarIO M.empty
        <*> newTVarIO M.empty

    pass unmask r = do
        atomically $ do
            readTVar (rLock r) >>= check . not
            writeTVar (rLock r) True
        unmask (k r) `finally` atomically (writeTVar (rLock r) False)

    store :: Store (Rapid k)
    store = Store stNum


-- | Create a thread with the given name that runs the given action.
--
-- The thread is restarted each time an update occurs.

restart
    :: (Ord k)
    => Rapid k  -- ^ Rapid state handle.
    -> k        -- ^ Name of the thread.
    -> IO ()    -- ^ Action the thread runs.
    -> IO ()
restart = restartWith async


-- | Create a thread with the given name that runs the given action.
--
-- The thread is restarted each time an update occurs.
--
-- The first argument is the function used to create the thread.  It can
-- be used to select between 'async', 'asyncBound' and 'asyncOn'.

restartWith
    :: (Ord k)
    => (forall a. IO a -> IO (Async a))  -- ^ Thread creation function.
    -> Rapid k  -- ^ Rapid state handle.
    -> k        -- ^ Name of the thread.
    -> IO ()    -- ^ Action the thread runs.
    -> IO ()
restartWith myAsync r k action =
    withThread r k $ \mtv -> do
        mapM_ cancelAndWait mtv
        Just <$> myAsync action


-- | Create a thread with the given name that runs the given action.
--
-- When an update occurs and the thread is currently not running, it is
-- started.

start
    :: (Ord k)
    => Rapid k  -- ^ Rapid state handle.
    -> k        -- ^ Name of the thread.
    -> IO ()    -- ^ Action the thread runs.
    -> IO ()
start = startWith async


-- | Create a thread with the given name that runs the given action.
--
-- When an update occurs and the thread is currently not running, it is
-- started.
--
-- The first argument is the function used to create the thread.  It can
-- be used to select between 'async', 'asyncBound' and 'asyncOn'.

startWith
    :: (Ord k)
    => (forall a. IO a -> IO (Async a))  -- ^ Thread creation function.
    -> Rapid k  -- ^ Rapid state handle.
    -> k        -- ^ Name of the thread.
    -> IO ()    -- ^ Action the thread runs.
    -> IO ()
startWith myAsync r k action =
    withThread r k $
        maybe (Just <$> myAsync action)
              (\tv -> poll tv >>=
                      maybe (pure (Just tv))
                            (\_ -> Just <$> myAsync action))


-- | Delete the thread with the given name.
--
-- When an update occurs and the thread is currently running, it is
-- cancelled.

stop :: (Ord k) => Rapid k -> k -> x -> IO ()
stop r k _ =
    withThread r k $ \mtv ->
        Nothing <$ mapM_ cancelAndWait mtv


-- | Apply the given transform to the reference with the given name.

withRef
    :: (Ord k)
    => Rapid k
    -> k
    -> (Maybe Dynamic -> IO (Maybe Dynamic, a))
    -> IO a
withRef r k f = do
    (mx, y) <- atomically (M.lookup k <$> readTVar (rRefs r)) >>=
               f
    atomically $ modifyTVar' (rRefs r) (maybe (M.delete k) (M.insert k) mx)
    pure y


-- | Apply the given transform to the thread with the given name.

withThread
    :: (Ord k)
    => Rapid k
    -> k
    -> (Maybe (Async ()) -> IO (Maybe (Async ())))
    -> IO ()
withThread r k f =
    atomically (M.lookup k <$> readTVar (rThreads r)) >>=
    f >>=
    atomically . modifyTVar' (rThreads r) . maybe (M.delete k) (M.insert k)


-- | Overwrite the mutable variable with the given name with the value
-- returned by the given action.  If the mutable variable does not
-- exist, it is created.
--
-- This function may be used to change the value type of a mutable
-- variable.

writeRef
    :: (Ord k, Typeable a)
    => Rapid k  -- ^ Rapid state handle.
    -> k        -- ^ Name of the mutable variable.
    -> IO a     -- ^ Value action.
    -> IO a
writeRef r k gen =
    withRef r k $ \_ ->
        fmap (\x -> (Just (toDyn x), x)) gen


{- $cabal

In general a Cabal project should not have this library as a build-time
dependency.  However, in certain environments (like Nix-based
development) it may be beneficial to include it in the @.cabal@ file
regardless.  A simple solution is to add a flag:

> flag Devel
>     default: False
>     description: Enable development dependencies
>     manual: True
>
> library
>     build-depends:
>         base >= 4.8 && < 5,
>         {- ... -}
>     if flag(devel)
>         build-depends: rapid
>     {- ... -}

Now you can configure your project with @-fdevel@ during development and
have this module available.

-}


{- $communication

If you need your background threads to communicate with each other, for
example by using concurrency primitives, some additional support is
required.  You cannot just create a 'TVar' within your @update@ action.
It would be a different one for every invocation, so threads that are
restarted would not communicate with already running threads, because
they would use a fresh @TVar@, while the old threads would still use the
old one.

To solve this, you need to wrap your 'newTVar' action with 'createRef'.
The @TVar@ created this way will survive reloads in the same way as
background threads do.  In particular, if there is already one from an
older invocation of @update@, it will be reused:

> import Control.Concurrent.STM
> import Control.Monad
> import Rapid
>
> update =
>     rapid 0 $ \r -> do
>         mv1 <- createRef r "var1" newEmptyTMVarIO
>         mv2 <- createRef r "var2" newEmptyTMVarIO
>
>         start r "producer" $
>             mapM_ (atomically . putTMVar mv1) [0 :: Integer ..]
>
>         restart r "consumer" $
>             forever . atomically $ do
>                 x <- takeTMVar mv1
>                 putTMVar mv2 (x, "blah")
>
>         -- For debugging the update action:
>         replicateM_ 3 $
>             atomically (takeTMVar mv2) >>= print

You can now change the string @"blah"@ in the consumer thread and then
run @update@.  You will notice that the numbers in the left component of
the tuples keep increasing even after a reload, while the string in the
right component changes.  That means the producer thread was not
restarted, but the consumer thread was.  Yet the restarted consumer
thread still refers to the same @TVar@ as before, so it still receives
from the producer.

-}


{- $emacs

This library integrates well with
<https://haskell.github.io/haskell-mode/manual/latest/Interactive-Haskell.html haskell-interactive-mode>,
particularly with its somewhat hidden
@haskell-process-reload-devel-main@ function.

This function finds your @DevelMain@ module by looking for a buffer
named @DevelMain.hs@, loads or reloads it in your current project's
interactive session and then runs @update@.  Assuming that you are
already using /haskell-interactive-mode/ all you need to do to use it is
to keep your @DevelMain@ module open in a buffer and type @M-x
haskell-process-reload-devel-main RET@ when you want to hot-reload.  You
may want to bind it to a key:

> (define-key haskell-mode-map (kbd "C-c m") 'haskell-process-reload-devel-main)

Since you will likely always reload the current module before running
@update@, you can save a few keystrokes by defining a small function
that does both and bind that one to a key instead:

> (defun my-haskell-run-devel ()
>   "Reloads the current module and then hot-reloads code via DevelMain.update."
>   (interactive)
>   (haskell-process-load-file)
>   (haskell-process-reload-devel-main))
>
> (define-key haskell-mode-map (kbd "C-c m") 'my-haskell-run-devel)

-}


{- $intro

While developing a project you may want to have your app running in
the background and restart (parts of) it as you iterate.  The premises
to using this library are:

1. you already have such a project

2. you use GHCi

To use this functionality, create a new module in your project and
export the @update@ action:

> module DevelMain (update) where
>
> import Rapid
>
> update :: IO ()
> update =
>     rapid 0 $ \r ->
>         -- We'll list our components here shortly.
>         pure ()

After loading this module in GHCi you run @update@ whenever you want
to restart the application in the background.  E.g, in the case of a
web server that server is simply restarted on every @update@:

> import qualified Data.Text as T
> import Rapid
> import Snap.Core
> import Snap.Http.Server
>
> update =
>     rapid 0 $ \r ->
>         restart r "webserver" $
>             quickHttpServe (writeText (T.pack "Hello world!"))

The app keeps running in the background even when you reload modules,
and GHCi REPL continues to be functional as well.  To apply new
changes, you simply reload @DevelMain@ again and run @update@.
Changing "Hello world!" to something else above will start responding
with the new text after you run @update@.

To stop the background thread, replace @restart@ with @stop@ within
@update@ and run it.  Note that the action given to 'stop' is actually
ignored.  It only takes the action argument for your convenience.

You can run multiple threads in the background simultaneously, have
some of them restart while others not:

> import MyProject.MyDatabase
> import MyProject.MyBackgroundWorker
> import MyProject.MyWebServer
> import Rapid
>
> update =
>     rapid 0 $ \r -> do
>         start r "database" myDatabase       -- doesn't restart on update
>         start r "worker" myBackgroundWorker -- doesn't restart on update
>         restart r "webserver" myWebServer   -- restarts on update

Usually you'd use @restart@ in front of the component you are working
on, while using @start@ for others.

Note that even while working on @MyProject.MyWebServer@ you're always
reloading @DevelMain@ to get the new @update@.

-}


{- $reusing

This library can also be used to shorten the development cycle when
using expensive resources:

> import Control.Exception
> import Data.Aeson
> import qualified Data.ByteString as B
>
> update =
>     rapid 0 $ \r -> do
>         value <- createRef r "file" $
>             B.readFile "blah.json" >>=
>             either (throwIO . userError) pure . eitherDecode
>
>         -- You can now reuse 'value' across reloads.

The above parses blah.json just once on startup. To actually recreate
the value replace @createRef@ to @writeRef@ temporarily and run @update@.

Using @deleteRef@ in the same manner removes values you no longer need.

-}


{- $safety

It's easy to crash GHCi with this library.  In order to prevent that,
follow these rules:

  * Do not change your service name type (the second argument to
    @start@, @stop@ and @restart@) within a session.  Simplest way
    to do that is to resist the temptation to define a custom name
    type and just use strings instead.  If you do change the name
    type then you need to restart GHCi.

  * Be careful with mutable variables created with @createRef@: if the
    value type changes (e.g. constructors or fields were changed), so
    must the variable be recreated, e.g by using @writeRef@ once.
    This likely also entails restarting all the threads that were
    using this variable.  Again, the safest option is to restart GHCi.

  * If any package in the current environment changes (especially this
    library itself), for example by updating a package via @cabal@ or
    @stack@, the @update@ action is likely to crash or go wrong in
    subtle ways due to binary incompatibility.  Again, restarting GHCi
    solves this.

  * __This library is a development tool!  Do not use it to hot-reload
    productive environments!__ There are much safer and more
    appropriate ways to hot-reload code in production, for example by
    using a plugin system.

The reason for this unsafety is that the underlying /foreign-store/
library is itself unsafe by nature, requiring us to maintain binary
compatibility.  This library hides most of that unsafety, but still
requires you to follow the rules listed above.

-}
