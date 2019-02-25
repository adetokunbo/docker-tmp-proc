{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Test.TmpProc.WarpSpec where

import           Test.Hspec

import           Data.Either                (isRight)
import qualified Data.Text                  as Text
import           Network.Wai                (Application)
import           System.Docker.TmpProc
import           System.Docker.TmpProc.Warp (ownerHandle, runServer, serverPort,
                                             shutdown, testWithApplication)

import           Test.SimpleServer            (statusOfGet)
import           Test.TmpProc.Hspec         (noDockerSpec)


mkSpec :: Bool -> TmpProc -> (OwnerHandle -> IO Application) -> Spec
mkSpec noDocker tp mkApp = do
  let name = procImageName tp
      desc = "ServerHandle: a server using " ++ (Text.unpack name)

  if noDocker then noDockerSpec desc else do
    singleSharedServerSpec tp mkApp
    serverPerTestSpec tp mkApp


singleSharedServerSpec :: TmpProc -> (OwnerHandle -> IO Application) -> Spec
singleSharedServerSpec tp mkApp = do
  let name = procImageName tp
      desc = "ServerHandle: a server using " ++ (Text.unpack name)

  beforeAll (runServer [tp] mkApp) $ afterAll shutdown $ do
    describe desc $ do
      context "ownerHandle" $ do
        it "should obtain the process' URI" $ \sh -> do
          (isRight $ procURI name $ ownerHandle sh) `shouldBe` True

        it "should reset the process ok" $ \sh -> do
          reset name (ownerHandle sh) `shouldReturn` ()

      context "port" $ do
        it "should reset the process ok" $ \sh -> do
          statusOfGet (serverPort sh) "test" `shouldReturn` 200


serverPerTestSpec :: TmpProc -> (OwnerHandle -> IO Application) -> Spec
serverPerTestSpec tp mkApp = do
  let name = procImageName tp
      desc = "CPS-style: a server using " ++ (Text.unpack name)

  around (testWithApplication [tp] mkApp) $ do
    describe desc $ do
      context "with the handle" $ do
        it "should obtain the process' URI" $ \(h, _) -> do
          (isRight $ procURI name h) `shouldBe` True

        it "should reset the process ok" $ \(h, _) -> do
          reset name h `shouldReturn` ()

      context "with the port" $ do
        it "should reset the process via the api" $ \(_, p) -> do
          statusOfGet p "test" `shouldReturn` 200
