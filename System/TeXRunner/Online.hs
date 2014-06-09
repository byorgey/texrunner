{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
module System.TeXRunner.Online
  ( TeXProcess
  , runTexProcess
  , hbox
  , hsize
  , showthe
  , texProcessParser
  , texPutStrLn
  ) where

import           Control.Applicative
import           Control.Monad.Reader
import qualified Data.Attoparsec.ByteString   as A
import           Data.ByteString.Char8        (ByteString)
import qualified Data.ByteString.Char8        as B
import           Data.Monoid
import           System.IO
import           System.IO.Streams            as Streams
import           System.IO.Streams.Attoparsec
import qualified System.Process               as P

import System.TeXRunner.Parse

-- | New type for dealing with TeX's pipeing interface.
newtype TeXProcess a = TeXProcess {runTeXProcess :: ReaderT TeXStreams IO a}
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader TeXStreams)

-- Run a tex process, disguarding the resulting PDF.
runTexProcess :: FilePath
              -> Maybe [(String, String)]
              -> String
              -> [String]
              -> ByteString
              -> TeXProcess a
              -> IO a
runTexProcess dir env command args preamble process = do
  (outS, inS, h) <- mkTeXHandles dir env command args preamble
  a              <- flip runReaderT (outS, inS) . runTeXProcess $ process

  write Nothing outS
  _ <- waitForProcess h

  return a

-- -- Run a tex process, keeping the resulting PDF.
-- runTexOnline :: FilePath
--              -> Maybe [(String, String)]
--              -> String
--              -> [String]
--              -> ByteString
--              -> TeXProcess a
--              -> IO (a, TeXResult)
-- runTexOnline dir env command args preamble process = do
--   streams <- mkTeXHandles command args preamble
--   a       <- flip runReaderT streams . runTeXProcess $ process
--
--   getOutSteam >>= write Nothing
--   waitForProcess pHandle
--
--   return a

-- | Get the dimensions of a hbox.
hbox :: ByteString -> TeXProcess Box
hbox str = do
  clearUnblocking
  texPutStrLn $ "\\setbox0=\\hbox{" <> str <> "}\n\\showbox0\n"
  texProcessParser parseBox

showthe :: ByteString -> TeXProcess Double
showthe str = do
  clearUnblocking
  texPutStrLn $ "\\showthe" <> str
  texProcessParser parseUnit

-- | Dimensions from filling the current line.
hsize :: TeXProcess Double
hsize = boxWidth <$> hbox "\\line{\\hfill}"

-- | Run an Attoparsec parser on TeX's output.
texProcessParser :: A.Parser a -> TeXProcess a
texProcessParser p = getInStream >>= liftIO . parseFromStream p
  -- TODO: have a timeout

texPutStrLn :: ByteString -> TeXProcess ()
texPutStrLn a = getOutStream >>= liftIO . write (Just $ B.append a "\n")

-- * Internal
-- These funcions should be used with caution.

type TeXStreams = (OutputStream ByteString, InputStream ByteString)

getOutStream :: TeXProcess (OutputStream ByteString)
getOutStream = reader fst

getInStream :: TeXProcess (InputStream ByteString)
getInStream = reader snd


clearUnblocking :: TeXProcess ()
clearUnblocking = getInStream >>= void . liftIO . Streams.read

-- | Uses a surface to open an interface with TeX,
mkTeXHandles :: FilePath
             -> Maybe [(String, String)]
             -> String
             -> [String]
             -> ByteString
             -> IO (OutputStream ByteString,
                    InputStream ByteString,
                    ProcessHandle)
mkTeXHandles dir env command args preamble = do

  -- TeX doesn't send anything to stderr
  (outStream, inStream, _, h) <- runInteractiveProcess'
                                   command
                                   args
                                   (Just dir)
                                   env

  write (Just "\\tracingonline=1\\showboxdepth=1\\showboxbreadth=1\\scrollmode\n")
        outStream
  write (Just preamble) outStream

  return (outStream, inStream, h)


-- plain :: TeXProcess a -> IO a
-- plain a = withSystemTempDirectory "texonline." $ \path ->
--             runTexProcess path Nothing "pdftex" [] "" a

-- plainHandles :: IO (OutputStream ByteString,
--                     InputStream ByteString,
--                     ProcessHandle)
-- plainHandles = mkTeXHandles "./" Nothing "pdftex" [] ""

-- Adapted from io-streams. Sets input handle to line buffering.

runInteractiveProcess'
    :: FilePath                 -- ^ Filename of the executable (see 'proc' for details)
    -> [String]                 -- ^ Arguments to pass to the executable
    -> Maybe FilePath           -- ^ Optional path to the working directory
    -> Maybe [(String,String)]  -- ^ Optional environment (otherwise inherit)
    -> IO (OutputStream ByteString,
           InputStream ByteString,
           InputStream ByteString,
           ProcessHandle)
runInteractiveProcess' cmd args wd env = do
    (hin, hout, herr, ph) <- P.runInteractiveProcess cmd args wd env

    -- it is possible to flush using write (Just "") but this seems nicer
    -- is there a better way?
    hSetBuffering hin LineBuffering

    sIn  <- Streams.handleToOutputStream hin >>=
            Streams.atEndOfOutput (hClose hin) >>=
            Streams.lockingOutputStream
    sOut <- Streams.handleToInputStream hout >>=
            Streams.atEndOfInput (hClose hout) >>=
            Streams.lockingInputStream
    sErr <- Streams.handleToInputStream herr >>=
            Streams.atEndOfInput (hClose herr) >>=
            Streams.lockingInputStream

    return (sIn, sOut, sErr, ph)

