module IRC
(ircInitialize, messageHandler, ircHandler)
where

import Configuration
import Control.Applicative
import Control.Concurrent.STM.TChan
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.STM
import qualified Control.Monad.State as S
import Data.Maybe
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
	write $ "NICK " ++ ircNick
	write $ "USER " ++ ircUser

messageHandler :: ChildEnv ()
messageHandler = do 
	msgChan <- S.gets messageChannel
	msg <- liftIO $ atomically $ readTChan msgChan 
	case msg of
		JoinMessage channel -> do
			write $ "JOIN " ++ channel	
			write $ "WHO " ++ channel	
			lift $ infoM_ $ "Joined channel " ++ channel
			
		LeaveMessage channel -> do
			write $ "LEAVE " ++ channel
			lift $ infoM_ $ "Left channel " ++ channel

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

-- | Handles WHO replies.
--   Begins by searching for every nick, ignoring any found users.
--   It then inserts the ones not found.
ircAction :: Message -> ChildEnv ()
ircAction (Message _ "352" [_,_,user,host,server,nick,_,real]) = do
	lift $ debugM_ $ "Adding nick: " ++ nick
		++ " host: " ++ host
		++ " server: " ++ server
		++ " user: " ++ user
		++ " real: " ++ real

	exists <- runQuery $ searchNick server host nick
	unless exists $ runQuery $ insertNick server host nick user real
	where
		runQuery q = do
			pipe <- S.gets dbSocket
			lift $ runReaderT q (DatabaseState pipe)

ircAction (Message _ "352" _) = lift $ errorM_ "Read invalid 352 message"

ircAction (Message _ "315" _) = lift (debugM_ "Read end of WHO msg") >> return ()

ircAction (Message prefix "PRIVMSG" params) = do
	if length params /= 2 then
		lift $ errorM_ $ "Received PRIVMSG with length " ++ show (length params)
		else do 

	let (nick, user, host) = getInfo
	lift $ infoM_ $ "Logging msg with (nick, user, host) = " ++
		nick ++ ", " ++ user ++ ", " ++ host
	Valid (_, server) <- S.gets ircHandle
	pipe <- S.gets dbSocket
	lift $ runReaderT 
		(addMsg server (head params) nick (params !! 1)
			>> return ()) --TODO: Don't ignore the result
		(DatabaseState pipe)
			
	where
		getInfo = case prefix of
			Just (NickName nick u h) -> (nick, fromMaybe "" u, fromMaybe "" h)
			_ -> ("", "", "")
		
ircAction (Message _ "PING" params) = do
	lift $ infoM_ $ "Got PING! (" ++ show params ++ ")"
	case params of
		[arg] -> write $ "PONG :" ++ arg
		_ -> lift $ errorM_ "Got invalid PING without argument"

ircAction (Message _ cmd _) = lift $ warningM_ $ "Ignored command: " ++ cmd

write :: String -> ChildEnv ()
write msg = do
	Valid (h, _) <- S.gets ircHandle
	_ <- liftIO $ hPrintf h "%s\r\n" msg
	lift $ debugM_ $ "Sent message: " ++ msg
