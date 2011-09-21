--let s f = runAction (use (Database $ u "irc") f) (Safe []) Master p'
{-# LANGUAGE OverloadedStrings #-}

module Storage
(createPool, closePool, getEnv, log, runOnDatabase,
addMsg, searchNick, insertNick)
where
import qualified Configuration as C
import Control.Applicative
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.Trans.Maybe
import Control.Exception (catch, IOException, evaluate, SomeException, throw)
import Data.Int
import qualified Data.ByteString.Char8 as L
import Data.Maybe
import qualified Data.Set as S
import Data.Time.Clock (UTCTime(..), utctDay, getCurrentTime, secondsToDiffTime)
import Data.Time.Calendar (toModifiedJulianDay, Day(..))
import Database.MongoDB
import LogWrapper
import Network.IRC
import Prelude hiding (log, catch, lookup, id)
import qualified Prelude as P
import Structures
import System.Log.Logger

maximumTCPConnections = 1

log :: LoggerEnv a -> DatabaseEnv a
log = lift

bracket_ :: Monad m => m a -> m b -> m c -> m c
bracket_ a b c = a >> c >>= (\x -> b >> return x)

createPool :: LoggerEnv (ConnPool Host)
createPool = bracket_
		(infoM_ $ "Creating connection pool to address: " ++ C.host)
		(infoM_ $ "Pool created")
		(io $ newConnPool maximumTCPConnections $ host C.host)

closePool :: ConnPool Host -> LoggerEnv ()
closePool pool = do
	infoM_ "Closing connection pool"
	io $ killPipes pool

getEnv :: ConnPool Host -> LoggerEnv (Maybe DatabaseState)
getEnv pool = do
	pipe <- io $ runErrorT $ getPipe Master pool
	case pipe of
		Right p -> 
			return $ Just $ DatabaseState p
		Left a -> errorM_ "Failed to connect to database" >> return Nothing 

runOnDatabase db f = do
		p <- asks pipe
		log . io $ runAction (use (Database $ db) f) (Safe []) Master p

-- | addMsg lookups the corresponding id and inserts the message.
addMsg :: ServerName -> Channel -> UserName -> String -> DatabaseEnv ()
addMsg server channel nick msg = do
	log $ debugM_ "Adding message"
	let query = ["nick" =: nick, "ircserver" =: (getNetwork server)]
	record <- transferTo <$> (`IRCMessage` msg) <$> liftIO getCurrentTime

	--TODO: Check if an open log record exists (like a filter in the select)
	res <- runOnDatabase "irc" $ 
		modify (select query "data") ["$push" =: ["messages" =: record]]
		--TODO: logs.find(end == 0) => en träff

        case res of
                Left e -> log (errorM_ "Failed to add message") >> throw Critical
		_ -> return ()
	{-lift $ debugM_ $ "docs is of length: " ++ show (length loaded)
	--find (select query "data") >>= rest

        let translated = fromMaybe [] (mapM transferFrom loaded) :: [Entry]

	success <- case length translated of
		0 -> log $ errorM_ "Failed to find an id" >> throw Critical
		1 -> log $ debugM_ "Found an id" >> return True
		_ -> log $ errorM_ "Multiple id:s returned" >> throw Critical
	
	let user = head translated

	--if (not . existsOpenSlot . logs . head) translated then return False else do
	lift $ debugM_ $ "existsOpenSlot gives: " ++ show (existsOpenSlot $ logs $ head translated)
	lift $ debugM_ $ "Dump of contents: " ++ (show $ head translated)

	input <- (`IRCMessage` msg) <$> liftIO getCurrentTime
	res <- runOnDatabase "irc" $ 
		insert "data" $ transferTo input
	case res of
		Left e -> log (errorM_ $ "Failed to add message, error: " ++ show e) >> throw Critical
		Right id -> log (debugM_ $ "Added message with id: " ++ show id) >> return True-}

getNetwork :: String -> String
getNetwork = tail . dropWhile (/= '.') 

existsOpenSlot :: [Activity] -> Bool
existsOpenSlot [] = False
existsOpenSlot (e:tail) 
	| end e == infiniteTime = True 
	| otherwise = existsOpenSlot tail
--any (\log -> end log == infiniteTime)

infiniteTime :: UTCTime
infiniteTime = UTCTime (ModifiedJulianDay 0) 0

-- | Search for the given server/nick and return true if an active session exists.
searchNick :: ServerName -> String -> UserName -> DatabaseEnv Bool
searchNick server host nick = do
	log $ debugM_ $ "Searching for nick: " ++ nick
	-- TODO: use Regex type as defined in BSON library
	let filterQuery = ["nick" =: nick, "ircserver" =: (getNetwork server), "hostname" =: host]
	res <- runOnDatabase "irc" $ 
                find (select filterQuery "data") >>= rest
        user <- case res of
                Left e -> log (errorM_ "Failed to search for nick") >> throw Critical
		Right docs -> return docs

        let translated = fromMaybe [] (mapM transferFrom user) :: [Entry]
	if null translated then return False else do

	-- Check if there exists an active Activity record. If not, add one.
	if (existsOpenSlot . logs . head) translated then 
		lift (debugM_ "Found an active Activity record") >> return True
		else do

	lift $ debugM_ $ "Contents of translated: " ++ (show $ head translated)
	lift $ debugM_ "Adding an empty Activity record"
	activity <- transferTo . (`Activity` infiniteTime) <$> liftIO getCurrentTime
	res <- runOnDatabase "irc" $ 
		modify (select filterQuery "data") ["$push" =: ["logs" =: activity]]
	case res of
		Left e -> log (errorM_ $ "Failed to add activity, error: " ++ show e) >> throw Critical
		Right _ -> log (debugM_ "Inserted activity") >> return True

-- | Insert a new user into the database.
insertNick :: ServerName -> String -> UserName -> String -> String-> DatabaseEnv ()
insertNick server host nick user real = do
	lift $ debugM_ $ "Inserting new nick: " ++ nick
	current <- liftIO getCurrentTime
	let entry = Entry Nothing nick (getNetwork server) host real user
		[Activity current infiniteTime] []
	res <- runOnDatabase "irc" $ 
		insert "data" $ transferTo entry
	case res of
		Left e -> log (errorM_ $ "Failed to add user, error: " ++ show e) >> throw Critical
		Right id -> log (debugM_ $ "Added user with id: " ++ show id)

