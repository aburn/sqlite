{-# LANGUAGE ForeignFunctionInterface #-}
module Database.SQLite.VFS where

import Control.Concurrent (threadDelay)
import Control.Monad
import Data.List
import Data.Time.Clock
import Data.Time.LocalTime
import Data.Char
import Database.SQLite.VFS.Types
import Foreign
import Foreign.C
import Foreign.Ptr
import Prelude hiding (catch)
import System.Directory
import System.IO
import System.IO.Error

import Database.SQLite.Types

import Debug.Trace

maxPathname :: CInt
maxPathname = 512

blockSize :: Int
blockSize = 1024

foreign import ccall "sqlite3.h sqlite3_vfs_register" sqliteVfsRegister ::
  Ptr SqliteVFS -> Bool -> IO Status

foreign import ccall "sqlite3.h sqlite3_vfs_find" sqliteVfsFind ::
  CString -> IO (Ptr SqliteVFS)

foreign import ccall "sqlite3.h sqlite3_vfs_unregister" sqliteVfsUnregister ::
  Ptr SqliteVFS -> IO Status

foreign import ccall "little_locks.h get_shared"
  get_shared :: CString -> CSize -> CString -> IO CInt

foreign import ccall "little_locks.h get_reserved"
  get_reserved :: CString -> CString -> IO CInt

foreign import ccall "little_locks.h get_exclusive"
  get_exclusive :: CString -> IO CInt

foreign import ccall "little_locks.h free_exclusive"
  free_exclusive :: CString -> CSize -> CString -> IO CInt

foreign import ccall "little_locks.h free_shared"
  free_shared :: CString -> CString -> IO CInt

foreign import ccall "little_locks.h check_res"
  check_res :: CString -> IO CInt

unregisterVFS :: String -> IO ()
unregisterVFS name =
 do ptr <- withCString name sqliteVfsFind
    unless (ptr == nullPtr) $
     do sqliteVfsUnregister ptr
        vfs <- peek ptr
        free (zName vfs)
        freeHaskellFunPtr (xOpen vfs)
        freeHaskellFunPtr (xDelete vfs)
        freeHaskellFunPtr (xAccess vfs)
        freeHaskellFunPtr (xGetTempname vfs)
        freeHaskellFunPtr (xFullPathname vfs)
        freeHaskellFunPtr (xDlOpen vfs)
        freeHaskellFunPtr (xDlError vfs)
        freeHaskellFunPtr (xDlSym vfs)
        freeHaskellFunPtr (xDlClose vfs)
        freeHaskellFunPtr (xRandomness vfs)
        freeHaskellFunPtr (xSleep vfs)
        freeHaskellFunPtr (xCurrentTime vfs)
        free ptr

registerDirectoryVFS :: IO Status
registerDirectoryVFS =
 do vfs <- new =<< return (SqliteVFS maxPathname nullPtr)
                   `ap` newCString "filebased"
                   `ap` return nullPtr
                   `ap` mkXOpen vopen
                   `ap` mkXDelete vdelete
                   `ap` mkXAccess vaccess
                   `ap` mkXGetTempname vgettempname
                   `ap` mkXFullPathname vfullpathname
                   `ap` mkXDlOpen vdlopen
                   `ap` mkXDlError vdlerror
                   `ap` mkXDlSym vdlsym
                   `ap` mkXDlClose vdlclose
                   `ap` mkXRandomness vrandomness
                   `ap` mkXSleep vsleep
                   `ap` mkXCurrentTime vcurrenttime
    sqliteVfsRegister vfs True

vopen :: XOpen
vopen _ zName my_file_ptr flags pOutFlags =
 do name <- peekCString zName
    putStrLn ("Open: " ++ name)
    createDirectoryIfMissing False name
    poke my_file_ptr =<< init_my_file zName
    return sQLITE_OK
   `catch` \ _ -> return sQLITE_CANTOPEN

vdelete :: XDelete
vdelete _ zName syncDir =
 do name <- peekCString zName
    putStrLn ("Delete: " ++ name)
    putStrLn (" Sync: " ++ show syncDir)
    removeDirectoryRecursive name
    return sQLITE_OK

vaccess :: XAccess
vaccess _ zName flags =
 do name <- peekCString zName
    putStrLn ("Access: " ++ name ++ " " ++ showAccess flags)
    perms <- getPermissions name
    return $ if      flags == sQLITE_ACCESS_EXISTS    then True
             else if flags == sQLITE_ACCESS_READ      then readable perms
             else if flags == sQLITE_ACCESS_READWRITE then readable perms &&
                                                           writable perms
             else False
  `catch` \ _ -> return False

vgettempname :: XGetTempname
vgettempname _ nOut zOut =
 do let i = 42 :: Int
    let name = show i
    putStrLn ("GetTempname: " ++ name)
    if length name <= fromIntegral nOut
      then do pokeCString zOut name
              return sQLITE_OK
      else return sQLITE_ERROR

vfullpathname :: XFullPathname
vfullpathname _ zName nOut zOut =
 do name <- peekCString zName
    fullname <- canonicalizePath name
    putStrLn ("FullPathname: " ++ name)
    if genericLength fullname <= nOut
      then do pokeCString zOut fullname
              return sQLITE_OK
      else return sQLITE_ERROR

vdlopen :: XDlOpen
vdlopen = error "xDlOpen"

vdlerror :: XDlError
vdlerror = error "xDlError"

vdlsym :: XDlSym
vdlsym = error "xDlSym"

vdlclose :: XDlClose
vdlclose = error "xDlClose"

vrandomness :: XRandomness
vrandomness _ nByte zOut =
 do putStrLn ("Randomness: " ++ show nByte)
    withBinaryFile "/dev/urandom" ReadMode $ \ h ->
      hGetBuf h zOut (fromIntegral nByte)
    return nByte

vsleep :: XSleep
vsleep _ us = threadDelay (fromIntegral us) >> return sQLITE_OK

vcurrenttime :: XCurrentTime
vcurrenttime _ ptr =
 do zone <- getCurrentTimeZone
    now  <- getCurrentTime
    let local = utcToLocalTime zone now
        ut1 = localTimeToUT1 0 local
        m   = getModJulianDate ut1
    poke ptr (fromRational m)
    return sQLITE_OK

pokeCString :: Ptr CChar -> String -> IO ()
pokeCString ptr xs = pokeArray0 0 ptr (map (toEnum . fromEnum) xs)

init_my_file :: CString -> IO MySqliteFile
init_my_file zName = return MySqliteFile `ap` init_file `ap` return zName `ap` return nullPtr

init_file :: IO SqliteFile
init_file = SqliteFile `fmap` (new =<< init_io_methods)

init_io_methods :: IO SqliteIoMethods
init_io_methods =
  return SqliteIoMethods
    `ap` mkXClose vclose
    `ap` mkXRead  vread
    `ap` mkXWrite vwrite
    `ap` mkXTruncate vtruncate
    `ap` mkXSync vsync
    `ap` mkXFileSize vfilesize
    `ap` mkXLock vlock
    `ap` mkXUnlock vunlock
    `ap` mkXCheckReservedLock vcheckres
    `ap` mkXFileControl vfilecontrol
    `ap` mkXSectorSize vsectorsize
    `ap` mkXDeviceCharacteristics vdevchar

freeIoMethods :: Ptr SqliteIoMethods -> IO ()
freeIoMethods ptr =
 do s <- peek ptr
    freeHaskellFunPtr (xClose s)
    freeHaskellFunPtr (xRead s)
    freeHaskellFunPtr (xWrite s)
    freeHaskellFunPtr (xTruncate s)
    freeHaskellFunPtr (xSync s)
    freeHaskellFunPtr (xFileSize s)
    freeHaskellFunPtr (xLock s)
    freeHaskellFunPtr (xUnlock s)
    freeHaskellFunPtr (xCheckReservedLock s)
    freeHaskellFunPtr (xFileControl s)
    freeHaskellFunPtr (xSectorSize s)
    freeHaskellFunPtr (xDeviceCharacteristics s)
    free ptr


vclose :: XClose
vclose ptr =
 do freeIoMethods . pMethods . myBaseFile =<< peek ptr
    return sQLITE_OK

getMyFilename :: Ptr MySqliteFile -> IO String
getMyFilename ptr = peekCString . myFilename =<< peek ptr

doRead :: Ptr Word8 -> String -> Int -> Int -> Int -> IO Int
doRead _ _ _ 0 _ = return 0
doRead ptr name fn amt offset = do
  let amt' = min (blockSize - offset) amt
  got <- (withBinaryFile (name ++ "/" ++ show fn) ReadMode $ \ h ->
           do hSeek h AbsoluteSeek (fromIntegral offset)
              hGetBuf h ptr amt'
          ) `catch` \ e -> if isDoesNotExistError e then return 0 else ioError e
  if got < amt' then return got else do
    got' <- doRead (ptr `advancePtr` got) name (fn+1) (amt-got) 0
    return (got + got')

doWrite :: Ptr Word8 -> String -> Int -> Int -> Int -> IO ()
-- finished writing
doWrite _ _ _ 0 _ = return ()

-- writing a full block
doWrite ptr name fn amt 0 | amt >= blockSize =
 do withBinaryFile (name ++ "/" ++ show fn) WriteMode $ \ h ->
      hPutBuf h ptr blockSize
    doWrite (ptr `advancePtr` blockSize) name (fn+1) (amt-blockSize) 0

-- writing a partial block
doWrite ptr name fn amt offset = do
  let amt' = min (blockSize - offset) amt
  allocaArray blockSize $ \ tempArray ->
   do (withBinaryFile (name ++ "/" ++ show fn) ReadMode $ \ h ->
         hGetBuf h (tempArray :: Ptr Word8) blockSize
       ) `catch` \ _ -> return 0
      withBinaryFile (name ++ "/" ++ show fn) WriteMode $ \ h ->
       do hPutBuf h tempArray offset
          hPutBuf h ptr amt'
          hPutBuf h (tempArray `advancePtr` (offset + amt'))
                    (blockSize - offset - amt')
  doWrite (ptr `advancePtr` amt') name (fn+1) (amt-amt') 0

vread :: XRead
vread p buffer amt offset =
 do name <- getMyFilename p
    let a = fromIntegral amt
        o = fromIntegral offset
    putStrLn ("Read: " ++ name)
    putStrLn (" amt: " ++ show amt)
    putStrLn (" offset: " ++ show offset)
    let firstNumber = o `div` blockSize
    (do got <- doRead buffer name firstNumber a (o - firstNumber * blockSize)
        return $ if got < a then sQLITE_IOERR_SHORT_READ else sQLITE_OK
     ) `catch` \ _ -> return sQLITE_IOERR_READ

vwrite :: XWrite
vwrite p buffer amt offset =
 do name <- getMyFilename p
    let a = fromIntegral amt
        o = fromIntegral offset
    putStrLn "Write"
    putStrLn (" amt: " ++ show amt)
    putStrLn (" offset: " ++ show offset)
    let firstNumber = o `div` blockSize
    doWrite buffer name firstNumber a (o - firstNumber * blockSize)
    return sQLITE_OK

vtruncate :: XTruncate
vtruncate p newsize =
 do name <- getMyFilename p
    putStrLn "Truncate"
    putStrLn (" newsize " ++ show newsize)
    return sQLITE_OK

vsync :: XSync
vsync _ flags = return sQLITE_OK

vfilesize :: XFileSize
vfilesize p pSize =
 do name <- getMyFilename p
    putStrLn ("Filesize: " ++ name)
    xs1 <- getDirectoryContents name `catch` \ _ -> return ["",""]
    let xs = filter (all isDigit) xs1
    poke pSize (fromIntegral (blockSize * (length xs - 2)))
    return sQLITE_OK

vlock :: XLock
vlock ptr flag =
  do info <- peek ptr
     s    <- peekCString (myFilename info)
     putStrLn ("lock: " ++ s ++ " " ++ showLock flag)
     getLine
     case () of
       _ | flag == sQLITE_LOCK_SHARED ->
            fmap check $ get_shared (myFilename info) 512 (mySharedlock info)
         | flag == sQLITE_LOCK_RESERVED ->
            fmap check $ get_reserved (myFilename info) (mySharedlock info)
         | flag == sQLITE_LOCK_EXCLUSIVE ->
            fmap check $ get_exclusive (myFilename info)
         | otherwise -> return sQLITE_ERROR

  where
  check 0 = sQLITE_OK
  check e | Errno (negate e) == eBUSY = sQLITE_BUSY
          | otherwise                 = sQLITE_ERROR


vunlock :: XUnlock
vunlock ptr flag =
  do info <- peek ptr
     s <- peekCString (myFilename info)
     putStrLn ("unlock: " ++ s ++ " " ++ showLock flag)
     case () of
      _ | flag == sQLITE_LOCK_NONE -> free_shared (myFilename info) (mySharedlock info) >>= check
        | flag == sQLITE_LOCK_SHARED -> free_exclusive (myFilename info) 512 (mySharedlock info) >>= check
        | otherwise -> return sQLITE_ERROR
  where
  check 0 = return sQLITE_OK
  check _ = return sQLITE_ERROR

-- note: could be combined
showAccess x = checks !! fromIntegral x
  where checks = ["EXISTS", "READWRITE", "READ"]
                    ++ repeat ("unknown " ++ show x)

showLock x = locks !! fromIntegral x
  where locks = ["NONE", "SHARED", "RESERVED", "PENDING", "EXCLUSIVE"]
                ++ repeat ("unknown " ++ show x)


vcheckres :: XCheckReservedLock
vcheckres p = do putStrLn "check reserved?"
                 info <- peek p
                 rc <- check_res (myFilename info)
                 return (rc == 1)

vfilecontrol :: XFileControl
vfilecontrol _ op pArg = return sQLITE_OK

vsectorsize :: XSectorSize
vsectorsize _ = return (fromIntegral blockSize)

vdevchar :: XDeviceCharacteristics
vdevchar _ = return sQLITE_IOCAP_ATOMIC1K
