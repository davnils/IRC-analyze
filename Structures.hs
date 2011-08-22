{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}

module Structures
(DatabaseState(..), DatabaseEnv, ChildState(..), ChildEnv, ServerState(..), ServerEnv,
ChannelMessage(..), Entry(..), Activity(..), HandleWrapper(..),
transferTo, transferFrom)
where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Concurrent.STM.TChan
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State
import qualified Data.ByteString as L
import Data.Int
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Time.Clock (UTCTime(..), utctDay, getCurrentTime, secondsToDiffTime)
import Data.Time.Calendar (toModifiedJulianDay, Day(..))
import Database.MongoDB
import LogWrapper
import Network.Socket(HostName)
import Prelude hiding (log, catch, lookup, id)
import qualified Prelude as P
import System.IO

data DatabaseState = DatabaseState { pipe :: Pipe }
type DatabaseEnv = ReaderT DatabaseState LoggerEnv

data ChannelMessage
	= JoinMessage String
	| LeaveMessage String
	| StatsQuery 
	| StatsReply { channelStatus :: [String]} 

data Entry = Entry {	id :: Int64,
			nick :: L.ByteString,
			ip :: Int32,
			hostname :: HostName,
			realname :: L.ByteString,
			username :: L.ByteString,
			logs :: [Activity] }

data Activity = Activity
		{	start :: UTCTime,
			end :: UTCTime,
			hostname_ :: HostName}

data IRCMessage = IRCMessage { id :: Int64,
				message :: L.ByteString }

data ServerState = ServerState {	pool :: ConnPool Host,
				  	childs :: M.Map String (TChan ChannelMessage)}
type ServerEnv = StateT ServerState LoggerEnv

data ChildState = ChildState {	dbSocket :: Pipe,
				ircHandle :: HandleWrapper,
				messageChannel :: TChan ChannelMessage,
				channels :: [String]}
type ChildEnv = StateT ChildState LoggerEnv

data HandleWrapper = Invalid | Valid { getHandle :: Handle }

class MongoIO a where
	transferTo :: a -> Document
	transferFrom :: Document -> Maybe a

-- |Used to wrap values in a heterogene list.
data ValWrapper = forall a. Val a => W a

-- | Local functions used for convenience in MongoIO instances.
liftM6 f a1 a2 a3 a4 a5 a6 = return f `ap` a1 `ap` a2 `ap` a3 `ap` a4 `ap` a5 `ap` a6
liftM7 f a1 a2 a3 a4 a5 a6 a7 = return f `ap` a1 `ap` a2 `ap` a3 `ap` a4 `ap` a5 `ap` a6 `ap` a7

toVal = map (\(l, W v) -> (l :: UString) := val v)
f a d = lookup (a) d
extrBin a d = f a d >>= \(Binary x) -> return x

-- Could probably be cleaned up with template haskell.
instance MongoIO Entry where
	transferTo entry = toVal [
			("id", W $ id entry),
			("nick", W $ Binary $ nick entry),
			("ip", W $  ip entry),
			("hostname", W $ hostname entry),
			("realname", W $ Binary $ realname entry),
			("username", W $ Binary $ username entry),
			("logs", W $ map transferTo $ logs entry)
			]
	transferFrom doc = liftM7 Entry (f "id" doc) (extrBin "nick" doc) (f "ip" doc)
		(f "hostname" doc) (extrBin "realname" doc) (extrBin "username" doc) 
		(mapM transferFrom $ f "logs" doc)

instance MongoIO Activity where
	transferTo activity = undefined
	transferFrom doc = undefined
