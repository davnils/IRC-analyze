{-# LANGUAGE OverloadedStrings #-}

module Storage
(createPool, closePool, getEnv, log, runOnDatabase)
where
import qualified Configuration as C
import Control.Applicative
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.Trans.Maybe
import Control.Exception (catch, IOException, evaluate, SomeException)
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
addMsg :: ServerName -> Channel -> UserName -> String -> DatabaseEnv Bool
addMsg server channel nick msg = do
	log $ debugM_ $ "Adding message"
	res <- runOnDatabase "irc" $ do
                find (select ["nick" =: nick, "hostname" =: server] $ "users") >>= rest
		--TODO: logs.find(end == 0) => en träff

        loaded <- case res of
                Left e -> (log $ errorM_ $ "Failed to load id") >> return []
		Right docs -> return docs

        translated <- return $ (mapM transferFrom (loaded :: [Document]) :: Maybe [Entry])
	let transList = fromMaybe [] translated

	success <- case length transList of
		0 -> log $ errorM_ "Failed to find an id" >> return False
		1 -> log $ debugM_ "Found an id" >> return True
		_ -> log $ errorM_ "Multiple id:s returned" >> return False
	
	if success then do
		let input = IRCMessage (id $ transList !! 0) $ L.pack msg
		res <- runOnDatabase "irc" $ do
			insert ("messages") $ transferTo input
		case res of
			Left e -> (log $ errorM_ $ "Failed to add message, error: " ++ show e) >> return False
			Right id -> (log $ debugM_ $ "Added message with id: " ++ show id) >> return True

		else return False
