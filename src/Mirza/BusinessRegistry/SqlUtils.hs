module Mirza.BusinessRegistry.SqlUtils
  (
    Utils.handleError
  , handleSqlUniqueViloation
  ) where


import           Mirza.BusinessRegistry.Types      as BT
import qualified Mirza.Common.Utils                as Utils

import           Database.PostgreSQL.Simple        (SqlError (..))
import           Database.PostgreSQL.Simple.Errors (ConstraintViolation (UniqueViolation),
                                                    constraintViolation)

import           Control.Lens                      (( # ), (^?))

import           Control.Monad.Except              (catchError, throwError)

import           Data.ByteString



handleSqlUniqueViloation  :: (AsSqlError err, AsBusinessRegistryError err, MonadError err m, MonadIO m)
                          => ByteString        -- ^ UniqueViolation name.
                          -> (SqlError -> err) -- ^ A function which takes the original SQL error for the
                                               --   UniqueViolation and turns it into the error that is thrown
                                               --   when the UniqueViolation name is matched.
                          -> err               -- ^ The error that we are catching.
                          -> m a
handleSqlUniqueViloation = Utils.handleSqlUniqueViloationTemplate (_UnmatchedUniqueViolationBRE #)
