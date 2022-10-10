{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{- |
   Module      : Text.Pandoc.Lua.Reader
   Copyright   : Copyright (C) 2021-2022 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Supports custom parsers written in Lua which produce a Pandoc AST.
-}
module Text.Pandoc.Lua.Reader ( readCustom ) where
import Control.Exception
import Control.Monad ((<=<), when)
import Control.Monad.IO.Class (MonadIO)
import Data.Maybe (fromMaybe)
import HsLua as Lua hiding (Operation (Div))
import HsLua.Core.Run (newGCManagedState, withGCManagedState)
import Text.Pandoc.Class (PandocMonad, findFileWithDataFallback, report)
import Text.Pandoc.Logging
import Text.Pandoc.Lua.Global (Global (..), setGlobals)
import Text.Pandoc.Lua.Init (runLuaWith)
import Text.Pandoc.Lua.PandocLua
import Text.Pandoc.Lua.Marshal.Pandoc (peekPandoc)
import Text.Pandoc.Readers (Reader (..))
import Text.Pandoc.Sources (ToSources(..), sourcesToText)
import qualified Data.Text as T

-- | Convert custom markup to Pandoc.
readCustom :: (PandocMonad m, MonadIO m)
            => FilePath -> m (Reader m)
readCustom luaFile = do
  luaState <- liftIO newGCManagedState
  luaFile' <- fromMaybe luaFile <$> findFileWithDataFallback "readers" luaFile
  either throw pure <=< runLuaWith luaState $ do
    let globals = [ PANDOC_SCRIPT_FILE luaFile ]
    setGlobals globals
    stat <- dofileTrace luaFile'
    -- check for error in lua script (later we'll change the return type
    -- to handle this more gracefully):
    when (stat /= Lua.OK)
      Lua.throwErrorAsException
    pure (reader luaState)

 where
  reader st = TextReader $ \opts srcs -> liftIO . withGCManagedState st $ do
    let input = toSources srcs
    getglobal "Reader"
    push input
    push opts
    pcallTrace 2 1 >>= \case
      OK -> forcePeek $ peekPandoc top
      ErrRun -> do
        -- Caught a runtime error. Check if parsing might work if we
        -- pass a string instead of a Sources list, then retry.
        runPeek (peekText top) >>= \case
          Failure {} ->
            -- not a string error object. Bail!
            throwErrorAsException
          Success errmsg -> do
            if "string expected, got pandoc Sources" `T.isInfixOf` errmsg
              then do
                pop 1
                _ <- unPandocLua $ do
                  report $ Deprecated "old Reader function signature" $
                    T.unlines
                    [ "Reader functions should accept a sources list; "
                    , "functions expecting `string` input are deprecated. "
                    , "Use `tostring` to convert the first argument to a "
                    , "string."
                    ]
                getglobal "Reader"
                push $ sourcesToText input  -- push sources as string
                push opts
                callTrace 2 1
                forcePeek $ peekPandoc top
              else
                -- nothing we can do here
                throwErrorAsException
      _ ->  -- not a runtime error, we won't be able to recover from that
        throwErrorAsException
