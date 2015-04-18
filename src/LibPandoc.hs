{-# LANGUAGE ForeignFunctionInterface #-}
{-
 - Copyright (C) 2009-2010  Anton Tayanovskyy <name.surname@gmail.com>
 - Copyright (C) 2015  Shahbaz Youssefi <ShabbyX@gmail.com>
 -
 - This file is part of libpandoc, providing C bindings to Pandoc.
 -
 - libpandoc is free software: you can redistribute it and/or modify
 - it under the terms of the GNU General Public License as published by
 - the Free Software Foundation, either version 2 of the License, or
 - (at your option) any later version.
 -
 - libpandoc is distributed in the hope that it will be useful,
 - but WITHOUT ANY WARRANTY; without even the implied warranty of
 - MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 - GNU General Public License for more details.
 -
 - You should have received a copy of the GNU General Public License
 - along with libpandoc.  If not, see <http://www.gnu.org/licenses/>.
 -}

-- | Provides FFI interface to Pandoc.
module LibPandoc (pandoc, LibPandocSettings(..), defaultLibPandocSettings) where

import           Control.Arrow              ((>>>))
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Char                  as Char
import qualified Data.Generics.Rep          as Rep
import qualified Data.Map                   as Map
import           Foreign
import           Foreign.C.String
import           Foreign.C.Types
import           LibPandoc.IO
import           LibPandoc.Settings
import           System.IO.Unsafe
import           Text.Pandoc
import           Text.Pandoc.Error
import qualified Text.XML.Light             as Xml
import qualified Text.XML.Light.Generic     as XG

-- | The type of the main entry point.
type CPandoc = CInt -> CString -> CString -> CString
             -> FunPtr CReader -> FunPtr CWriter -> Ptr ()
             -> IO CString

foreign export ccall "pandoc" pandoc     :: CPandoc
foreign export ccall "increase" increase :: CInt -> IO CInt
foreign import ccall "dynamic" peekReader :: FunPtr CReader -> CReader
foreign import ccall "dynamic" peekWriter :: FunPtr CWriter -> CWriter

increase :: CInt -> IO CInt
increase x = return (x + 1)

readXml :: ReaderOptions -> String -> Either PandocError Pandoc
readXml state xml =
    let failed = Left $ ParseFailure "Failed to parse XML." in
    case Xml.onlyElems (Xml.parseXML xml) of
      (elem : _) ->
          case XG.ofXml elem of
            Just pandoc -> Right pandoc
            Nothing     -> failed
      _ -> failed

writeXml :: WriterOptions -> Pandoc -> String
writeXml options pandoc = Xml.ppElement (XG.toXml pandoc)

readNativeWrapper :: ReaderOptions -> String -> Either PandocError Pandoc
readNativeWrapper options = readNative

getInputFormat :: String -> Maybe (ReaderOptions -> String -> Either PandocError Pandoc)
getInputFormat x =
    case map Char.toLower x of
      "docbook"    -> Just readDocBook
      "html"       -> Just readHtml
      "latex"      -> Just readLaTeX
      "markdown"   -> Just readMarkdown
      "mediawiki"  -> Just readMediaWiki
      "native"     -> Just readNativeWrapper
      "rst"        -> Just readRST
--      "texmath"    -> Just readTeXMath  TODO: disabled until I figure out how to convert it to ReaderOptions -> String -> Pandoc
      "textile"    -> Just readTextile
      "xml"        -> Just readXml
      _            -> Nothing

getOutputFormat :: String -> Maybe (WriterOptions -> Pandoc -> String)
getOutputFormat x =
    case map Char.toLower x of
      "asciidoc"     -> Just writeAsciiDoc
      "context"      -> Just writeConTeXt
      "docbook"      -> Just writeDocbook
--      "docx"         -> Just writeDocx  TODO: The following are disabled because they return IO types
--      "epub"         -> Just writeEPUB  TODO: Which I do not know yet how to mix with the non IO type
--      "fb2"          -> Just writeFB2
      "html"         -> Just writeHtmlString
      "latex"        -> Just writeLaTeX
      "man"          -> Just writeMan
      "markdown"     -> Just writeMarkdown
      "mediawiki"    -> Just writeMediaWiki
      "native"       -> Just writeNative
--      "odt"          -> Just writeODT
      "opendocument" -> Just writeOpenDocument
      "org"          -> Just writeOrg
      "rst"          -> Just writeRST
      "rtf"          -> Just writeRTF
      "texinfo"      -> Just writeTexinfo
      "textile"      -> Just writeTextile
      "xml"          -> Just writeXml
      _              -> Nothing


joinRep :: Rep.ValueRep -> Rep.ValueRep -> Rep.ValueRep
joinRep (Rep.ValueRep name (Left x)) (Rep.ValueRep _ (Left y)) =
    Rep.ValueRep name (Left (Map.toList um)) where
        xm = Map.fromList x
        ym = Map.fromList y
        um = Map.unionWith joinRep xm ym
joinRep (Rep.ValueRep name (Right x)) (Rep.ValueRep _ (Right y)) =
    Rep.ValueRep name (Right (zipWith joinRep x y))
joinRep (Rep.TupleRep x) (Rep.TupleRep y) =
    Rep.TupleRep (zipWith joinRep x y)
joinRep (Rep.ListRep x) (Rep.ListRep y) =
    Rep.ListRep (zipWith joinRep x y)
joinRep x _ = x

getSettings :: CString -> IO LibPandocSettings
getSettings settings
    | settings == nullPtr =
        return defaultLibPandocSettings
    | otherwise =
        do let dS = defaultLibPandocSettings
           s <- peekCString settings
           case Xml.onlyElems (Xml.parseXML s) of
             (e:_) ->
                 case XG.decodeXml e of
                   Nothing  -> return dS
                   Just rep ->
                       let r = Rep.toRep dS `joinRep` rep in
                       return $ maybe dS id (Rep.ofRep r)
             _ -> return dS

pandoc :: CPandoc
pandoc bufferSize input output settings reader writer userData = do
  let r = peekReader reader
      w = peekWriter writer
  i <- peekCString input
  o <- peekCString output
  s <- getSettings settings
  case (getInputFormat i, getOutputFormat o) of
    (Nothing, _)            -> newCString "Invalid input format."
    (_, Nothing)            -> newCString "Invalid output format."
    (Just read, Just write) ->
      do let run = read (readerOptions s) >>> handleError >>> write (writerOptions s)
         transform (decodeInt bufferSize) run r w userData
         return nullPtr

decodeInt :: CInt -> Int
decodeInt = fromInteger . toInteger
