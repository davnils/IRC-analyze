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
import qualified Data.ByteString as L
import Data.Maybe
import qualified Data.Set as S
import Data.Time.Clock (UTCTime(..), utctDay, getCurrentTime, secondsToDiffTime)
import Data.Time.Calendar (toModifiedJulianDay, Day(..))
import Database.MongoDB
import LogWrapper
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

addEntry :: Entry -> DatabaseEnv Bool
addEntry entry = do
	log $ debugM_ $ "Adding entry (id: " ++ (show $ id entry) ++ ")"
	res <- runOnDatabase "Log" $ do
		insert ("TODO") $ transferTo entry
	case res of
		Left e -> (log $ errorM_ $ "Failed to add entry, error: " ++ show e) >> return False
		Right id -> (log $ debugM_ $ "Added entry with db-id: " ++ show id) >> return True
	
