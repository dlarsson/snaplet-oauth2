{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
module Snap.Snaplet.OAuth2
    ( -- * Snaplet Definition
      OAuth
    , initOAuth

      -- * Authorization 'Snap.Handler's
    , AuthorizationResult(..)
    , Code
    , AuthorizationGrantError(..)

    -- * 'Client's
    , Client(..)
    , register

      -- * Scope
    , Scope(..)

      -- * Defining Protected Resources
    , protect

      -- * OAuth Backends
    , initInMemoryOAuth
    , OAuthBackend(..)
    ) where


--------------------------------------------------------------------------------
import Control.Applicative ((<$>), (<*>), (<|>))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State.Class (get, gets)
import Control.Monad.Trans (lift)
import Control.Monad ((>=>), guard, when)
import Data.Aeson (Value, (.=), encode, object)
import Data.Maybe (fromMaybe)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Text (Text, pack)
import Data.Time (UTCTime, addUTCTime, getCurrentTime, diffUTCTime)
import Data.Tuple (swap)
import Network.URI (uriQuery)
import Network.URL (importParams, exportParams)


--------------------------------------------------------------------------------
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Error as Error
import qualified Data.ByteString as BS
import qualified Data.IORef as IORef
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Set as Set
import qualified Network.URI as URI
import qualified Snap.Core as Snap
import qualified Snap.Snaplet as Snap
import qualified Snap.Snaplet.Session.Common as Snap

import qualified Snap.Snaplet.OAuth2.AccessToken as AccessToken
import qualified Snap.Snaplet.OAuth2.AuthorizationGrant as AuthorizationGrant

import Snap.Snaplet.OAuth2.Internal

--------------------------------------------------------------------------------
-- | All storage backends for OAuth must implement the following API. See the
-- documentation for each method for various invariants that either MUST or
-- SHOULD be implemented (as defined by RFC-2119).
class OAuthBackend oauth where
    -- | Store an access token that has been granted to a client.
    storeToken :: oauth scope -> AccessToken scope -> IO ()

    -- | Store an authorization grant that has been granted to a client.
    storeAuthorizationGrant :: oauth scope -> AuthorizationGrant scope -> IO ()

    -- | Retrieve an authorization grant from storage for inspection. This is
    -- used to verify an authorization grant for its validaty against subsequent
    -- client requests.
    --
    -- This function should remove the authorization grant from storage entirely
    -- so that subsequent calls to 'inspectAuthorizationGrant' with the same
    -- parameters return 'Nothing'.
    inspectAuthorizationGrant :: oauth scope -> Code -> IO (Maybe (AuthorizationGrant scope))

    -- | Attempt to lookup an access token.
    lookupToken :: oauth scope -> Code -> IO (Maybe (AccessToken scope))

    -- | Try and find a 'Client' by their 'clientId'.
    lookupClient :: oauth scope -> Text -> IO (Maybe Client)

    -- | Register a client.
    storeClient :: oauth scope -> Client -> IO ()


--------------------------------------------------------------------------------
data InMemoryOAuth scope = InMemoryOAuth
  { oAuthGranted :: MVar.MVar (Map.Map Code (AuthorizationGrant scope))
  , oAuthAliveTokens :: IORef.IORef (Map.Map Code (AccessToken scope))
  , oAuthClients :: IORef.IORef (Map.Map Text Client)
  }


--------------------------------------------------------------------------------
instance OAuthBackend InMemoryOAuth where
  storeAuthorizationGrant be grant =
    MVar.modifyMVar_ (oAuthGranted be) $
      return . Map.insert (authGrantCode grant) grant

  inspectAuthorizationGrant be code =
    MVar.modifyMVar (oAuthGranted be) $
      return . swap . Map.updateLookupWithKey (const (const Nothing)) code

  storeToken be token =
    IORef.modifyIORef (oAuthAliveTokens be) (Map.insert (accessToken token) token)

  lookupToken be token =
    Map.lookup token <$> IORef.readIORef (oAuthAliveTokens be)

  lookupClient be id' =
    Map.lookup id' <$> IORef.readIORef (oAuthClients be)

  storeClient be client =
    IORef.modifyIORef (oAuthClients be) (Map.insert (clientId client) client)


--------------------------------------------------------------------------------
-- | The OAuth snaplet. You should nest this inside your application snaplet
-- using 'nestSnaplet' with the 'initOAuth' initializer.
data OAuth scope = forall o. OAuthBackend o => OAuth
  { oAuthBackend :: o scope
  , oAuthRng :: Snap.RNG
  }

--------------------------------------------------------------------------------
-- | The result of an authorization request.
data AuthorizationResult =
    -- | The resource owner is in the process of granting authorization. There
    -- may be multiple page requests to grant authorization (ie, the user
    -- accidently types invalid input, or uses multifactor authentication).
    InProgress

    -- | The request was not approved.
  | Denied

    -- | The resource owner has granted permission.
  | Granted


--------------------------------------------------------------------------------
data AuthorizationGrant scope = AuthorizationGrant
  { authGrantCode :: Code
  , authGrantExpiresAt :: UTCTime
  , authGrantRedirectUri :: URI.URI
  , authGrantClient :: Client
  , authGrantScope :: Set.Set scope
  }


--------------------------------------------------------------------------------
-- | Application-specific definition of scope. Your application should provide
-- an instance of this for a custom data type. For example:
--
-- > data AppScope = Read | Write deriving (Eq, Ord, Show)
-- >
-- > instance Scope AppScope where
-- >   parseScope "read" = return Read
-- >   parseScope "write" = returnWrite
-- >   parseScope _ = mzero
--
-- >   showScope Read = "read"
-- >   showScope Write = "write"
--
-- This type class has the single law that 'parseScope' and 'showScope' should
-- mutual inverses. That is:
--
--   * @'fmap' 'showScope' '.' 'parseScope' = 'Just'@
--
--   * @'parseScope' '.' 'showScope' = 'Just'@
class Ord a => Scope a where
    parseScope :: Text -> Maybe a

    showScope :: a -> Text

    defaultScope :: Maybe [a]
    defaultScope = Nothing


--------------------------------------------------------------------------------
accessTokenToJSON :: MonadIO m => AccessToken scope -> m Value
accessTokenToJSON at = do
    now <- liftIO getCurrentTime
    return $ object
        [ "access_token" .= accessToken at
        , "token_type" .= show (accessTokenType at)
        , "expires_in" .= (floor $ accessTokenExpiresAt at `diffUTCTime` now :: Int)
        , "refresh_token" .= accessTokenRefreshToken at
        ]


--------------------------------------------------------------------------------
data ParameterFailure = MoreThanOne | Missing
  deriving (Enum, Eq, Ord, Show)


--------------------------------------------------------------------------------
requireOne :: BS.ByteString -> Snap.Params
           -> Either ParameterFailure BS.ByteString
requireOne k m = optionalOne k m >>= Error.note Missing


--------------------------------------------------------------------------------
optionalOne :: BS.ByteString
            -> Snap.Params -> Either ParameterFailure (Maybe BS.ByteString)
optionalOne k m = case Map.lookup k m of
        Just [v] -> return $ Just v
        Just (_ : _) -> Left MoreThanOne
        _ -> return Nothing


--------------------------------------------------------------------------------
data AuthorizationGrantError = InvalidRedirectionUri ParameterFailure
                             | InvalidClientId ParameterFailure
                             | MalformedRedirectionUri BS.ByteString
                             | MismatchingRedirectionUri Client
                             | UnknownClient Text
  deriving (Eq, Ord, Show)

--------------------------------------------------------------------------------
authorizationRequest :: Scope scope
                     => (Client -> [scope]
                         -> Snap.Handler b (OAuth scope) AuthorizationResult)
                     -> (Code -> Snap.Handler b (OAuth scope) ())
                     -> (AuthorizationGrantError -> Snap.Handler b (OAuth scope) ())
                     -> Snap.Handler b (OAuth scope) ()
authorizationRequest authSnap genericDisplay displayAuthGrantError =
    Error.eitherT displayAuthGrantError processAuthRequest checkClientValidity

  where

    checkClientValidity = do
        client <- findClient
        redirectUri <- parseRedirectUri
        checkRedirectMatchesClient client redirectUri

        return client

    processAuthRequest client =
        let handleError = redirectError (clientRedirectUri client)
        in Error.eitherT handleError authReqGranted $ do
            mandateCodeResponseType
            scope <- parseReqScope
            verifyWithResourceOwner client scope
            produceAuthGrant client scope

    findClient = do
        reqClientId <- Error.fmapLT InvalidClientId $
            decodeUtf8 <$> queryRequire "client_id"

        client <- lift $ nestBackend $
            \be -> lookupClient be reqClientId
        maybe (Error.left (UnknownClient reqClientId)) return client

    parseRedirectUri = do
        unparsedUri <- Error.fmapLT InvalidRedirectionUri $
            queryRequire "redirect_uri"

        Error.EitherT . return .
            Error.note (MalformedRedirectionUri unparsedUri) $
                parseURI unparsedUri

    checkRedirectMatchesClient client redirectUri =
        when (redirectUri /= clientRedirectUri client) $
            Error.left (MismatchingRedirectionUri client)

    mandateCodeResponseType =
        Error.fmapLT (const AuthorizationGrant.InvalidRequest) $
            discardError (queryRequire "response_type") >>=
                guard . (== "code")

    parseReqScope = Error.EitherT . return . scopeParser =<<
        Error.fmapLT (const AuthorizationGrant.InvalidRequest)
            (queryOptional "scope")

    produceAuthGrant client scope = do
        code <- lift newCSRFToken
        now <- liftIO getCurrentTime
        let authGrant = AuthorizationGrant
                { authGrantCode = code
                , authGrantExpiresAt = addUTCTime 600 now
                , authGrantRedirectUri = clientRedirectUri client
                , authGrantClient = client
                , authGrantScope = scope
                }

        lift $ nestBackend $ \be -> storeAuthorizationGrant be authGrant

        return authGrant

    discardError = Error.fmapLT (const ())

    authReqGranted authGrant =
        let uri = clientRedirectUri $ authGrantClient authGrant
            Just noRedirect = URI.parseURI "urn:ietf:wg:oauth:2.0:oob"
            code = authGrantCode authGrant
        in if uri == noRedirect
            then genericDisplay code
            else augmentedRedirect uri [ ("code", Text.unpack code) ]

    verifyWithResourceOwner client scope = do
      authResult <- lift $ authSnap client (Set.toList scope)
      case authResult of
        Granted    -> Error.right AuthorizationGrant.AccessDenied
        InProgress -> lift $ Snap.getResponse >>= Snap.finishWith
        Denied     -> Error.left AuthorizationGrant.AccessDenied

    redirectError uri oAuthError =
        augmentedRedirect uri
            [ ("error", show oAuthError)
            ]

    augmentedRedirect uri params =
      Snap.redirect $ encodeUtf8 $ pack $ show $ uri
          { uriQuery = ("?" ++) $ exportParams $
                       fromMaybe [] (importParams $ uriQuery uri) ++
                       params }

    queryRequire = withQueryParams . requireOne

    queryOptional = withQueryParams . optionalOne

    withQueryParams f = Error.EitherT $ f <$> Snap.getQueryParams

--------------------------------------------------------------------------------
scopeParser :: Scope scope =>
    Maybe BS.ByteString -> Either AuthorizationGrant.ErrorCode (Set.Set scope)
scopeParser = maybe useDefault (goParse . Text.words . decodeUtf8)

  where

    useDefault = maybe
        (Left AuthorizationGrant.InvalidScope)
        (Right . Set.fromList)
         defaultScope

    goParse scopes =
        let parsed = map parseScope scopes
        in if any Error.isNothing parsed
            then Left AuthorizationGrant.InvalidScope
            else Right (Set.fromList $ Error.catMaybes parsed)

--------------------------------------------------------------------------------
requestToken :: Snap.Handler b (OAuth scope) ()
requestToken = Error.eitherT jsonError success body

  where

    body = do
        mandateGrantType
        grant <- findAuthGrant
        redirectUriMustMatch (authGrantRedirectUri grant)
        client <- findClient
        grant `wasAllocatedTo` client
        grantHasNotExpired grant
        lift (issueAccessToken client (authGrantScope grant))

    mandateGrantType = postRequire "grant_type" >>=
        Error.fmapLT (\() -> AccessToken.UnsupportedGrantType) .
            guard . (== "authorization_code")

    findAuthGrant = do
        reqCode <- decodeUtf8 <$> postRequire "code"

        maybeGrant <- lift (nestBackend $ \be -> inspectAuthorizationGrant be reqCode)
        maybe (Error.left (notFound reqCode)) return maybeGrant

    success = accessTokenToJSON >=> writeJSON

    redirectUriMustMatch expected = do
        redirectUri <- postRequire "redirect_uri" >>=
            Error.EitherT . return . Error.note AccessToken.InvalidRequest . parseURI

        Error.fmapLT (\() -> AccessToken.InvalidGrant) $
            guard (redirectUri == expected)

    findClient = do
        clientReqId <- decodeUtf8 <$> postRequire "client_id"

        client <- lift $ nestBackend $
            \be -> lookupClient be clientReqId

        maybe (Error.left AccessToken.InvalidClient) return client

    grant `wasAllocatedTo` client =
        Error.fmapLT (\() -> AccessToken.InvalidGrant) $
            guard (authGrantClient grant == client)

    grantHasNotExpired grant = do
        now <- liftIO getCurrentTime
        Error.fmapLT (\() -> AccessToken.InvalidGrant) $
            guard (now <= authGrantExpiresAt grant)

    issueAccessToken client scope = do
        token <- newCSRFToken
        now <- liftIO getCurrentTime
        let grantedAccessToken = AccessToken
              { accessToken = token
              , accessTokenType = Bearer
              , accessTokenExpiresAt = 3600 `addUTCTime` now
              , accessTokenRefreshToken = token
              , accessTokenClient = client
              , accessTokenScope = scope
              }

        -- Store the granted access token, handling backend failure.
        nestBackend $ \be -> storeToken be grantedAccessToken

        return grantedAccessToken

    notFound = const AccessToken.InvalidGrant

    jsonError e = Snap.modifyResponse (Snap.setResponseCode 400) >> writeJSON e

    writeJSON j = do
      Snap.modifyResponse $ Snap.setContentType "application/json"
      Snap.writeLBS $ encode j

    postRequire k = Error.fmapLT (const AccessToken.InvalidRequest) $
        Error.EitherT $ requireOne k <$> Snap.getPostParams


--------------------------------------------------------------------------------
nestBackend :: (forall o. (OAuthBackend o) => o scope -> IO a)
            -> Snap.Handler b (OAuth scope) a
nestBackend x = do
    (OAuth be _) <- get
    liftIO (x be)


--------------------------------------------------------------------------------
newCSRFToken :: Snap.Handler b (OAuth scope) Text
newCSRFToken = gets oAuthRng >>= liftIO . Snap.mkCSRFToken


--------------------------------------------------------------------------------
-- | Initialize the OAuth snaplet, providing handlers to do actual
-- authentication, and a handler to display an authorization request token to
-- clients who are not web servers (ie, cannot handle redirections).
initOAuth :: (Scope scope, OAuthBackend backend)
          =>(Client -> [scope] -> Snap.Handler b (OAuth scope) AuthorizationResult)
          -- ^ A handler to perform authorization against the server.
          -> (Code -> Snap.Handler b (OAuth scope) ())
          -- ^ A handler to display an authorization request 'Code' to
          -- clients.
          -> (AuthorizationGrantError -> Snap.Handler b (OAuth scope) ())
          -- ^ A handler to display authorization grant errors that are
          -- so severe they cannot be redirect back to the client
          -- (e.g., the @client-id@ field could not be parsed, thus
          -- there is no client to redirect the error response to).
          -> backend scope
          -- ^ The OAuth backend to use for data storage.
          -> Snap.SnapletInit b (OAuth scope)
initOAuth authSnap genericCodeDisplay authGrantError backend =
  Snap.makeSnaplet "OAuth" "OAuth 2 Authentication" Nothing $ do
    Snap.addRoutes
      [ ("/auth", authorizationRequest authSnap genericCodeDisplay authGrantError)
      , ("/token", requestToken)
      ]

    OAuth backend <$> liftIO Snap.mkRNG


--------------------------------------------------------------------------------
-- | Initialize the in-memory OAuth data store.
initInMemoryOAuth :: Snap.Initializer b v (InMemoryOAuth scope)
initInMemoryOAuth = liftIO $
    InMemoryOAuth <$> MVar.newMVar Map.empty
                  <*> IORef.newIORef Map.empty
                  <*> IORef.newIORef Map.empty

--------------------------------------------------------------------------------
-- | Protect a resource by requiring valid OAuth tokens in the request header
-- before running the body of the handler.
protect :: Scope scope
        => [scope]
        -- ^ The scope that a client must have
        -> Snap.Handler b (OAuth scope) ()
        -- ^ The handler to run on sucessful authentication.
        -> Snap.Handler b (OAuth scope) ()
protect scope h =
    Error.maybeT wwwAuthenticate (const h) $ do
        reqToken <-     authorizationRequestHeader
                    <|> postParameter
                    <|> queryParameter

        token <- Error.MaybeT $ nestBackend $ \be -> lookupToken be reqToken

        now <- liftIO getCurrentTime
        guard (now < accessTokenExpiresAt token)
        guard (Set.fromList scope `Set.isSubsetOf` accessTokenScope token)

  where

    wwwAuthenticate = Snap.modifyResponse $
        Snap.setResponseCode 401 .
        Snap.setHeader "WWW-Authenticate" "Bearer"

    authorizationRequestHeader = do
        ["Bearer", reqToken] <-
            Error.MaybeT $ fmap (take 2 . Text.words . decodeUtf8) <$>
                Snap.withRequest (return . Snap.getHeader "Authorization")
        return reqToken

    decodeAndRequire = fmap decodeUtf8 . Error.MaybeT

    postParameter = decodeAndRequire (Snap.getPostParam "access_token")

    queryParameter = decodeAndRequire (Snap.getQueryParam "access_token")


--------------------------------------------------------------------------------
-- | Register a client.
register :: Client -> Snap.Handler b (OAuth scope) ()
register client = nestBackend $ \be -> storeClient be client


--------------------------------------------------------------------------------
parseURI :: BS.ByteString -> Maybe URI.URI
parseURI = URI.parseURI . Text.unpack . decodeUtf8
