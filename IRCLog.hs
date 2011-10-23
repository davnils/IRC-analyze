module Main
where

import Configuration
import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM.TChan
import qualified Data.Map as M
import Control.Exception
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.STM
import qualified Control.Monad.State as S
import Data.Maybe
import Database.MongoDB
import LogWrapper
import Network
import Network.IRC.Base
import Network.IRC.Parser
import Prelude hiding (log, catch, lookup, id)
import qualified Prelude as P
import Storage
import Structures
import System.IO
import System.Log.Formatter
import System.Log.Logger
import System.Log.Handler.Simple
import System.Log.Handler (setFormatter)
import Text.Printf

main :: IO ()
main = runReaderT run $ LoggerState "main"

run :: LoggerEnv ()
run = do
	logFile <- io $ fileHandler "log" DEBUG >>=  \h -> return $
		setFormatter h (simpleLogFormatter "[$prio] $msg")
	io $ updateGlobalLogger rootLoggerName $ addHandler logFile 
	io $ updateGlobalLogger rootLoggerName $ setLevel DEBUG
	infoM_ "Initializing"
	pool <- createPool
	S.runStateT shell $ ServerState pool M.empty
	infoM_ "Shutting down"
	closePool pool

shell :: ServerEnv()
shell = do
	(cmd:tail) <- liftIO $ words <$> (putStr "> " >> getLine)
	act cmd tail 
	unless (cmd == "quit") shell

act :: String -> [String] -> ServerEnv ()
act "quit" _ = return ()
act "add" [server, channel] = do
	-- Create a thread if one doesn't exist for this server.
	-- Message the associated thread with a JoinAction construct.
	-- TODO: lookup channels.. (put it in a state monad)
	connected <- M.member server <$> S.gets childs
	pipe <- if connected then do
			Just x <- M.lookup server <$> S.gets childs
			return x
		else fst <$> launchThread server
	S.modify $ \(ServerState p c) ->
		ServerState p $ M.insert server pipe c 
	liftIO $ atomically $ writeTChan pipe $ JoinMessage channel

act _ _ = return ()

-- TODO: act "remove" server channel pool = undefined

launchThread :: String -> ServerEnv (TChan ChannelMessage, String)
launchThread server = do
	pool <- S.gets pool
	chan <- liftIO newTChanIO :: ServerEnv (TChan ChannelMessage)
	let build x = ChildState (pipe x) Invalid chan []
	Just env <- lift $ getEnv pool >>= \x -> return $ fmap build x
	r <- ask
	-- TODO: Clean up using forkable-monad
	liftIO $ forkIO $ runReaderT (S.runStateT (worker server) env) r >> return ()
	return (chan, server)

worker :: String -> ChildEnv ()
worker server = do
	h <- liftIO $ connectTo server $ PortNumber 6667
	liftIO $ hSetBuffering h NoBuffering
	S.modify $ \(ChildState db _ c _) -> ChildState db (Valid (h, server)) c []
	
	write $ "NICK " ++ ircNick
	write $ "USER " ++ ircUser
	forever workerLoop
	liftIO $ hClose h

workerLoop :: ChildEnv ()
workerLoop = do
	--Any Input available on the IRC socket?
	--TODO: Catch any exception -> disconnected (use try with a fitting exp)
	Valid (h, _) <- S.gets ircHandle
	liftIO (hReady h) >>= run ircHandler
	-- Read messages from channel
	chan <- S.gets messageChannel
	liftIO (atomically $ isEmptyTChan chan) >>= run' messageHandler
	where
		run = flip when
		run' = flip unless

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
ircAction (Message _ "352" [_,_,user,host,server,nick,_,real]) = do
	let real' = words real !! 2
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
			Nothing -> ("", "", "")
		
ircAction (Message _ "PING" params) = do
	lift $ infoM_ $ "Got PING! (" ++ show params ++ ")"
	case params of
		[arg] -> write $ "PONG :" ++ arg
		_ -> lift $ errorM_ "Got invalid PING without argument"

ircAction (Message _ cmd _) = lift $ warningM_ $ "Ignored command: " ++ cmd

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

write :: String -> ChildEnv ()
write msg = do
	Valid (h, _) <- S.gets ircHandle
	liftIO $ hPrintf h "%s\r\n" msg
	lift $ debugM_ $ "Sent message: " ++ msg
