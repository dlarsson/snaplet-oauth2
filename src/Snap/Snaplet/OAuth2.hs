{-# LANGUAGE OverloadedStrings #-}
module Snap.Snaplet.OAuth2
       ( -- * Snaplet Definition
         OAuth
       , oAuthInit

         -- * Authorization Handlers
       , AuthorizationResult(..)
       , AuthorizationRequest
       , authReqClientId, authReqRedirectUri
       , authReqScope, authReqState

         -- * Defining Protected Resources
       , protect
       ) where

import Control.Applicative ((<$>), (<*>), (<*), pure)
import Control.Error.Util
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader
import Control.Monad.State.Class (gets)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Either
import Data.Aeson (ToJSON(..), encode, (.=), object)
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map as Map
import qualified Data.Text as Text
import Data.IORef
import Data.Text (Text, pack)
import Data.Text.Encoding (decodeUtf8)
import Snap.Core
import Snap.Snaplet
import Snap.Snaplet.Session.Common

--------------------------------------------------------------------------------
-- | The type of both authorization request tokens and access tokens.
type Code = Text

--------------------------------------------------------------------------------
{-| The OAuth snaplet. You should nest this inside your application snaplet
using 'nestSnaplet' with the 'oAuthInit' initializer. -}
data OAuth = OAuth
  { oAuthGranted :: IORef (Map.Map Code AuthorizationRequest)
  , oAuthRng :: RNG
  }

--------------------------------------------------------------------------------
{-| The result of an authorization request. -}
data AuthorizationResult =
    {-| The resource owner is in the process of granting authorization. There
may be multiple page requests to grant authorization (ie, the user accidently
types invalid input, or uses multifactor authentication). -}
    InProgress

    -- | The request was not approved. The associated string indicates why.
  | Failed String

    -- | Authorization succeeded.
  | Success

--------------------------------------------------------------------------------
-- | Information about an authorization request from a client.
data AuthorizationRequest = AuthorizationRequest
  { -- | The client's unique identifier.
    authReqClientId :: Text

    {-| The (optional) redirection URI to redirect to on success. The OAuth
snaplet will take care of this redirection; you do not need to perform the
redirection yourself. -}
  , authReqRedirectUri :: Maybe BS.ByteString

    -- | The scope of authorization requested.
  , authReqScope :: Maybe Text

    {-| Any state the client wishes to be associated with the authorization
request. -}
  , authReqState :: Maybe Text
  }

--------------------------------------------------------------------------------
data AccessTokenRequest = AccessTokenRequest
  { accessTokenCode :: Code
  , accessTokenRedirect :: Maybe BS.ByteString
  }

--------------------------------------------------------------------------------
data AccessToken = AccessToken
  { accessToken :: Code
  , accessTokenType :: AccessTokenType
  , accessTokenExpiresIn :: Int
  , accessTokenRefreshToken :: Code
  }

--------------------------------------------------------------------------------
data AccessTokenType = Example | Bearer
  deriving (Show)

--------------------------------------------------------------------------------
instance ToJSON AccessToken where
  toJSON at = object [ "access_token" .= accessToken at
                     , "token_type" .= show (accessTokenType at)
                     , "expires_in" .= show (accessTokenExpiresIn at)
                     , "refresh_token" .= accessTokenRefreshToken at
                     ]

--------------------------------------------------------------------------------
authorizationRequest :: (AuthorizationRequest -> Handler b OAuth AuthorizationResult)
                     -> (Code -> Handler b OAuth ())
                     -> Handler b OAuth ()
authorizationRequest authHandler genericDisplay =
  runParamParser getQueryParams parseAuthorizationRequestParameters $ \authReq -> do
    authResult <- authHandler authReq
    case authResult of
      Success -> do
        code <- newCSRFToken
        gets oAuthGranted >>= \codes -> liftIO $ modifyIORef codes (Map.insert code authReq)
        case authReqRedirectUri authReq of
          Just "urn:ietf:wg:oauth:2.0:oob" -> genericDisplay code
          Nothing -> genericDisplay code
          Just uri -> error "Redirect to a URI is not yet supported"
      InProgress -> return ()

requestToken :: Handler b OAuth ()
requestToken =
  runParamParser getPostParams parseTokenRequestParameters $ \tokenReq -> do
    req' <- Map.lookup (accessTokenCode tokenReq) <$> (gets oAuthGranted >>= liftIO . readIORef)
    case req' of
      Nothing -> do
        modifyResponse (setResponseCode 400)
        writeText $ Text.append (pack "Authorization request not found: ") (accessTokenCode tokenReq)
      Just req ->
        case authReqRedirectUri req == accessTokenRedirect tokenReq of
          True -> do
            token <- newCSRFToken
            let grantedAccessToken = AccessToken
                  { accessToken = token
                  , accessTokenType = Bearer
                  , accessTokenExpiresIn = 3600
                  , accessTokenRefreshToken = token
                  }
            writeLBS $ encode grantedAccessToken

newCSRFToken :: Handler b OAuth Text
newCSRFToken = gets oAuthRng >>= liftIO . mkCSRFToken

--------------------------------------------------------------------------------
-- | Initialize the OAuth snaplet, providing handlers to do actual
-- authentication, and a handler to display an authorization request token to
-- clients who are not web servers (ie, cannot handle redirections).
oAuthInit :: (AuthorizationRequest -> Handler b OAuth AuthorizationResult)
          -- ^ A handler to perform authorization against the server.
          -> (Code -> Handler b OAuth ())
          -- ^ A handler to display an authorization request 'Code' to clients.
          -> SnapletInit b OAuth
oAuthInit authHandler genericCodeDisplay =
  makeSnaplet "OAuth" "OAuth 2 Authentication" Nothing $ do
    addRoutes [ ("/auth", authorizationRequest authHandler genericCodeDisplay)
              , ("/token", requestToken)
              ]
    codeStore <- liftIO $ newIORef Map.empty
    rng <- liftIO mkRNG
    return $ OAuth codeStore rng

--------------------------------------------------------------------------------
-- | Protect a resource by requiring valid OAuth tokens in the request header
-- before running the body of the handler.
protect :: Handler b OAuth ()
        -- ^ A handler to run if the client is /not/ authorized
        -> Handler b OAuth ()
        -- ^ The handler to run on sucessful authentication.
        -> Handler b OAuth ()
protect failure h = do
  authHead <- fmap (take 2 . BS.words) <$> withRequest (return . getHeader "Authorization")
  case authHead of
    Just ["Bearer", token] -> h
    _ -> failure

--------------------------------------------------------------------------------
{-
Parameter parsers are a combination of 'Reader'/'EitherT' monads. The environment
is a 'Params' map (from Snap), and 'EitherT' allows us to fail validation at any
point. Combinators 'require' and 'optional' take a parameter key, and a
validation routine.
-}

type ParameterParser a = EitherT String (Reader Params) a

param :: String -> ParameterParser (Maybe BS.ByteString)
param p = fmap head . Map.lookup (BS.pack p) <$> lift ask

require :: String -> (BS.ByteString -> Bool) -> String -> ParameterParser BS.ByteString
require name predicate e = do
  v <- param name >>= noteT (name ++ " is required") . liftMaybe
  unless (predicate v) $ left e
  return v

optional :: String -> (BS.ByteString -> Bool) -> String -> ParameterParser (Maybe BS.ByteString)
optional name predicate e = do
  v <- param name
  case v of
    Just v' -> if predicate v' then return v else left e
    Nothing -> return Nothing

parseAuthorizationRequestParameters :: ParameterParser AuthorizationRequest
parseAuthorizationRequestParameters = pure AuthorizationRequest
  <*  require "response_type" (== "code") "response_type must be code"
  <*> fmap decodeUtf8 (require "client_id" (const True) "")
  <*> optional "redirect_uri" validRedirectUri
        "redirect_uri must be an absolute URI and not contain a fragment component"
  <*> fmap (fmap decodeUtf8) (optional "scope" validScope "")
  <*> fmap (fmap decodeUtf8) (optional "state" (const True) "")

parseTokenRequestParameters :: ParameterParser AccessTokenRequest
parseTokenRequestParameters = pure AccessTokenRequest
  <*  require "grant_type" (== "authorization_code") "grant_type must be authorization_code"
  <*> fmap decodeUtf8 (require "code" (const True) "")
  <*> optional "redirect_uri" validRedirectUri
        "redirect_uri must be an absolute URI and not contain a fragment component"

validRedirectUri _ = True
validScope _  = True

runParamParser :: Handler b OAuth Params -> ParameterParser a -> (a -> Handler b OAuth ()) -> Handler b OAuth ()
runParamParser params parser handler = do
  qps <- params
  case runReader (runEitherT parser) qps of
    Left e -> writeText $ pack e
    Right a -> handler a
