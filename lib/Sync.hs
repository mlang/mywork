{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}

module Sync
  -- (
  -- )
where

import           Control.Applicative ( (<|>) )
import           Control.Lens
import           Control.Monad ( filterM, foldM )
import           Control.Monad.IO.Class ( MonadIO, liftIO )
import           Control.Monad.State ( StateT, evalStateT, gets, modify )
import qualified Data.HashMap.Lazy as HM
import           Data.Ini
import qualified Data.List as DL
import           Data.Maybe ( catMaybes )
import           Data.Text ( Text )
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Data.Time.Calendar ( Day )
import           Data.Time.Clock ( getCurrentTime, utctDay )
import           Path ( (</>), Path, Abs, Dir, relfile, reldir
                      , toFilePath, parseAbsDir, fileExtension )
import           Path.IO ( doesDirExist, doesFileExist, getModificationTime
                         , listDir )

import           Defs


data LocationStatus = LocationStatus { locExists :: Maybe Bool
                                     , otherLocs :: [ (LType, LocationSpec) ]
                                     , locNotes :: [ Note ]
                                     , lastUpd :: Maybe Day
                                     }

data LType = GitRepo GitRemote | GitFork LType | DarcsRepo
  deriving Eq

newtype GitRemote = GitRemote Text
  deriving Eq


syncLocation :: MonadIO m => Location -> m LocationStatus
syncLocation l = case l ^. locationL of
  LocalSpec lcl ->
    do e <- liftIO $ doesDirExist lcl
       u <- if e
            then Just . utctDay <$> liftIO (getModificationTime lcl)
            else return Nothing
       o <- getOtherLocs lcl
       nts <- getLocNotes lcl
       return $ LocationStatus { locExists = Just e
                               , otherLocs = o
                               , locNotes = nts
                               , lastUpd = u
                               }
  RemoteSpec _ -> return LocationStatus { locExists = Nothing
                                        , otherLocs = mempty
                                        , locNotes = mempty
                                        , lastUpd = Nothing
                                        }

-- | Searches for other locations based on the current location.  This will find
-- locations like remote git repos, darcs repos, etc.
--
-- These locations are added permanently to the project.
getOtherLocs :: MonadIO m => Path Abs Dir -> m [ (LType, LocationSpec) ]
getOtherLocs lcl = concat <$> sequence [ getGitLocs lcl
                                       , getDarcsLocs lcl
                                       ]


getGitLocs :: MonadIO m => Path Abs Dir -> m [ (LType, LocationSpec) ]
getGitLocs lcl =
  let gitCfgFile = lcl </> [relfile|.git/config|]
      gcRemote sname cfg locs =
        case T.words sname of
          ["remote", rmt] ->
            let t = GitRepo $ GitRemote
                    -- drop surrounding double-quotes
                    $ T.drop 1 $ T.take (T.length rmt - 1) rmt
            in locs <> catMaybes
               [ (t,) . toLocSpec <$> HM.lookup "url" cfg
               , (GitFork t,) . toLocSpec <$> HM.lookup "pushurl" cfg
               ]
          _ -> locs
      toLocSpec t = maybe (RemoteSpec t) LocalSpec $ parseAbsDir $ T.unpack t
      gcProc = HM.foldrWithKey gcRemote mempty . unIni
  in do ge <- liftIO (doesFileExist gitCfgFile)
        if ge
          then do gt <- liftIO $ TIO.readFile (toFilePath gitCfgFile)
                  case parseIni gt of
                    Left _e -> return mempty -- no error reporting
                    Right gc -> return $ gcProc gc
          else return mempty


getDarcsLocs :: MonadIO m => Path Abs Dir -> m [ (LType, LocationSpec) ]
getDarcsLocs lcl =
  let darcsRepos = lcl </> [relfile|_darcs/prefs/repos|]
      mkDarcs t = ( DarcsRepo
                  , maybe (RemoteSpec t) LocalSpec $ parseAbsDir $ T.unpack t
                  )
      lclExists (_,r) = case r of
        RemoteSpec _ -> return True
        LocalSpec d -> doesDirExist d
  in do de <- liftIO (doesFileExist darcsRepos)
        if de
          then do rst <- liftIO $ TIO.readFile $ toFilePath darcsRepos
                  let rsc = mkDarcs <$> T.lines rst
                  filterM lclExists rsc
          else return mempty


