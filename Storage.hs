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
import Control.Exception (throw)
import Data.Maybe
import Data.Time.Clock (UTCTime(..), getCurrentTime)
import Data.Time.Calendar (Day(..))
import Database.MongoDB
import LogWrapper
import Network.IRC
import Prelude hiding (log, catch, lookup, id)
import qualified Prelude as P
import Structures

maximumTCPConnections :: Int
maximumTCPConnections = 1

log :: LoggerEnv a -> DatabaseEnv a
log = lift

bracket_ :: Monad m => m a -> m b -> m c -> m c
bracket_ a b c = a >> c >>= (\x -> b >> return x)

createPool :: LoggerEnv (ConnPool Host)
createPool = bracket_
		(infoM_ $ "Creating connection pool to address: " ++ C.host)
		(infoM_ "Pool created")
		(io $ newConnPool maximumTCPConnections $ host C.host)

closePool :: ConnPool Host -> LoggerEnv ()
closePool pool = do
	infoM_ "Closing connection pool"
	io $ killPipes pool

getEnv :: ConnPool Host -> LoggerEnv (Maybe DatabaseState)
getEnv pool' = do
	p <- io $ runErrorT $ getPipe Master pool'
	case p of
		Right pipe' -> 
			return $ Just $ DatabaseState pipe'
		Left _ -> errorM_ "Failed to connect to database" >> return Nothing 

runOnDatabase :: UString -> ReaderT Database (Action IO) a
	-> DatabaseEnv (Either Failure a)
runOnDatabase db f = do
		p <- asks pipe
		log . io $ runAction (use (Database db) f) (Safe []) Master p

-- | addMsg lookups the corresponding id and inserts the message.
addMsg :: ServerName -> Channel -> UserName -> String -> DatabaseEnv ()
addMsg server channel nick msg = do
	log $ debugM_ "Adding message"
	let query = ["nick" =: nick, "ircserver" =: getNetwork server, "logs.end" =: infiniteTime]
	record <- transferTo <$> (`IRCMessage` msg) <$> liftIO getCurrentTime

	count' <- runOnDatabase "irc" $ 
		count (select query "data")
	case count' of
		Left _ -> log (errorM_ "Failed load count of users") >> throw Critical
		Right val -> unless (val == 1) $
			log (errorM_ $ "addMsg didn't match one user, but: " ++ show val)
			>> throw Critical

	res <- runOnDatabase "irc" $ 
		modify (select query "data") ["$push" =: ["messages" =: record]]

        case res of
                Left _ -> log (errorM_ "Failed to add message") >> throw Critical
		_ -> return ()

getNetwork :: String -> String
getNetwork = tail . dropWhile (/= '.') 

existsOpenSlot :: [Activity] -> Bool
existsOpenSlot = any (\log -> end log == infiniteTime)

infiniteTime :: UTCTime
infiniteTime = UTCTime (ModifiedJulianDay 0) 0

-- | Search for the given server/nick and return true if an active session exists.
searchNick :: ServerName -> String -> UserName -> DatabaseEnv Bool
searchNick server host nick = do
	log $ debugM_ $ "Searching for nick: " ++ nick
	-- TODO: use Regex type as defined in BSON library
	let filterQuery = ["nick" =: nick, "ircserver" =: getNetwork server, "hostname" =: host]
	res <- runOnDatabase "irc" $ 
                find (select filterQuery "data") >>= rest
        user <- case res of
                Left _ -> log (errorM_ "Failed to search for nick") >> throw Critical
		Right docs -> return docs

        let translated = fromMaybe [] (mapM transferFrom user) :: [Entry]
	if null translated then return False else do

	-- Check if there exists an active Activity record. If not, add one.
	if (existsOpenSlot . logs . head) translated then 
		lift (debugM_ "Found an active Activity record") >> return True
		else do

	lift $ debugM_ $ "Contents of translated: " ++ show (head translated)
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

