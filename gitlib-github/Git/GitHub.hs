{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Git.GitHub where

import           Control.Applicative
import           Control.Concurrent
import           Control.Exception
import           Control.Failure
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader
import           Data.Aeson hiding (Success)
import           Data.Attempt
import           Data.ByteString as B hiding (pack, putStrLn, map, null)
import qualified Data.ByteString.Base64 as B64
import           Data.Conduit
import           Data.Default ( Default(..) )
import           Data.Foldable (for_)
import           Data.Function
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import           Data.Hex
import           Data.IORef
import           Data.List as L
import           Data.Marshal.JSON ()
import           Data.Maybe
import           Data.Monoid
import           Data.Tagged
import           Data.Text as T hiding (drop, map, null)
import qualified Data.Text.Encoding as T
import           Data.Time.Clock (UTCTime)
import           Data.Time.Format (formatTime, parseTime)
import           Filesystem.Path.CurrentOS (FilePath)
import qualified Filesystem.Path.CurrentOS as F
import qualified Git
import qualified Github.Repos as Github
import           Network.HTTP.Conduit hiding (Proxy, Response)
import           Network.REST.Client
import           Prelude hiding (FilePath)
import           System.IO.Unsafe
import           System.Locale (defaultTimeLocale)
import           Text.Shakespeare.Text (st)

type Oid       = Git.Oid GitHubRepository

type BlobOid   = Git.BlobOid GitHubRepository
type TreeOid   = Git.TreeOid GitHubRepository
type CommitOid = Git.CommitOid GitHubRepository

type Blob      = Git.Blob GitHubRepository
type Tree      = Git.Tree GitHubRepository
type TreeEntry = Git.TreeEntry GitHubRepository
type Commit    = Git.Commit GitHubRepository

type TreeRef   = Git.TreeRef GitHubRepository
type CommitRef = Git.CommitRef GitHubRepository

type Reference = Git.Reference GitHubRepository Commit

instance Git.RepositoryBase GitHubRepository where
    data Oid GitHubRepository = Oid { getOid :: ByteString }

    data Tree GitHubRepository = GitHubTree
        { ghTreeOid      :: IORef (Maybe TreeOid)
        , ghTreeContents :: IORef (HashMap Text TreeEntry)
        }

    data Commit GitHubRepository = GitHubCommit
        { ghCommitOid       :: Maybe CommitOid
        , ghCommitAuthor    :: Git.Signature
        , ghCommitCommitter :: Maybe Git.Signature
        , ghCommitMessage   :: Text
        , ghCommitTree      :: TreeRef
        , ghCommitParents   :: [CommitRef]
        }

    data Tag GitHubRepository = Tag { tagCommit :: CommitRef }

    facts = return Git.RepositoryFacts
        { Git.hasSymbolicReferences = False }

    parseOid x = Oid <$> unhex (T.encodeUtf8 x)
    renderOid (Tagged (Oid x)) = T.toLower (T.decodeUtf8 (hex x))

    createRef    = ghCreateRef
    lookupRef    = ghLookupRef
    updateRef    = ghUpdateRef
    deleteRef    = ghDeleteRef
    allRefs      = ghAllRefs
    lookupCommit = ghLookupCommit
    lookupTree   = ghLookupTree
    lookupBlob   = ghLookupBlob
    lookupTag    = undefined -- ghLookupTag
    lookupObject = undefined -- ghLookupObject
    newTree      = ghNewTree
    createBlob   = ghCreateBlob
    createCommit = ghCreateCommit
    createTag    = undefined

data GitHubBlob = GitHubBlob
    { ghBlobContent  :: ByteString
    , ghBlobEncoding :: Text
    , ghBlobSha      :: Text
    , ghBlobSize     :: Int } deriving Show

instance Show (Git.Oid GitHubRepository) where
    show = T.unpack . Git.renderOid . Tagged

instance Ord (Git.Oid GitHubRepository) where
    compare (Oid l) (Oid r) = compare l r

instance Eq (Git.Oid GitHubRepository) where
    Oid l == Oid r = l == r

instance MonadBase IO GitHubRepository where
    liftBase = liftIO

instance MonadUnsafeIO GitHubRepository where
    unsafeLiftIO = return . unsafePerformIO

instance MonadThrow GitHubRepository where
    -- monadThrow :: Exception e => e -> m a
    monadThrow = throw

-- jww (2012-12-26): If no name mangling scheme is provided, assume it is
-- "type name prefix"
-- jww (2013-01-12): Look into using JsonGrammar to automate JSON encoding and
-- decoding: https://github.com/MedeaMelana/JsonGrammar
instance FromJSON GitHubBlob where
  parseJSON (Object v) = GitHubBlob <$> v .: "content"
                                    <*> v .: "encoding"
                                    <*> v .: "sha"
                                    <*> v .: "size"
  parseJSON _ = mzero

ghRestfulEx :: (ToJSON a, FromJSON b) => Text -> Text -> a -> RESTful ()
            -> GitHubRepository b
ghRestfulEx method url arg act = do
    gh        <- ghGet
    urlPrefix <- ghPrefix
    let tok = gitHubToken gh
    result <- liftIO $ runResourceT $
              withRestfulEnvAndMgr (fromJust (httpManager gh))
              (for_ tok $ \t -> do
                    addHeader "Authorization" ("token " <> t)
                    addHeader "Content-type" "application/json")
              (restfulJsonEx arg [st|#{method} #{urlPrefix}/#{url}|] act)
    attempt failure return result

ghRestful :: (ToJSON a, FromJSON b) => Text -> Text -> a -> GitHubRepository b
ghRestful method url arg = do
    gh        <- ghGet
    urlPrefix <- ghPrefix
    let tok = gitHubToken gh
    result <- liftIO $ runResourceT $
              withRestfulEnvAndMgr (fromJust (httpManager gh))
              (for_ tok $ \t -> do
                    addHeader "Authorization" ("token " <> t)
                    addHeader "Content-type" "application/json")
              (restfulJson arg [st|#{method} #{urlPrefix}/#{url}|])
    attempt failure return result

ghLookupBlob :: BlobOid -> GitHubRepository Blob
ghLookupBlob oid = do
    -- jww (2013-01-12): Split out GET to its own argument, using StdMethod
    -- from http-types.  Also, use a type class for this argument, to be added
    -- to http-types:
    --     class IsHttpMethod a where asHttpMethod :: a -> ByteString
    -- jww (2012-12-26): Do we want runtime checking of the validity of the
    -- method?  Yes, but allow the user to declare it as OK.
    blob <- ghRestful "GET" ("git/blobs/" <> Git.renderOid oid) ()
    let content = ghBlobContent blob
    case ghBlobEncoding blob of
        "base64" ->
            case dec content of
                Right bs' -> return (Git.Blob oid (Git.BlobString bs'))
                Left str  -> failure (Git.TranslationException (T.pack str))
        "utf-8" -> return (Git.Blob oid (Git.BlobString content))
        enc -> failure (Git.BlobEncodingUnknown enc)

  where dec = B64.decode . B.concat . B.split 10

data Content = Content { contentContent  :: ByteString
                       , contentEncoding :: Text } deriving Show

instance FromJSON Content where
  parseJSON (Object v) = Content <$> v .: "content"
                                 <*> v .: "encoding"
  parseJSON _ = mzero

instance ToJSON Content where
  toJSON (Content bs enc) = object ["content" .= bs, "encoding" .= enc]

instance Default Content where
  def = Content B.empty "utf-8"

data GitHubOidProxy = GitHubOidProxy { runGhpOid :: Oid } deriving Show

instance FromJSON GitHubOidProxy where
  parseJSON (Object v) =
      GitHubOidProxy . Oid <$>
      (unsafePerformIO . unhex . T.encodeUtf8 <$> v .: "sha")
  parseJSON _ = mzero

instance ToJSON GitHubOidProxy where
  toJSON (GitHubOidProxy (Oid sha)) = object ["sha" .= show sha]

textToOid :: Text -> Oid
textToOid = Oid . unsafePerformIO . unhex . T.encodeUtf8

oidToText :: Oid -> Text
oidToText = T.pack . show

ghCreateBlob :: Git.BlobContents GitHubRepository -> GitHubRepository BlobOid
ghCreateBlob (Git.BlobString content) =
    Tagged . runGhpOid
        <$> ghRestful "POST" "git/blobs"
                      (Content (B64.encode content) "base64")
ghCreateBlob _ = error "NYI"    -- jww (2013-02-06): NYI

data GitHubTreeProxy = GitHubTreeProxy
    { ghpTreeOid      :: Maybe Text
    , ghpTreeContents :: [GitHubTreeEntryProxy]
    } deriving Show

instance FromJSON GitHubTreeProxy where
  parseJSON (Object v) =
      -- jww (2013-02-06): The GitHub API supports using the "base_tree"
      -- parameter for doing incremental updates based on existing trees.
      -- This could be a huge efficiency gain, although it would only be an
      -- optimization, as we always know the full contents of every tree.
      GitHubTreeProxy <$> v .: "sha"
                      <*> v .: "tree"
  parseJSON _ = mzero

instance ToJSON GitHubTreeProxy where
  toJSON (GitHubTreeProxy _ contents) = object [ "tree" .= contents ]

data GitHubTreeEntryProxy = GitHubTreeEntryProxy
    { ghpTreeEntryType    :: Text
    , ghpTreeEntryPath    :: Text
    , ghpTreeEntryMode    :: Text
    , ghpTreeEntrySize    :: Int
    , ghpTreeEntrySha     :: Text
    , ghpTreeEntrySubtree :: Maybe TreeRef
    }

instance Show GitHubTreeEntryProxy where
    show x = Prelude.unlines
        [ "GitHubTreeEntryProxy {"
        , "  ghpTreeEntryType    = " ++ show (ghpTreeEntryType x)
        , "  ghpTreeEntryPath    = " ++ show (ghpTreeEntryPath x)
        , "  ghpTreeEntryMode    = " ++ show (ghpTreeEntryMode x)
        , "  ghpTreeEntrySize    = " ++ show (ghpTreeEntrySize x)
        , "  ghpTreeEntrySha     = " ++ show (ghpTreeEntrySha x)
        , "}"
        ]

treeEntryToProxy :: Text -> TreeEntry -> GitHubRepository GitHubTreeEntryProxy
treeEntryToProxy name (Git.BlobEntry oid exe) =
    return GitHubTreeEntryProxy
        { ghpTreeEntryType    = "blob"
        , ghpTreeEntryPath    = name
        , ghpTreeEntryMode    = if exe then "100755" else "100644"
        , ghpTreeEntrySize    = (-1)
        , ghpTreeEntrySha     = Git.renderOid oid
        , ghpTreeEntrySubtree = Nothing
        }
treeEntryToProxy name (Git.TreeEntry ref@(Git.ByOid oid)) =
    return GitHubTreeEntryProxy
        { ghpTreeEntryType    = "tree"
        , ghpTreeEntryPath    = name
        , ghpTreeEntryMode    = "040000"
        , ghpTreeEntrySize    = (-1)
        , ghpTreeEntrySha     = Git.renderOid oid
        , ghpTreeEntrySubtree = Just ref
        }
treeEntryToProxy name (Git.TreeEntry ref@(Git.Known tree)) = do
    oid <- Git.writeTree tree
    return GitHubTreeEntryProxy
        { ghpTreeEntryType    = "tree"
        , ghpTreeEntryPath    = name
        , ghpTreeEntryMode    = "040000"
        , ghpTreeEntrySize    = (-1)
        , ghpTreeEntrySha     = Git.renderOid oid
        , ghpTreeEntrySubtree = Just ref
        }

proxyToTreeEntry :: GitHubTreeEntryProxy -> GitHubRepository TreeEntry
proxyToTreeEntry entry@(GitHubTreeEntryProxy { ghpTreeEntryType = "blob" }) = do
    oid <- Git.parseOid (ghpTreeEntrySha entry)
    return $ Git.BlobEntry (Tagged oid) (ghpTreeEntryMode entry == "100755")

proxyToTreeEntry entry@(GitHubTreeEntryProxy { ghpTreeEntryType = "tree" }) = do
    oid <- Git.parseOid (ghpTreeEntrySha entry)
    return $ Git.TreeEntry (Git.ByOid (Tagged oid))

proxyToTreeEntry _ = error "Unexpected tree entry type from GitHub"

instance FromJSON GitHubTreeEntryProxy where
  parseJSON (Object v) =
      GitHubTreeEntryProxy <$> v .: "type"
                           <*> v .: "path"
                           <*> v .: "mode"
                           <*> v .:? "size" .!= (-1)
                           <*> v .: "sha"
                           <*> pure Nothing
  parseJSON _ = mzero

instance ToJSON GitHubTreeEntryProxy where
  toJSON entry = object [ "type" .= ghpTreeEntryType entry
                        , "path" .= ghpTreeEntryPath entry
                        , "mode" .= ghpTreeEntryMode entry
                        , "sha"  .= ghpTreeEntrySha entry ]

ghNewTree :: GitHubRepository Tree
ghNewTree = GitHubTree <$> (liftIO $ newIORef Nothing)
                       <*> (liftIO $ newIORef HashMap.empty)

ghLookupTree :: TreeOid -> GitHubRepository Tree
ghLookupTree oid = do
    treeProxy <- ghRestful "GET" ("git/trees/" <> Git.renderOid oid) ()
    oid' <- Git.parseOid (fromJust (ghpTreeOid treeProxy))
    subtree' <- subtree treeProxy
    GitHubTree <$> (liftIO $ newIORef (Just (Tagged oid')))
               <*> (liftIO $ newIORef subtree')
  where
    subtree tp =
        HashMap.fromList <$>
        mapM (\entry -> (,) <$> pure (ghpTreeEntryPath entry)
                           <*> proxyToTreeEntry entry)
             (ghpTreeContents tp)

doLookupTreeEntry :: Tree -> [Text] -> GitHubRepository (Maybe TreeEntry)
doLookupTreeEntry t [] = return (Just (Git.treeEntry t))
doLookupTreeEntry t (name:names) = do
  -- Lookup the current name in this tree.  If it doesn't exist, and there are
  -- more names in the path and 'createIfNotExist' is True, create a new Tree
  -- and descend into it.  Otherwise, if it exists we'll have @Just (TreeEntry
  -- {})@, and if not we'll have Nothing.

  y <- liftIO $ HashMap.lookup name <$> readIORef (ghTreeContents t)
  if null names
      then return y
      else case y of
      Just (Git.BlobEntry {}) -> failure Git.TreeCannotTraverseBlob
      Just (Git.TreeEntry t') -> do t'' <- Git.resolveTree t'
                                    doLookupTreeEntry t'' names
      _ -> return Nothing

doModifyTree :: Tree
             -> [Text]
             -> Bool
             -> (Maybe TreeEntry -> GitHubRepository (Maybe TreeEntry))
             -> GitHubRepository (Maybe TreeEntry)
doModifyTree t [] _ _ = return . Just . Git.TreeEntry . Git.Known $ t
doModifyTree t (name:names) createIfNotExist f = do
    -- Lookup the current name in this tree.  If it doesn't exist, and there
    -- are more names in the path and 'createIfNotExist' is True, create a new
    -- Tree and descend into it.  Otherwise, if it exists we'll have @Just
    -- (TreeEntry {})@, and if not we'll have Nothing.
    y' <- doLookupTreeEntry t [name]
    y  <- if isNothing y' && createIfNotExist && not (null names)
          then Just . Git.TreeEntry . Git.Known <$> Git.newTree
          else return y'

    if null names
        then do
        -- If there are no further names in the path, call the transformer
        -- function, f.  It receives a @Maybe TreeEntry@ to indicate if there
        -- was a previous entry at this path.  It should return a 'Left' value
        -- to propagate out a user-defined error, or a @Maybe TreeEntry@ to
        -- indicate whether the entry at this path should be deleted or
        -- replaced with something new.
        --
        -- NOTE: There is no provision for leaving the entry unchanged!  It is
        -- assumed to always be changed, as we have no reliable method of
        -- testing object equality that is not O(n).
        ze <- f y
        liftIO $ modifyIORef (ghTreeContents t) $
            case ze of
                Nothing -> HashMap.delete name
                Just z' -> HashMap.insert name z'
        return ze

        else
        -- If there are further names in the path, descend them now.  If
        -- 'createIfNotExist' was False and there is no 'Tree' under the
        -- current name, or if we encountered a 'Blob' when a 'Tree' was
        -- required, throw an exception to avoid colliding with user-defined
        -- 'Left' values.
        case y of
            Nothing -> return Nothing
            Just (Git.BlobEntry {}) -> failure Git.TreeCannotTraverseBlob
            Just (Git.TreeEntry st') -> do
                st <- Git.resolveTree st'
                ze <- doModifyTree st names createIfNotExist f
                liftIO $ do
                    modifyIORef (ghTreeOid t) (const Nothing)
                    stc <- readIORef (ghTreeContents st)
                    modifyIORef (ghTreeContents t) $
                        if HashMap.null stc
                        then HashMap.delete name
                        else HashMap.insert name (Git.treeEntry st)
                return ze

ghModifyTree :: Tree -> FilePath -> Bool
             -> (Maybe TreeEntry -> GitHubRepository (Maybe TreeEntry))
             -> GitHubRepository (Maybe TreeEntry)
ghModifyTree tree = doModifyTree tree . splitPath

splitPath :: FilePath -> [Text]
splitPath path = T.splitOn "/" text
  where text = case F.toText path of
                 Left x  -> error $ "Invalid path: " ++ T.unpack x
                 Right y -> y

ghWriteTree :: Tree -> GitHubRepository TreeOid
ghWriteTree tree = do
    contents <- liftIO $ readIORef (ghTreeContents tree)
    if HashMap.size contents > 0
        then do
        contents'  <- HashMap.traverseWithKey treeEntryToProxy contents
        treeProxy' <- ghRestful "POST" "git/trees"
                      (GitHubTreeProxy Nothing (HashMap.elems contents'))
        oid <- Git.parseOid (fromJust (ghpTreeOid treeProxy'))
        return (Tagged oid)

        else failure (Git.TreeCreateFailed "Attempt to create an empty tree")

-- data GitHubSignature = GitHubSignature
--     { ghSignatureDate  :: Text
--     , ghSignatureName  :: Text
--     , ghSignatureEmail :: Text } deriving Show

-- parseGhTime :: Text -> UTCTime
-- parseGhTime = fromJust . parseTime defaultTimeLocale "%Y-%m-%dT%H%M%S%z"
--               . T.unpack . T.filter (/= ':')

-- formatGhTime :: UTCTime -> Text
-- formatGhTime t =
--     let fmt   = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%z" t
--         (b,a) = L.splitAt (L.length fmt - 2) fmt
--     in T.pack (b ++ ":" ++ a)
parseGhTime :: Text -> UTCTime
parseGhTime =
    fromJust . parseTime defaultTimeLocale "%Y-%m-%dT%H%M%SZ" . T.unpack

formatGhTime :: UTCTime -> Text
formatGhTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

instance FromJSON Git.Signature where
  parseJSON (Object v) = Git.Signature <$> v .: "name"
                                       <*> v .: "email"
                                       <*> (parseGhTime <$> v .: "date")
  parseJSON _ = mzero

instance ToJSON Git.Signature where
  toJSON (Git.Signature name email date) =
      object [ "name"  .= name
             , "email" .= email
             , "date"  .= formatGhTime date ]

data GitHubCommitProxy = GitHubCommitProxy
    { ghpCommitOid       :: Text
    , ghpCommitAuthor    :: Git.Signature
    , ghpCommitCommitter :: Maybe Git.Signature
    , ghpCommitMessage   :: Text
    , ghpCommitTree      :: GitHubOidProxy
    , ghpCommitParents   :: [GitHubOidProxy]
    } deriving Show

-- The strange thing about commits is that converting them to JSON does not use
-- the "sha" key for the trees and parents:
--
--   { "parents": ["7d1b31e74ee336d15cbd21741bc88a537ed063a0"],
--      "tree": "827efc6d56897b048c772eb4087f854f46256132" }
--
-- But when converting from JSON, it does:
--
-- { "tree": { "sha": "827efc6d56897b048c772eb4087f854f46256132" },
--   "parents": [
--     { "sha": "7d1b31e74ee336d15cbd21741bc88a537ed063a0" }
--   ] }
instance FromJSON GitHubCommitProxy where
  parseJSON (Object v) =
      GitHubCommitProxy <$> v .: "sha"
                        <*> v .: "author"
                        <*> v .:? "committer"
                        <*> v .: "message"
                        <*> v .: "tree"
                        <*> v .: "parents"
  parseJSON _ = mzero

instance ToJSON GitHubCommitProxy where
  toJSON c = object $ [ "author"    .= ghpCommitAuthor c
                      , "message"   .= ghpCommitMessage c
                      , "tree"      .= oidToText (runGhpOid (ghpCommitTree c))
                      , "parents"   .= map (oidToText . runGhpOid)
                                           (ghpCommitParents c)
                      ] <>
                      [ "committer" .= fromJust (ghpCommitCommitter c) |
                                       isJust (ghpCommitCommitter c) ]

proxyToCommit :: GitHubCommitProxy -> Commit
proxyToCommit cp = GitHubCommit
    { ghCommitOid       = Just (Tagged (textToOid (ghpCommitOid cp)))
    , ghCommitAuthor    = ghpCommitAuthor cp
    , ghCommitCommitter = ghpCommitCommitter cp
    , ghCommitMessage   = ghpCommitMessage cp
    , ghCommitTree      = Git.ByOid (Tagged (runGhpOid (ghpCommitTree cp)))
    , ghCommitParents   = map (Git.ByOid . Tagged . runGhpOid)
                              (ghpCommitParents cp)
    }

ghLookupCommit :: CommitOid -> GitHubRepository Commit
ghLookupCommit oid = do
    cp <- ghRestful "GET" ("git/commits/" <> Git.renderOid oid) ()
    return (proxyToCommit cp)

ghCreateCommit :: [CommitRef] -> TreeRef
               -> Git.Signature -> Git.Signature -> Text -> Maybe Text
               -> GitHubRepository Commit
ghCreateCommit parents tree author committer message ref = do
    treeOid <- Git.treeRefOid tree
    commit' <- ghRestful "POST" "git/commits" $ GitHubCommitProxy
                { ghpCommitOid       = ""
                , ghpCommitAuthor    = author
                , ghpCommitCommitter = Just committer
                , ghpCommitMessage   = message
                , ghpCommitTree      = GitHubOidProxy (unTagged treeOid)
                , ghpCommitParents   =
                    map (GitHubOidProxy . unTagged . Git.commitRefOid) parents
                }

    let commit = proxyToCommit commit'
    when (isJust ref) $
        void (ghUpdateRef (fromJust ref)
              (Git.RefObj (Git.ByOid (fromJust (ghCommitOid commit)))))

    return commit

data GitHubObjectRef = GitHubObjectRef
    { objectRefType :: Text
    , objectRefSha  :: Text } deriving Show

instance FromJSON GitHubObjectRef where
  parseJSON (Object v) = GitHubObjectRef <$> v .: "type"
                                         <*> v .: "sha"
  parseJSON _ = mzero

instance ToJSON GitHubObjectRef where
  toJSON c = object $ [ "type" .= objectRefType c
                      , "sha"  .= objectRefSha c ]

data GitHubReference = GitHubReference
    { referenceName   :: Text
    , referenceObject :: GitHubObjectRef } deriving Show

instance FromJSON GitHubReference where
  parseJSON (Object v) = GitHubReference <$> v .: "ref"
                                         <*> v .: "object"
  parseJSON _ = mzero

instance ToJSON GitHubReference where
  toJSON c = object $ [ "ref"    .= referenceName c
                      , "object" .= referenceObject c ]

data GitHubDirectRef = GitHubDirectRef
    { directRefName  :: Maybe Text
    , directRefSha   :: Text
    , directRefForce :: Maybe Bool
    } deriving Show

instance FromJSON GitHubDirectRef where
  parseJSON (Object v) = GitHubDirectRef <$> v .:? "ref"
                                         <*> v .: "sha"
                                         <*> v .:? "force"
  parseJSON _ = mzero

instance ToJSON GitHubDirectRef where
  toJSON c = object $ [ "ref"   .= directRefName c
                      , "sha"   .= directRefSha c
                      , "force" .= directRefForce c ]

ghRefToReference :: GitHubReference -> GitHubRepository Reference
ghRefToReference ref = do
    oid <- Git.parseOid (objectRefSha (referenceObject ref))
    return (Git.Reference (referenceName ref)
                          (Git.RefObj (Git.ByOid (Tagged oid))))

ghLookupRef :: Text -> GitHubRepository (Maybe Reference)
ghLookupRef refName =
    -- jww (2013-02-14): Need to test whether or not the ref exists
    Just <$> (ghRefToReference =<< ghRestful "GET" ("git/" <> refName) ())

ghAllRefs :: GitHubRepository [Reference]
ghAllRefs =
    mapM ghRefToReference =<< ghRestful "GET" "git/refs" ()

ghCreateRef :: Text -> Git.RefTarget GitHubRepository Commit
            -> GitHubRepository Reference
ghCreateRef refName (Git.RefObj commitRef) = do
    let oid = Git.commitRefOid commitRef
    ghRefToReference
        =<< ghRestful "POST" "git/refs"
                     (GitHubDirectRef (Just refName) (Git.renderOid oid)
                                      Nothing)

ghCreateRef _ (Git.RefSymbolic _) =
    error "Not supported"

ghUpdateRef :: Text -> Git.RefTarget GitHubRepository Commit
            -> GitHubRepository Reference
ghUpdateRef refName (Git.RefObj commitRef) = do
    let oid = Git.commitRefOid commitRef
    ghRefToReference =<<
        (ghRestful "PATCH" ("git/" <> refName)
                   (GitHubDirectRef Nothing (Git.renderOid oid) (Just True)))

ghUpdateRef _ (Git.RefSymbolic _) =
    error "Not supported"

ghDeleteRef :: Text -> GitHubRepository ()
ghDeleteRef ref = ghRestful "DELETE" ("git/" <> ref) ref

data GitHubOwner = GitHubUser Text
                 | GitHubOrganization Text
                 deriving (Show, Eq)

data Repository = Repository
    { httpManager :: Maybe Manager
    , gitHubOwner :: GitHubOwner
    , gitHubRepo  :: Github.Repo
    , gitHubToken :: Maybe Text
    }

ghPrefix :: GitHubRepository Text
ghPrefix = do
    repo <- ghGet
    let owner = case gitHubOwner repo of
            GitHubUser name         -> name
            GitHubOrganization name -> name
        name  = Github.repoName (gitHubRepo repo)
    return [st|https://api.github.com/repos/#{owner}/#{name}|]

newtype GitHubRepository a = GitHubRepository
    { runGhRepository :: ReaderT Repository IO a }

instance Functor GitHubRepository where
    fmap f (GitHubRepository x) = GitHubRepository (fmap f x)

instance Applicative GitHubRepository where
    pure = GitHubRepository . pure
    GitHubRepository f <*> GitHubRepository x = GitHubRepository (f <*> x)

instance Monad GitHubRepository where
    return = GitHubRepository . return
    GitHubRepository m >>= f = GitHubRepository (m >>= runGhRepository . f)

instance MonadIO GitHubRepository where
    liftIO m = GitHubRepository (liftIO m)

instance Exception e => Failure e GitHubRepository where
    failure = liftIO . throwIO

ghGet :: GitHubRepository Repository
ghGet = GitHubRepository ask

instance Git.Treeish Tree where
    type TreeRepository Tree = GitHubRepository
    modifyTree = ghModifyTree
    writeTree  = ghWriteTree

instance Git.Commitish Commit where
    type CommitRepository Commit = GitHubRepository
    commitOid       = fromJust . ghCommitOid
    commitParents   = ghCommitParents
    commitTree      = ghCommitTree
    commitAuthor    = ghCommitAuthor
    commitCommitter = \c -> fromMaybe (ghCommitAuthor c) (ghCommitCommitter c)
    commitLog       = ghCommitMessage
    commitEncoding  = const "utf-8"

instance Git.Treeish Commit where
    type TreeRepository Commit = GitHubRepository
    modifyTree c path createIfNotExist f =
        Git.commitTree' c >>= \t -> Git.modifyTree t path createIfNotExist f
    writeTree c = Git.commitTree' c >>= Git.writeTree

withOpenGhRepository :: Repository -> GitHubRepository a -> IO a
withOpenGhRepository repo action = runReaderT (runGhRepository action) repo

withGitHubRepository :: GitHubOwner -> Text -> Maybe Text -> GitHubRepository a
                     -> IO (Either Github.Error a)
withGitHubRepository owner repoName token action =
    let repoName' = if ".git" `T.isSuffixOf` repoName
                    then T.take (T.length repoName - 4) repoName
                    else repoName
    in bracket
       (openOrCreateGhRepository owner repoName' token)
       (\repo -> case repo of
             Left _ -> return ()
             Right _ -> when (isJust token) $ do
             let name = case owner of
                     GitHubUser n -> n
                     GitHubOrganization n -> n
             _ <- Github.deleteRepo
                  (Github.GithubOAuth (T.unpack (fromJust token)))
                  (T.unpack name) (T.unpack repoName')
             return ())
       (\repo -> case repo of
             Left e -> return (Left e)
             Right r -> Right <$> withOpenGhRepository r action)

openGhRepository :: GitHubOwner -> Github.Repo -> Maybe Text -> IO Repository
openGhRepository owner repo token = do
    mgr <- newManager def
    return Repository { httpManager = Just mgr
                      , gitHubOwner = owner
                      , gitHubRepo  = repo
                      , gitHubToken = token }

createGhRepository ::
    GitHubOwner -> Text -> Text -> IO (Either Github.Error Repository)
createGhRepository owner repoName token =
    let auth = Github.GithubOAuth (T.unpack token)
        newr = (Github.newRepo (T.unpack repoName))
                   { Github.newRepoHasIssues = Just False
                   , Github.newRepoAutoInit  = Just True }
    in either (return . Left) confirmCreation =<<
       case owner of
           GitHubUser _ -> Github.createRepo auth newr
           GitHubOrganization name ->
               Github.createOrganizationRepo auth (T.unpack name) newr
  where
    confirmCreation _ = do
        repo <- query (20 :: Int)
        flip (either (return . Left)) repo $ \r -> do
            mgr <- newManager def
            return $ Right $ Repository
                { httpManager = Just mgr
                , gitHubOwner = owner
                , gitHubRepo  = r
                , gitHubToken = Just token }

    query count = do
        -- Poll every five seconds for 100 seconds, waiting for the repository
        -- to be created, since this happens asynchronously on the GitHub
        -- servers.
        repo <- liftIO $ threadDelay 5000000
                >> doesRepoExist owner repoName
        case repo of
            Left l
                | count < 0 -> return (Left l)
                | otherwise -> query (count - 1)
            Right r -> return (Right r)

doesRepoExist :: GitHubOwner -> Text -> IO (Either Github.Error Github.Repo)
doesRepoExist owner repoName =
    case owner of
        GitHubUser name -> do
            Github.userRepo (T.unpack name) (T.unpack repoName)
        GitHubOrganization name -> do
            Github.organizationRepo (T.unpack name) (T.unpack repoName)

openOrCreateGhRepository ::
    GitHubOwner -> Text -> Maybe Text -> IO (Either Github.Error Repository)
openOrCreateGhRepository owner repoName token = do
    exists <- doesRepoExist owner repoName
    case exists of
        Left _ -> case token of
            Just tok -> createGhRepository owner repoName tok
            Nothing  -> return (Left (Github.UserError
                                      "Authentication token not provided"))
        Right r -> Right <$> openGhRepository owner r token

-- GitHub.hs
