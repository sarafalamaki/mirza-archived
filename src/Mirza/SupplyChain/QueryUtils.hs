{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Following are a bunch of utility functions to do household stuff like
-- generating primary keys, timestamps - stuff that almost every function
-- below would need to do anyway
-- functions that start with `insert` does some database operation
-- functions that start with `to` converts between
-- Model type and its Storage equivalent
module Mirza.SupplyChain.QueryUtils
  (
    storageToModelEvent, userTableToModel
  , constructEventToSign
  , handleError
  , withPKey
  ) where

import           Mirza.Common.Utils
import           Mirza.SupplyChain.Database.Schema as Schema
import           Mirza.SupplyChain.Types           hiding (User (..))
import qualified Mirza.SupplyChain.Types           as ST

import qualified Data.GS1.Event                    as Ev

import           Data.Aeson.Text                   (encodeToLazyText)
import           Data.ByteString                   (ByteString)
import           Data.Text.Encoding                (encodeUtf8)
import qualified Data.Text.Lazy                    as TxtL

import           Database.Beam.Postgres            (PgJSON (..))


-- | Handles the common case of generating a primary key, using it in some
-- transaction and then returning the primary key.
-- @
--   insertFoo :: ArgType -> AppM PrimmaryKeyType
--   insertFoo arg = withPKey $ \pKey -> do
--     runDb ... pKey ...
-- @
withPKey :: MonadIO m => (PrimaryKeyType -> m a) -> m PrimaryKeyType
withPKey f = do
  pKey <- newUUID
  _ <- f pKey
  pure pKey


storageToModelEvent :: Schema.Event -> Ev.Event
storageToModelEvent schemaEvent =
  let (PgJSON event) = Schema.event_json schemaEvent
  in event

-- | Converts a DB representation of ``User`` to a Model representation
-- Schema.User = Schema.User uid bizId fName lName phNum passHash email
userTableToModel :: Schema.User -> ST.User
userTableToModel (Schema.User uid _ fName lName _ _ _)
    = ST.User (ST.UserId uid) fName lName

constructEventToSign :: Ev.Event -> ByteString
constructEventToSign event = encodeUtf8 $ TxtL.toStrict (encodeToLazyText event)
