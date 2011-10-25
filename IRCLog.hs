module Main
where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM.TChan
import qualified Data.Map as M
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.STM
import qualified Control.Monad.State as S
import Data.Maybe
import Database.MongoDB
import IRC
import LogWrapper
import Network
import Prelude hiding (log, catch, lookup, id)
import qualified Prelude as P
import Storage
import Structures
import System.IO

main :: IO ()
main = runReaderT run $ LoggerState "main"

run :: LoggerEnv ()
run = do
        logInitialize 
        infoM_ "Initializing"
        pool <- createPool
        _ <- S.runStateT shell $ ServerState pool M.empty
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
        _ <- liftIO $ forkIO $ runReaderT (S.runStateT (worker server) env) r >> return ()
        return (chan, server)

worker :: String -> ChildEnv ()
worker server = do
        h <- liftIO $ connectTo server $ PortNumber 6667
        liftIO $ hSetBuffering h NoBuffering
        S.modify $ \(ChildState db _ c _) -> ChildState db (Valid (h, server)) c []
        ircInitialize
        _ <- forever workerLoop
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
