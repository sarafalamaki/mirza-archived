module Mirza.BusinessRegistry.Tests.Utils where

import           Crypto.JOSE (JWK)
import           Data.Aeson  (decodeFileStrict)

-- Read a JWK key from file (either prubli or private).
readJWK :: FilePath -> IO (Maybe JWK)
readJWK = decodeFileStrict

-- Gets a good PEM RSA key from file to use from test cases.
goodRsaPublicKey :: IO (Maybe JWK)
goodRsaPublicKey = readJWK "./test/Mirza/Common/TestData/testKeys/goodJWKs/4096bit_rsa_pub.json"

-- Gets a good PEM RSA private key from file to use from test cases.
goodRsaPrivateKey :: IO (Maybe JWK)
goodRsaPrivateKey = readJWK "./test/Mirza/Common/TestData/testKeys/goodJWKs/4096bit_rsa.json"

-- | Converts from number of seconds to the number of microseconds.
secondsToMicroseconds :: (Num a) => a -> a
secondsToMicroseconds = (* 1000000)
