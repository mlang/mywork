{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Panes.Notes () where

import           Brick hiding ( Location )
import           Brick.Panes
import           Brick.Widgets.List
import           Control.Lens
import           Control.Monad ( join )
import qualified Data.Text as T
import qualified Data.Vector as V

import           Defs
import           Panes.Common.Inputs


instance Pane WName MyWorkEvent Note (Maybe Location) where
  data (PaneState Note MyWorkEvent) = N { nL :: List WName Note }
  type (InitConstraints Note s) = ( HasLocation s
                                  , HasProjects s
                                  , HasSelection s
                                  )
  type (DrawConstraints Note s WName) = ( HasFocus s WName
                                        , HasLocation s
                                        )
  initPaneState gs =
    let l = N (list (WName "Notes:List") mempty 1)
    in flip updatePane l $ join $ snd <$> getCurrentLocation gs
  updatePane mbl ps =
    case mbl of
      Just l -> N $ listReplace (V.fromList $ notes l) (Just 0) (nL ps)
      Nothing -> N $ listReplace mempty Nothing (nL ps)
  drawPane ps gs =
    let isFcsd = gs^.getFocus.to focused == Just WNotes
        rndr nt = str (show (notedOn nt) <> " -- ")
                  <+> txt (headText $ T.lines $ note nt)
    in Just $ vBox [ renderList (const rndr) isFcsd (nL ps)
                     -- , hBorder
                   , vLimit 1 (fill '-'
                               <+> str " vv - Full Note - vv "
                               <+> fill '-')
                   , vLimitPercent 25
                     $ withVScrollBarHandles
                     $ withVScrollBars OnRight
                     $ viewport (WName "Notes:Scroll") Vertical
                     $ txtWrap
                     $ maybe "" (note . snd) $ listSelectedElement (nL ps)
                   ]
  focusable _ ps = focus1If WNotes $ not $ null $ listElements $ nL ps
  handlePaneEvent _ ev = nList %%~ \w -> nestEventM' w (handleListEvent ev)


nList :: Lens' (PaneState Note MyWorkEvent) (List WName Note)
nList f ps = (\n -> ps { nL = n }) <$> f (nL ps)


instance HasNote (PaneState Note MyWorkEvent) where
  selectedNote = fmap (noteTitle . snd) . listSelectedElement . nL
