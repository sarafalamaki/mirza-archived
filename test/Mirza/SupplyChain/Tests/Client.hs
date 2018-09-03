{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}

module Mirza.SupplyChain.Tests.Client where

import           Mirza.SupplyChain.Tests.Settings

import           Control.Concurrent               (ThreadId, forkIO, killThread)
import           Control.Exception                (bracket)
import           System.IO.Unsafe                 (unsafePerformIO)

import qualified Network.HTTP.Client              as C
import           Network.Socket
import qualified Network.Wai                      as Wai
import           Network.Wai.Handler.Warp

import           Servant.API.BasicAuth
import           Servant.Client

import           Data.Either                      (isLeft, isRight)
import           Data.Text.Encoding               (encodeUtf8)

import           Test.Tasty.Hspec
import           Test.Tasty
import           Test.Tasty.HUnit

import           Mirza.SupplyChain.Main           (ServerOptions (..),
                                                   initApplication,
                                                   initSCSContext)
import           Mirza.SupplyChain.Types

import           Data.GS1.EPC                     (GS1CompanyPrefix (..))

import           Mirza.SupplyChain.Client.Servant

import           Katip                            (Severity (DebugS))
import           Mirza.SupplyChain.Tests.Dummies

import           Database.Beam.Query              (delete, runDelete, val_)
import           Mirza.SupplyChain.Database.Schema


-- Cribbed from https://github.com/haskell-servant/servant/blob/master/servant-client/test/Servant/ClientSpec.hs

-- === Servant Client tests

shouldSatisfyIO :: (HasCallStack, Show a, Eq a) => IO a -> (a -> Bool) -> Expectation
action `shouldSatisfyIO` p = action >>= (`shouldSatisfy` p)

userABC :: NewUser
userABC = NewUser
  { newUserPhoneNumber = "0400 111 222"
  , newUserEmailAddress = EmailAddress "abc@example.com"
  , newUserFirstName = "Biz Johnny"
  , newUserLastName = "Smith Biz"
  , newUserCompany = GS1CompanyPrefix "something"
  , newUserPassword = "re4lly$ecret14!"}

authABC :: BasicAuthData
authABC = BasicAuthData
  (encodeUtf8 . getEmailAddress . newUserEmailAddress $ userABC)
  (encodeUtf8 . newUserPassword                      $ userABC)

runApp :: IO (ThreadId, BaseUrl)
runApp = do
  ctx <- initSCSContext so
  startWaiApp =<< initApplication so ctx

so :: ServerOptions
so = ServerOptions Dev False testDbConnStr "127.0.0.1" 8000 14 8 1 DebugS

clientSpec :: IO TestTree
clientSpec = do
  ctx <- initSCSContext so

  flushDbResult <- runAppM @_ @ServiceError ctx $ runDb $ do
      let deleteTable table = pg $ runDelete $ delete table (const (val_ True))
      deleteTable $ _users supplyChainDb
      deleteTable $ _users supplyChainDb
      deleteTable $ _businesses supplyChainDb
      deleteTable $ _contacts supplyChainDb
      deleteTable $ _labels supplyChainDb
      deleteTable $ _what_labels supplyChainDb
      deleteTable $ _items supplyChainDb
      deleteTable $ _transformations supplyChainDb
      deleteTable $ _locations supplyChainDb
      deleteTable $ _events supplyChainDb
      deleteTable $ _whats supplyChainDb
      deleteTable $ _biz_transactions supplyChainDb
      deleteTable $ _whys supplyChainDb
      deleteTable $ _wheres supplyChainDb
      deleteTable $ _whens supplyChainDb
      deleteTable $ _label_events supplyChainDb
      deleteTable $ _user_events supplyChainDb
      deleteTable $ _signatures supplyChainDb
      deleteTable $ _hashes supplyChainDb
      deleteTable $ _blockchain supplyChainDb
  flushDbResult `shouldSatisfy` isRight


  let userCreationTests = testCaseSteps "Adding new users" $ \step ->
        bracket runApp endWaiApp $ \(_tid,baseurl) -> do
          let http = runClient baseurl

          let user1 = userABC
              user2 = userABC {newUserEmailAddress= EmailAddress "different@example.com"}
              -- Same email address as user1 other fields different.
              userSameEmail = userABC {newUserFirstName="First"}

          step "Can create a new user"
          http (addUser user1)
            `shouldSatisfyIO` isRight

          step "Can't create a new user with the same email address"
          http (addUser userSameEmail)
            `shouldSatisfyIO` isLeft

          step "Can create a second user"
          http (addUser user2)
            `shouldSatisfyIO` isRight

          step "Should be able to authenticate"
          http (contactsInfo authABC)
            `shouldSatisfyIO` isRight

          step "Should fail to authenticate with unknown user"
          http (contactsInfo (BasicAuthData "xyz@example.com" "notagoodpassword"))
            `shouldSatisfyIO` isLeft

  let eventInsertionTests = testCaseSteps "User can add events" $ \step ->
        bracket runApp endWaiApp $ \(_tid,baseurl) -> do
          let http = runClient baseurl
          step "User Can insert Object events"
            -- TODO: Events need their EventId returned to user
          http (insertObjectEvent authABC dummyObject)
            `shouldSatisfyIO` isRight

          step "User Can insert Aggregation events"
          http (insertAggEvent authABC dummyAggregation)
            `shouldSatisfyIO` isRight

          step "User Can insert Transaction events"
          http (insertTransactEvent authABC dummyTransaction)
            `shouldSatisfyIO` isRight

          step "User Can insert Transformation events"
          http (insertTransfEvent authABC dummyTransformation)
            `shouldSatisfyIO` isRight
          step "Provenance of a labelEPC"
          http (insertTransfEvent authABC dummyTransformation)
            `shouldSatisfyIO` isRight
  pure $ testGroup "Supply Chain Service Client Tests"
        [ userCreationTests
        , eventInsertionTests
        ]

