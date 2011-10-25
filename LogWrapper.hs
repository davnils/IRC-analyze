-- | LogWrapper provides some basic logging functions that function in the LoggerEnv monad.
module LogWrapper where

import Control.Monad.Reader
import System.Log.Logger
import Prelude hiding (log)
import System.Log.Formatter
import System.Log.Logger
import System.Log.Handler.Simple
import System.Log.Handler (setFormatter)

-- | The state which is carried around functions able to log messages.
data LoggerState = LoggerState { name :: String }
-- | The monad stack, with the logger environment on top of the IO monad.
type LoggerEnv = ReaderT LoggerState IO

io :: IO a -> LoggerEnv a
io = liftIO

logInitialize :: LoggerEnv ()
logInitialize = do
        logFile <- io $ fileHandler "log" DEBUG >>=  \h -> return $
               setFormatter h (simpleLogFormatter "[$prio] $msg")
        io $ updateGlobalLogger rootLoggerName $ addHandler logFile
        io $ updateGlobalLogger rootLoggerName $ setLevel DEBUG

logM__ :: String -> Priority -> String -> IO ()
logM__ = logM

logM_ :: Priority -> String -> LoggerEnv ()
logM_ priority msg = do
        logger <- asks name
        io $ logM__ logger priority msg

infoM_ :: String -> LoggerEnv()
infoM_ = logM_ INFO

debugM_ :: String -> LoggerEnv()
debugM_ = logM_ DEBUG

warningM_ :: String -> LoggerEnv()
warningM_ = logM_ WARNING

errorM_ :: String -> LoggerEnv()
errorM_ = logM_ ERROR

criticalM_ :: String -> LoggerEnv()
criticalM_ = logM_ CRITICAL
