{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Structures
(DbException(..), DatabaseState(..), DatabaseEnv, ChildState(..), ChildEnv,
ServerState(..), ServerEnv, ChannelMessage(..), Entry(..), Activity(..),
IRCMessage(..), HandleWrapper(..), transferTo, transferFrom)
where

import Control.Concurrent.STM.TChan
import Control.Exception
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Data.Bson (ObjectId)
import qualified Data.Map as M
import Data.Time.Clock (UTCTime(..))
import Data.Time.Calendar (toModifiedJulianDay, Day(..))
import Data.Typeable
import Database.MongoDB hiding (timestamp)
import LogWrapper
import Network.Socket (HostName)
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

data Entry = Entry {    id :: Maybe ObjectId,
                        nick :: String,
                        ircserver :: String,
                        hostname :: String,
                        realname :: String,
                        username :: String,
                        logs :: [Activity],
                        messages :: [IRCMessage] }
        deriving Show

data Activity = Activity {      start :: UTCTime,
                                end :: UTCTime,
                                channelActivity :: String }
        deriving Show

data IRCMessage = IRCMessage {  timestamp :: UTCTime,
                                msgChannel :: String,
                                message :: String }
        deriving Show

data ServerState = ServerState {        childs :: M.Map String (TChan ChannelMessage) }
type ServerEnv = StateT ServerState LoggerEnv

data ChildState = ChildState {  dbSocket :: Pipe,
                                ircHandle :: HandleWrapper,
                                messageChannel :: TChan ChannelMessage,
                                channels :: [String],
                                whoBuffer :: [String] }
type ChildEnv = StateT ChildState LoggerEnv

data HandleWrapper = Invalid | Valid { getHandle :: (Handle, String) }

class MongoIO a where
        transferTo :: a -> Document
        transferFrom :: Document -> Maybe a

-- |Used to wrap values in a heterogene list.
data ValWrapper = forall a. Val a => W a

-- | Local functions used for convenience in MongoIO instances.
liftM8 :: Monad m =>
        (a1 -> a2 -> a3 -> a4 -> a5 -> a6 -> a7 -> a8 -> b)
        -> m a1 -> m a2 -> m a3 -> m a4 -> m a5 -> m a6 -> m a7 -> m a8
        -> m b
liftM8 f' a1 a2 a3 a4 a5 a6 a7 a8 = return f'
        `ap` a1 `ap` a2 `ap` a3 `ap` a4 `ap` a5 `ap` a6 `ap` a7 `ap` a8

toVal :: [(UString, ValWrapper)] -> [Field]
toVal = map (\(l, W v) -> (l :: UString) := val v)

f :: (Val v, Monad m) => Label -> Document -> m v
f = lookup

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
                        Just id' -> [("_id", W id')]
                        Nothing -> []

        transferFrom doc = liftM8 Entry (Just $ f "_id" doc) (f "nick" doc)
                (f "ircserver" doc)
                (f "hostname" doc) (f "realname" doc) (f "username" doc)
                (f "logs" doc >>= mapM transferFrom)
                (f "messages" doc >>= mapM transferFrom)

instance MongoIO Activity where
        transferTo activity = toVal [
                                ("start", W $ start activity),
                                ("end", W $ end activity),
                                ("channel", W $ channelActivity activity)
                                ]
        transferFrom doc = liftM3 Activity
                (f "start" doc) (f "end" doc) (f "channel" doc)

instance MongoIO IRCMessage where
        transferTo msg = toVal [
                        ("timestamp", W $ timestamp msg),
                        ("channel", W $ msgChannel msg),
                        ("msg", W $ message msg)]
        transferFrom doc = liftM3 IRCMessage
                (f "timestamp" doc) (f "channel" doc) (f "msg" doc)