{-
Check Provenance of a labelEPC
where I've used head, you need to use map to actually do it for all elements in the list. I've just done one element for illustrative purposes.
eventList ← listEvents <labelEPC>
let event = head eventList
eventInfo ← eventInfo(eventID)
(sig, uid) = head (signatures eventInfo)
publicKey ← getPublicKey uid
assert $ decrypt(sig, publicKey) == (joseText eventInfo)

Insert an ObjectEvent
Create an ObjectEvent
add it via the API
sign it
Insert an AggregationEvent
Create an aggregation event
add it
sign it

Insert an TransformationEvent
Create an transformation event
add it
sign it

Sign AND countersign a TransactionEvent
(eventID, joseTxt) ← insertTransactionEvent transactionEvent
signedEvent = sign(joseTxt, privKey)
sign(signedEvent)
addUserToEvent(user2ID, eventID)
.. then user2 does the same thing with their priv key, and sends it using the "event/sign" api call.

Check for tampering by comparing to Blockchain hash
eventInfo ← eventInfo(eventID)
joseTxt = joseText eventInfo
expectedHash = hash joseText
blockchainID = blockchainID eventInfo
bcHash = getBlockchainHash(blockchainID)
assert (bcHash == expectedHash)
Get all events that relate to a labelEPC
eventList ← listEvents <labelEPC>
subEvents eventList = [e | e ← eventList, if
(eventType e == aggregationEvent || eventType e == transformationEvent)
then (map subEvents $ map listEvents (getSubEPCs e)]
Keys
add, get, getInfo public key
revoke public key
..these will be moved into the registery soon.
Contacts
Add, remove and search for contacts.


-}


-- Plumbing

startWaiApp :: Wai.Application -> IO (ThreadId, BaseUrl)
startWaiApp app = do
    (prt, sock) <- openTestSocket
    let settings = setPort prt defaultSettings
    thread <- forkIO $ runSettingsSocket settings sock app
    return (thread, BaseUrl Http "localhost" prt "")


endWaiApp :: (ThreadId, BaseUrl) -> IO ()
endWaiApp (thread, _) = killThread thread

openTestSocket :: IO (Port, Socket)
openTestSocket = do
  s <- socket AF_INET Stream defaultProtocol
  localhost <- inet_addr "127.0.0.1"
  bind s (SockAddrInet aNY_PORT localhost)
  listen s 1
  prt <- socketPort s
  return (fromIntegral prt, s)



{-# NOINLINE manager' #-}
manager' :: C.Manager
manager' = unsafePerformIO $ C.newManager C.defaultManagerSettings

runClient :: BaseUrl -> ClientM a -> IO (Either ServantError a)
runClient baseUrl' x = runClientM x (mkClientEnv manager' baseUrl')