getLocNotes :: MonadIO m => Path Abs Dir -> m [ Note ]
getLocNotes lcl =
  let notesDir = lcl </> [reldir|@MyWork|]
      mkFileNote nl f =
        case fileExtension f of
          Just ".txt" ->
            do nt <- liftIO $ TIO.readFile (toFilePath f)
               nd <- utctDay <$> liftIO ( getModificationTime f)
               return $ Note { note = nt
                             , notedOn = nd
                             , noteCore =
                                 NoteRT
                                 { noteSource = ProjLoc
                                 }
                             } : nl
          _ -> return nl
  in do ne <- liftIO (doesDirExist notesDir)
        if ne
          then do (_,files) <- liftIO (listDir notesDir)
                  foldM mkFileNote mempty files
          else return mempty


applyLocSync :: Day -> LocationStatus -> Location -> Location
applyLocSync now locsts loc =
  let rmtnoteTxt :: (LType, LocationSpec) -> Text
      rmtnoteTxt = \case
        (GitRepo (GitRemote n), r) ->
          "Cloned from git repo " <> tshow n <> " @ " <> tshow r
        (GitFork (GitRepo (GitRemote n)), r) ->
          "Pushing to git repo " <> tshow n <> " fork @ " <>  tshow r
        (DarcsRepo, r) -> "Synced with darcs repo @ " <> tshow r
        (_, r) -> "Related to " <> tshow r
      addRmtNoteText ol cl =
        -- n.b. instead of using updateNote, which prefers the new note, this
        -- only adds a note if there isn't already one, preferring the existing
        -- one in case it has been updated (aside from the noteTitle).
        let rnt = rmtnoteTxt ol
            rn = Note { note = rnt, notedOn = now
                      , noteCore = NoteRT { noteSource = MyWorkGenerated }
                      }
        in case DL.find ((noteTitle' rnt ==) . noteTitle) (cl ^. notesL) of
             Nothing -> cl & notesL <>~ [rn]
             Just _ -> cl
      loc1 = foldr addRmtNoteText loc $ otherLocs locsts
      loc2 = foldr (updateLocNote Nothing) loc1 $ locNotes locsts
  in loc2 & locValidL .~ maybe True id (locExists locsts)
          & locatedOnL .~ (lastUpd locsts <|> loc ^. locatedOnL)

applyProjLocSync :: MonadIO m
                 => Maybe LocationSpec -> Project -> Location
                 -> StateT [LocationSpec] m Project
applyProjLocSync = go
  where
    go :: MonadIO m => Maybe LocationSpec -> Project -> Location -> StateT [LocationSpec] m Project
    go mbOldL p l =
      -- Check if this location was already processed
      gets (l ^. locationL `elem`) >>= \case
      True -> return p
      False ->
        do modify (l ^. locationL :)
           -- This location was not previously processed, so process it now
           locsts <- syncLocation l
           now <- utctDay <$> liftIO getCurrentTime

           -- Remove any previous dynamic notes
           let l' = l { notes = filter ((MyWorkDB ==) . view noteSourceL) $ notes l }

           let p' = updateLocation mbOldL (applyLocSync now locsts l') p
           let rmtspec rmtName =
                 DL.lookup (GitRepo (GitRemote rmtName)) $ otherLocs locsts
           let mkLoc (lt,ls) =
                 let nts = case lt of
                             GitRepo (GitRemote _) -> mempty
                             GitFork (GitRepo (GitRemote n)) ->
                               [ Note { note = "Fork of git repo @ " <>
                                               case rmtspec n of
                                                 Just rls -> tshow rls
                                                 Nothing -> "??"
                                      , notedOn = now
                                      , noteCore =
                                          NoteRT
                                          { noteSource = MyWorkGenerated
                                          }
                                      }
                               ]
                             DarcsRepo -> mempty
                             _ -> [ Note { note = "Related to " <> tshow ls
                                         , notedOn = now
                                         , noteCore =
                                             NoteRT
                                             { noteSource = MyWorkGenerated
                                             }
                                         }
                                  ]
                 in Location { location = ls
                             , locatedOn = Nothing
                             , notes = nts
                             , locCore = LocRT
                                         { locValid = True
                                         }
                             }
           foldM (go Nothing) p' (mkLoc <$> otherLocs locsts)


-- | Called to synchronize (load) a Project's dynamic information by searching
-- local locations for that dynamic information.  If the first argument is true,
-- this is a re-synchronization, so any existing dynamic information is discarded
-- first.
syncProject :: MonadIO m => Project -> m Project
syncProject p = evalStateT (foldM (applyProjLocSync Nothing) p $ p ^. locationsL) mempty
