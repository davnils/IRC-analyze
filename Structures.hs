{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Structures
(DbException(..), DatabaseState(..), DatabaseEnv, ChildState(..), ChildEnv, ServerState(..), ServerEnv,
ChannelMessage(..), Entry(..), Activity(..), IRCMessage(..), HandleWrapper(..),
transferTo, transferFrom)
where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Concurrent.STM.TChan
import Control.Exception
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State
import qualified Data.ByteString.Char8 as L
import Data.Bson (ObjectId)
import Data.Int
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Time.Clock (UTCTime(..), utctDay, getCurrentTime, secondsToDiffTime)
import Data.Time.Calendar (toModifiedJulianDay, Day(..))
import Data.Typeable
import Database.MongoDB hiding (timestamp)
import LogWrapper
import Network.Socket(HostName)
import Prelude hiding (log, catch, lookup, id)
import qualified Prelude as P
import System.IO

data DatabaseState = DatabaseState { pipe :: Pipe }
type DatabaseEnv = ReaderT DatabaseState LoggerEnv

data DbException = Critical
	deriving (Show, Typeable)

instance Exception DbException

data ChannelMessage
	= JoinMessage String
	| LeaveMessage String
	| StatsQuery 
	| StatsReply { channelStatus :: [String]} 

data Entry = Entry {	id :: Maybe ObjectId,
			nick :: String,
			ircserver :: String,
			hostname :: String,
			realname :: String,
			username :: String,
			logs :: [Activity],
			messages :: [IRCMessage] }
	deriving Show

data Activity = Activity {	start :: UTCTime,
				end :: UTCTime }
	deriving Show

data IRCMessage = IRCMessage {  timestamp :: UTCTime,
				message :: String }
	deriving Show

data ServerState = ServerState {	pool :: ConnPool Host,
				  	childs :: M.Map String (TChan ChannelMessage) }
type ServerEnv = StateT ServerState LoggerEnv

data ChildState = ChildState {	dbSocket :: Pipe,
				ircHandle :: HandleWrapper,
				messageChannel :: TChan ChannelMessage,
				channels :: [String] }
type ChildEnv = StateT ChildState LoggerEnv

data HandleWrapper = Invalid | Valid { getHandle :: (Handle, String) }

class MongoIO a where
	transferTo :: a -> Document
	transferFrom :: Document -> Maybe a

-- |Used to wrap values in a heterogene list.
data ValWrapper = forall a. Val a => W a

-- | Local functions used for convenience in MongoIO instances.
liftM6 f a1 a2 a3 a4 a5 a6 = return f `ap` a1 `ap` a2 `ap` a3 `ap` a4 `ap` a5 `ap` a6
liftM8 f a1 a2 a3 a4 a5 a6 a7 a8 = return f
	`ap` a1 `ap` a2 `ap` a3 `ap` a4 `ap` a5 `ap` a6 `ap` a7 `ap` a8

toVal = map (\(l, W v) -> (l :: UString) := val v)
f a d = lookup a d
extrBin a d = f a d >>= \(Binary x) -> return x

-- MongoIO instances of every data-structure that will be stored in the database.
instance MongoIO Entry where
	transferTo entry = toVal $ parseId ++ [
			("nick", W $ nick entry),
			("ircserver", W $  ircserver entry),
			("hostname", W $ hostname entry),
			("realname", W $ realname entry),
			("username", W $ username entry),
			("logs", W $ map transferTo $ logs entry),
			("messages", W $ map transferTo $ messages entry)
			]
		where
		parseId = case id entry of
			Just _id -> [("_id", W $ _id)]
			Nothing -> []

	transferFrom doc = liftM8 Entry (Just $ f "_id" doc) (f "nick" doc) (f "ircserver" doc)
		(f "hostname" doc) (f "realname" doc) (f "username" doc) 
		(mapM transferFrom $ lookup "logs" doc)
		(mapM transferFrom $ lookup "messages" doc)

instance MongoIO Activity where
	transferTo activity = toVal [
				("start", W $ start activity),
				("end", W $ end activity)
				]
	transferFrom doc = liftM2 Activity (f "start" doc) (f "end" doc)

instance MongoIO IRCMessage where
	transferTo msg = toVal [
			("timestamp", W $ timestamp msg), 
			("msg", W $ message msg)] 
	transferFrom doc = liftM2 IRCMessage (f "timestamp" doc) (f "msg" doc)
