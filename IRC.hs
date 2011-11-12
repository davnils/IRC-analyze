module IRC
(ircInitialize, messageHandler, ircHandler)
where

import Configuration as C
import Control.Applicative
import Control.Concurrent.STM.TChan
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.STM
import qualified Control.Monad.State as S
import Data.Maybe
import Data.Time.Clock (getCurrentTime)
import LogWrapper
import Network.IRC.Base
import Network.IRC.Parser
import Prelude hiding (log, catch, lookup, id)
import Storage
import System.IO
import Structures
import Text.Printf

ircInitialize :: ChildEnv ()
ircInitialize = do
        write $ "NICK " ++ C.ircNick
        write $ "USER " ++ C.ircUser

messageHandler :: ChildEnv ()
messageHandler = do
        msgChan <- S.gets messageChannel
        msg <- liftIO $ atomically $ readTChan msgChan
        case msg of
                JoinMessage chan -> do
                        channelExists <- any (== chan) <$> S.gets channels
                        unless channelExists $ do
                        ChildState d h m channels buffer <- S.get
                        S.put $ ChildState d h m (chan:channels) (buffer ++ [chan])
                        write $ "JOIN " ++ chan
                        write $ "WHO " ++ chan
                        lift $ infoM_ $ "Joined channel " ++ chan

                LeaveMessage chan -> do
                        write $ "LEAVE " ++ chan
                        lift $ infoM_ $ "Left channel " ++ chan

                StatsQuery -> do
                        reply <- StatsReply <$> S.gets channels
                        liftIO $ atomically $ writeTChan msgChan reply
                _ -> return ()

ircHandler :: ChildEnv ()
ircHandler = do
        Valid (h, _) <- S.gets ircHandle
        msg <- liftIO $ (printf "%s\n" :: String -> String) <$> hGetLine h
        lift $ debugM_ $ show msg
        let msg' = decode msg
        lift $ debugM_ $ "Received: " ++ show msg'
        case msg' of
                Just m -> ircAction m
                _ -> lift $ errorM_ "Failed to parse IRC message"

-- | Handle WHO replies.
--   Begin by searching for every nick, ignore any found users.
--   Then insert the ones not found.
ircAction :: Message -> ChildEnv ()
ircAction (Message _ "352" [_,_,user,host,server,nick,_,real]) = do
        lift $ debugM_ $ "Adding nick: " ++ nick
                ++ " host: " ++ host
                ++ " server: " ++ server
                ++ " user: " ++ user
                ++ " real: " ++ real

        channel <- head <$> S.gets whoBuffer
        exists <- runQuery $ searchNick server host nick channel
        unless exists $ runQuery $ insertNick server host nick user real channel
        where
                runQuery q = do
                        pipe <- S.gets dbSocket
                        lift $ runReaderT q (DatabaseState pipe)

ircAction (Message _ "352" _) = lift $ errorM_ "Read invalid 352 message"

ircAction (Message _ "315" _) = do
        lift $ debugM_ "Read end of WHO msg"
        S.modify updateBuffer
        where updateBuffer s = s { whoBuffer = tail $ whoBuffer s}

ircAction (Message prefix "PRIVMSG" [channel,message]) = do
        let (nick, user, host) = getInfo
        lift $ infoM_ $ "Logging msg with (nick, user, host) = " ++
                nick ++ ", " ++ user ++ ", " ++ host
        Valid (_, server) <- S.gets ircHandle
        pipe <- S.gets dbSocket
        lift $ runReaderT
                (addMsg server channel nick message)
                (DatabaseState pipe)

        where
                getInfo = case prefix of
                        Just (NickName nick u h) ->
                                (nick, fromMaybe "" u, fromMaybe "" h)
                        _ -> ("", "", "")

ircAction (Message _ "PING" params) = do
        lift $ debugM_ $ "Got PING! (" ++ show params ++ ")"
        case params of
                [arg] -> write $ "PONG :" ++ arg
                _ -> lift $ errorM_ "Got invalid PING without argument"

ircAction (Message (Just (NickName nick _ _)) "JOIN" [channel]) = do
        Valid (h, _) <- S.gets ircHandle
        _ <- liftIO $ hPrintf h "WHO %s\r\n" nick
        S.modify updateBuffer
        lift $ debugM_ "Sent WHO query after join"
        where updateBuffer s = s { whoBuffer = whoBuffer s ++ [channel]}

ircAction (Message (Just (NickName nick _ _)) "PART" [channel]) = do
        lift $ debugM_ $ "Received PART message from " ++ nick
        time <- liftIO getCurrentTime
        Valid (_, server) <- S.gets ircHandle
        pipe <- S.gets dbSocket
        lift $ runReaderT
                (removeActivity server channel nick time)
                (DatabaseState pipe)

-- TODO: Support QUIT-messages

ircAction (Message _ cmd _) = lift $ warningM_ $ "Ignored command: " ++ cmd

write :: String -> ChildEnv ()
write msg = do
        Valid (h, _) <- S.gets ircHandle
        _ <- liftIO $ hPrintf h "%s\r\n" msg
        lift $ debugM_ $ "Sent message: " ++ msg
