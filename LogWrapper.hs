-- | LogWrapper provides some basic logging functions that function in the LoggerEnv monad.
module LogWrapper where

import Control.Monad.Reader
import System.Log.Logger
import Prelude hiding (log)

-- | The state which is carried around functions able to log messages.
data LoggerState = LoggerState { name :: String }
-- | The monad stack, with the logger environment on top of the IO monad.
type LoggerEnv = ReaderT LoggerState IO

io :: IO a -> LoggerEnv a
io = liftIO

logM__ :: String -> Priority -> String -> IO ()
logM__ logger priority msg = do
	logM logger priority msg

logM_ :: Priority -> String -> LoggerEnv ()
logM_ priority msg = do
	logger <- asks name
	io $ logM__ logger priority msg

infoM_ :: String -> LoggerEnv()
infoM_ msg = logM_ INFO msg

debugM_ :: String -> LoggerEnv()
debugM_ msg = logM_ DEBUG msg

warningM_ :: String -> LoggerEnv()
warningM_ msg = logM_ WARNING msg

errorM_ :: String -> LoggerEnv()
errorM_ msg = logM_ ERROR msg

criticalM_ :: String -> LoggerEnv()
criticalM_ msg = logM_ CRITICAL msg

