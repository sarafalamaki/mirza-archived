{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}

module Mirza.SupplyChain.Tests.Client where

import           Control.Exception                     (bracket)

import           Servant.API.BasicAuth

import           Data.Either                           (fromRight, isLeft,
                                                        isRight)
import           Data.UUID                             (nil)

import           Data.Text.Encoding                    (encodeUtf8)

import           Test.Tasty
import           Test.Tasty.Hspec
import           Test.Tasty.HUnit

import qualified Mirza.BusinessRegistry.Types          as BT
import qualified Mirza.SupplyChain.QueryUtils          as QU
import           Mirza.SupplyChain.Types               as ST


import qualified Mirza.BusinessRegistry.Client.Servant as BRClient
import           Mirza.SupplyChain.Client.Servant

import           Mirza.Common.Tests.InitClient         (TestData (..), endApps,
                                                        runApps)
import           Mirza.SupplyChain.Database.Schema     as Schema

import           Mirza.BusinessRegistry.Client.Servant (addPublicKey)
import           Mirza.BusinessRegistry.Tests.Utils    (goodRsaPrivateKey,
                                                        goodRsaPublicKey,
                                                        readRsaPrivateKey,
                                                        readRsaPublicKey)

import           Mirza.Common.Tests.ServantUtils
import           Mirza.Common.Tests.Utils
import           Mirza.SupplyChain.Tests.Dummies

import           Data.GS1.EPC                          (GS1CompanyPrefix (..))
import           Data.GS1.EventId                      as EvId

import           OpenSSL.EVP.Sign                      (signBS)

import qualified Data.ByteString.Char8                 as BS

import qualified Data.ByteString.Base64                as BS64
import           Mirza.SupplyChain.Handlers.Signatures (makeDigest)

-- === SCS Client tests

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
  (encodeUtf8 . newUserPassword                       $ userABC)


userDEF :: NewUser
userDEF = NewUser
  { newUserPhoneNumber = "0400 111 222"
  , newUserEmailAddress = EmailAddress "def@example.com"
  , newUserFirstName = "Biz Johnny"
  , newUserLastName = "Smith Biz"
  , newUserCompany = GS1CompanyPrefix "something"
  , newUserPassword = "re4lly$ecret14!"}

authDEF :: BasicAuthData
authDEF = BasicAuthData
  (encodeUtf8 . getEmailAddress . newUserEmailAddress $ userDEF)
  (encodeUtf8 . newUserPassword                       $ userDEF)

