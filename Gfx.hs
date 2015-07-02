{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE KindSignatures #-}

module Gfx where

import System.Environment
import SDL
import SDL.Input.Keyboard
import Linear
import Linear.Affine ( Point(P) )
import Control.Monad
import Control.Monad.Loops
import Control.Monad.Primitive
import Control.Monad.IO.Class
import Control.Monad.State.Strict
import Data.Functor.Identity
import Foreign.C.Types
import Data.Word
import Data.Bits
import Data.Int

import Prelude hiding ((.))
import Control.Category

import qualified Graphics.Rendering.OpenGL as GL
import qualified SDL.Raw.Timer as Raw
import qualified Config
import Lens
import Util
import GfxUtil

type AllState cs m = (cs, GfxState cs m)

data MonadIO m => GfxState cs m = GfxState {
  window :: SDL.Window
  ,renderer :: SDL.Renderer
  ,key_handler :: SDL.Keycode -> StateT (AllState cs m) m ()
  ,draw_handler :: Float -> StateT (AllState cs m) m ()
  ,framer :: FrameTimer
  ,glcontext :: SDL.GLContext
  }

make_lenses_tuple "allstate" ("client", "gfx")
make_lenses_record "gfx" ''Gfx.GfxState

init :: (MonadIO m, Functor m) => cs -> m (cs, GfxState cs m)
init client_state = do
  SDL.initialize [SDL.InitVideo]

  let winConfig =
          SDL.defaultWindow {SDL.windowPosition = SDL.Absolute (P (V2 100 100))
                            ,SDL.windowSize     = Config.window_size Config.config
                            ,SDL.windowOpenGL   = Just (Config.opengl Config.config)}
                     
  let rdrConfig =
          SDL.RendererConfig {SDL.rendererSoftware      = False
                             ,SDL.rendererAccelerated   = True
                             ,SDL.rendererPresentVSync  = False
                             ,SDL.rendererTargetTexture = True}

  window <- liftIO $ SDL.createWindow (Config.window_title Config.config) winConfig
  renderer <- liftIO $ SDL.createRenderer window (-1) rdrConfig
  gl <- SDL.glCreateContext window 

  SDL.glMakeCurrent window gl
  SDL.glSetSwapInterval SDL.ImmediateUpdates

  framer <- frame_timer_new 60

  return (client_state, GfxState {window = window
                                 ,renderer = renderer
                                 ,key_handler = \ _ -> return ()
                                 ,draw_handler = \ _ -> return ()
                                 ,framer = framer
                                 ,glcontext = gl
                                 })

finish :: MonadIO m => StateT (AllState cs m) m ()
finish = do
  (client_state, gfx_state) <- get
  liftIO $ do
    SDL.destroyRenderer (renderer gfx_state)
    SDL.destroyWindow (window gfx_state)
    SDL.quit
  return ()

loop :: (Functor m, MonadIO m) => StateT (AllState cs m) m ()
loop = do
  (client_state, gfx_state) <- get

  let gfx_renderer = renderer gfx_state
  let gfx_draw_handler = draw_handler gfx_state
  let gfx_window = window gfx_state

  _ <- SDL.renderClear gfx_renderer
  _ <- SDL.renderPresent gfx_renderer

  iterateUntil Prelude.id $ do
    gfx_state <- gets snd
    waittime <- with_lens (gfx_framer . allstate_gfx) $ frame_timer_wait

--    (next, new_gfx_state) <- lift $ runStateT ((with_lens gfx_framer) frame_timer_next) gfx_state
--    put (client_state, new_gfx_state)

--    liftIO $ do
--      putStrLn $ "waiting for: " ++ (show waittime)

    SDL.delay (fromIntegral waittime)
    dt <- with_lens (gfx_framer . allstate_gfx) $ frame_timer_mark
    dts <- seconds_of_counter (fromIntegral dt)

    gfx_draw_handler dts
    SDL.glSwapWindow gfx_window

    process_events

--    case next of
--      FrameMark dts -> do
--        gfx_draw_handler dts
--        SDL.glSwapWindow gfx_window
--        process_events
--
--      FrameWait t -> do
--        SDL.delay (fromIntegral (truncate (1000 * t)))
--        return False

  gfx_state <- gets snd
  liftIO $ putStrLn $ "overall fps=" ++ (show (fps (framer gfx_state)))
  return ()

collect_events_timeout :: (Functor m, MonadIO m) => Float -> m [SDL.Event]
collect_events_timeout t = do
  m_ev <- SDL.waitEventTimeout (fromIntegral (truncate (1000 * t)))
  case m_ev of
    Nothing -> return []
    Just ev -> fmap (ev :) collect_events
collect_events :: (Functor m, MonadIO m) => m [SDL.Event]
collect_events = do
  m_ev <- SDL.pollEvent
  case m_ev of
    Nothing -> return []
    Just ev -> fmap (ev :) collect_events

process_events :: (Functor m, MonadIO m) => StateT (AllState cs m) m Bool
process_events = do
  events <- collect_events
  anyM process_event events

process_event :: MonadIO m => SDL.Event -> StateT (AllState cs m) m Bool
process_event ev = do
  (client_state, gfx_state) <- get
  case SDL.eventPayload ev of
    SDL.QuitEvent -> return True
    SDL.KeyboardEvent _ SDL.KeyDown _ _ (SDL.Keysym _ KeycodeEscape _) -> return True
    SDL.KeyboardEvent _ SDL.KeyDown _ _ (SDL.Keysym _ kc _) ->
      do () <- (key_handler gfx_state) kc
         return False
      --(SDL.MouseButtonEvent _ SDL.MouseButtonDown _ _ _ _ _) -> True
    _ -> return False

process_events_wait :: (MonadIO m, Functor m) => Float -> StateT (AllState cs m) m Bool
process_events_wait t = do
  events <- collect_events_timeout t
  anyM process_event events