clientSpec :: IO TestTree
clientSpec = do

  let userCreationTests = testCaseSteps "Adding new users" $ \step ->
        -- bracket runSCSApp endWaiApp $ \(_tid,baseurl) -> do
        bracket runApps endApps $ \testData -> do
          let baseurl = scsBaseUrl testData
              http = runClient baseurl

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

  let eventInsertionTests = testCaseSteps "User can add single events" $ \step ->
        bracket runApps endApps $ \testData -> do

          let scsUrl = scsBaseUrl testData
              http = runClient scsUrl

          -- Add a user so that we can authenticate for these tests.
          http (addUser userABC) `shouldSatisfyIO` isRight

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

  let eventSignTests = testCaseSteps "eventSign" $ \step ->
        bracket runApps endApps $ \testData -> do

          let scsUrl = scsBaseUrl testData
              brUrl = brBaseUrl testData
              httpSCS = runClient scsUrl
              httpBR = runClient brUrl
              globalAuthData = brAuthData testData

          step "Adding a new user to SCS"
          httpSCS (addUser userABC) `shouldSatisfyIO` isRight

          step "Adding the same user to BR"
          let prefix = GS1CompanyPrefix "1000001"
          let userBR = BT.NewUser
                          (EmailAddress "abc@example.com")
                          "re4lly$ecret14!"
                          prefix
                          "Biz Johnny"
                          "Smith Biz"
                          "0400 111 222"

          let business = BT.NewBusiness prefix "Business Name"
          httpBR (BRClient.addBusiness globalAuthData business)
            `shouldSatisfyIO` isRight

          httpBR (BRClient.addUser globalAuthData userBR) `shouldSatisfyIO` isRight

          step "Tying the user with a good key"
          goodPubKey <- goodRsaPublicKey
          goodPrivKey <- goodRsaPrivateKey
          keyIdResponse <- httpBR (addPublicKey authABC goodPubKey Nothing)
          keyIdResponse `shouldSatisfy` isRight
          let keyId = fromRight (BRKeyId nil) keyIdResponse

          step "Inserting the object event"
          objInsertionResponse <- httpSCS (insertObjectEvent authABC dummyObject)
          objInsertionResponse `shouldSatisfy` isRight
          let (insertedEvent, (Schema.EventId eventId)) = fromRight (error "Should be right") objInsertionResponse

          step "Signing the key"
          let myDigest = SHA256
          (Just sha256) <- makeDigest myDigest
          mySignBS <- signBS sha256 goodPrivKey $ encodeUtf8 . QU.encodeEvent $ insertedEvent
          let mySign = ST.Signature . BS.unpack . BS64.encode $ mySignBS
          let mySignedEvent = SignedEvent (EvId.EventId eventId) keyId mySign myDigest

          httpSCS (eventSign authABC mySignedEvent) `shouldSatisfyIO` isRight

  let transactionEventTest = testCaseSteps
        "Signing and counter-signing a transaction event" $ \step ->
        bracket runApps endApps $ \testData -> do

          let scsUrl = scsBaseUrl testData
              brUrl = brBaseUrl testData
              httpSCS = runClient scsUrl
              httpBR = runClient brUrl
              globalAuthData = brAuthData testData

          -- ===============================================
          -- Giving user
          -- ===============================================

          step "Adding a giver user to SCS"
          uidGiver <- httpSCS (addUser userABC)
          uidGiver `shouldSatisfy` isRight
          -- let (Right userIdGiver) = uidGiver

          step "Adding business for the Giver"
          let prefixGiver = GS1CompanyPrefix "1000001"
          let businessGiver = BT.NewBusiness prefixGiver "Giver Biz"
          httpBR (BRClient.addBusiness globalAuthData businessGiver)
            `shouldSatisfyIO` isRight

          step "Adding the giver user to BR"
          let userBRGiver = BT.NewUser
                          (EmailAddress "abc@example.com")
                          "re4lly$ecret14!"
                          prefixGiver
                          "Biz Giver"
                          "Smith Biz"
                          "0400 111 222"
          httpBR (BRClient.addUser globalAuthData userBRGiver) `shouldSatisfyIO` isRight

          step "Tying the giver user with a good key"
          goodPubKeyGiver <- readRsaPublicKey "./test/Mirza/Common/TestData/testKeys/goodKeys/4096bit_rsa_key.pub"
          goodPrivKeyGiver <- readRsaPrivateKey "./test/Mirza/Common/TestData/testKeys/goodKeys/4096bit_rsa_key.key"
          keyIdResponseGiver <- httpBR (addPublicKey authABC goodPubKeyGiver Nothing)
          keyIdResponseGiver `shouldSatisfy` isRight
          let keyIdGiver = fromRight (BRKeyId nil) keyIdResponseGiver

          step "Inserting the object event with the giver user"
          objInsertionResponse <- httpSCS (insertObjectEvent authABC dummyObject)
          objInsertionResponse `shouldSatisfy` isRight
          let (insertedEvent, (Schema.EventId eid)) = fromRight (error "Should be right") objInsertionResponse
              eventId = EvId.EventId eid

          step "Signing the key"
          let myDigest = SHA256
          (Just sha256) <- makeDigest myDigest
          mySignBS <- signBS sha256 goodPrivKeyGiver $ encodeUtf8 . QU.encodeEvent $ insertedEvent
          let mySign = ST.Signature . BS.unpack . BS64.encode $ mySignBS
          let mySignedEvent = SignedEvent eventId keyIdGiver mySign myDigest
          httpSCS (eventSign authABC mySignedEvent) `shouldSatisfyIO` isRight

          -- ===============================================
          -- Receiving user
          -- ===============================================
          step "Adding receiving user to SCS"
          uidReceiver <- httpSCS (addUser userDEF)
          uidReceiver `shouldSatisfy` isRight
          let (Right userIdReceiver) = uidReceiver

          step "Adding business for receiver"
          let prefixReceiver = GS1CompanyPrefix "1000002"
          let businessReceiver = BT.NewBusiness prefixReceiver "Receiving Biz"

          httpBR (BRClient.addBusiness globalAuthData businessReceiver)
            `shouldSatisfyIO` isRight

          step "Adding the receiving user to BR"
          let userBRReceiver = BT.NewUser
                          (EmailAddress "def@example.com")
                          "re4lly$ecret14!"
                          prefixReceiver
                          "Biz Receiver"
                          "Smith Biz"
                          "0400 123 432"
          httpBR (BRClient.addUser globalAuthData userBRReceiver) `shouldSatisfyIO` isRight

          step "Checking that the receiver cannot add themselves to the event"
          httpSCS (addUserToEvent authDEF userIdReceiver eventId)
            `shouldSatisfyIO` isLeft

          -- TODO: Add userReceiver to event
          step "Adding receiver to the event using the giver"
          httpSCS (addUserToEvent authABC userIdReceiver eventId)
            `shouldSatisfyIO` isRight

          step "Retrieving the event info"
          eventInfoResult <- httpSCS (eventInfo authABC eventId)
          eventInfoResult `shouldSatisfy` isRight

          step "Checking that we got the correct event back"
          let (Right (Just retrievedEvent)) = eventInfoResult
          retrievedEvent `shouldBe` insertedEvent
          -- TODO: [BLOCKER] EventState should be defined in GS1Combinators
          --                 and added to the Ev.Event type as well

          -- TODO: Check that eventInfo says that the eventState is `AwaitingSignature`
          -- let eventState =
          -- TODO: Sign the event with the second user
          -- TODO: Check that eventInfo says that the eventState is `Signed`


  pure $ testGroup "Supply Chain Service Client Tests"
        [ userCreationTests
        , eventInsertionTests
        , eventSignTests
        , transactionEventTest
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
