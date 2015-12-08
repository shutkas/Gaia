{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Gaia.AesonObjectsUtils where

-- This module concentrates utility functions to facilitate the reading of Aeson Objects

import           Control.Monad.Trans.Maybe
import qualified Data.Aeson                               as A
    -- A.decode :: A.FromJSON a => Char8.ByteString -> Maybe a
import qualified Data.ByteString.Lazy.Char8               as Char8
import qualified Data.Digest.Pure.SHA                     as SHA
    -- SHA.sha1 :: Char8.ByteString -> Digest SHA1State
    -- SHA.showDigest :: Digest t -> String
import qualified Data.HashMap.Strict                      as HM
import qualified Data.Scientific                          as S
import qualified Data.Text                                as T
import qualified Data.Vector                              as V
import qualified GHC.Exts                                 as E
    -- support for the JSON library
import           Gaia.Types
import qualified PStorageServices.ContentAddressableStore as CAS

-- -----------------------------------------------------------
-- Some Documentation
-- -----------------------------------------------------------

{-
	Understanding Aion Objects (duplicate from documentation) and Aeson Values
-}

{-|

    Aion Objects

    {
        "aion-type" : "file"
        "version"   : 1
        "name"      : String
        "size"      : Integer
        "hash"      : sha1-hash
    }
    {
        "aion-type" : "directory"
        "version"   : 1
        "name"      : String
        "contents"  : CAS-KEY(s)
    }

    Aeson Values ( extracted using gaia-utils )

    Object (
        fromList [
            (
                "contents",Array (
                    fromList [
                        String "f2debbc0395676188af9224f21beebde4dfde586",
                        String "ac5b36985f766835d0e43d365d60ad3f242e0d04",
                        String "bbbb65c8fdbb5c24ae960ec832f8f3c72c6ed5f3",
                        String "74060dab7e3754a7e698b878a23540283b254971",
                        String "684ea29239107360c1a96e594810bc4235caf288"
                    ]
                )
            ),
            ("aion-type",String "directory"),
            ("name",String "Desktop"),
            ("version",Number 1.0)
        ]
    )

    Object (
        fromList [
            ("hash",String "49f83f1f31fb9605a6d22f81acd59a7b39a40e4b"),
            ("size",Number 2143190.0),("aion-type",String "file"),
            ("name",String "1449085780693.jpg"),
            ("version",Number 1.0)
        ]
    )

    an object is a HashMap
    an array is a Vector
    a string is a Text
    a number is Scientific
        (
            because JSON doesn't specify precision and so a
            type which allows arbitrary precision is used
        )

-}

-- -----------------------------------------------------------
-- Note to self
-- -----------------------------------------------------------

{-

	In fact we do not need Aeson Values of even JSON strings.
	We simply need a simple string serialization/unserialization
	of TAionPoint(s).

	A departure from Genesis, but JSON string came up in there only because
	Ruby manipulate them very well.

-}

-- -----------------------------------------------------------
-- Build TAionPoint from Stored JSON Strings
-- -----------------------------------------------------------

{-
	This section is in essence what is needed to convert a JSON string into
	a TAionPoint passing through a Aeson Value
-}

getAionJSONStringForCASKey :: String -> MaybeT IO String
getAionJSONStringForCASKey hash = do
    value <- MaybeT $ CAS.get hash
    return  ( Char8.unpack value )

convertJSONStringIntoAesonValue :: String -> Maybe A.Value
convertJSONStringIntoAesonValue string = A.decode $ Char8.pack string

extractListOfPairsFromAesonValue :: A.Value -> [(T.Text ,A.Value)] -> [(T.Text ,A.Value)]
extractListOfPairsFromAesonValue (A.Object x) _ = HM.toList x
extractListOfPairsFromAesonValue _ defaultvalue = defaultvalue

extractUnderlyingTextFromAesonValueString :: A.Value -> String -> T.Text
extractUnderlyingTextFromAesonValueString (A.String x) _ = x
extractUnderlyingTextFromAesonValueString _ defaultvalue = T.pack defaultvalue

extractUnderlyingIntegerFromAesonValueNumber :: A.Value -> Integer -> Integer
extractUnderlyingIntegerFromAesonValueNumber (A.Number x) _ = S.coefficient x
extractUnderlyingIntegerFromAesonValueNumber _ defaultvalue = defaultvalue

extractUnderlyingListOfStringsFromAesonValueVectorString :: A.Value -> [String] -> [String]
extractUnderlyingListOfStringsFromAesonValueVectorString (A.Array x) _ =
    map (\v -> T.unpack $ extractUnderlyingTextFromAesonValueString v "" )
        ( V.toList x )
extractUnderlyingListOfStringsFromAesonValueVectorString _ defaultvalue = defaultvalue

aesonValueIsFile :: A.Value -> Bool
aesonValueIsFile aesonValue =
    let
        value1 = extractListOfPairsFromAesonValue aesonValue []
        answer = case lookup "aion-type" value1 of
            Nothing     -> False
            Just value3 -> ( extractUnderlyingTextFromAesonValueString value3 "" )=="file"
    in
        answer

aesonValueToTAionPoint :: A.Value -> TAionPoint
aesonValueToTAionPoint aesonvalue
    | aesonValueIsFile aesonvalue =
        let
            value1 = extractListOfPairsFromAesonValue aesonvalue [] -- [(T.Text ,A.Value)]

            filename =
                case Prelude.lookup "name" value1 of
                    Nothing -> ""
                    Just v2 -> T.unpack $ extractUnderlyingTextFromAesonValueString v2 ""

            filesize =
                case Prelude.lookup "size" value1 of
                    Nothing -> 0
                    Just s1 -> extractUnderlyingIntegerFromAesonValueNumber s1 0

            hash =
                case Prelude.lookup "hash" value1 of
                    Nothing -> ""
                    Just h1 -> T.unpack $ extractUnderlyingTextFromAesonValueString h1 ""

        in TAionPointFile filename filesize hash
    | otherwise =
        -- Here we make a leap of faith that if it's not a file it's a directory
        -- TODO: understand if is worth to move it to Either or Maybe with a
        --       check isDirectory or simply brutally panic if not a directory :P
        let
            value1 = extractListOfPairsFromAesonValue aesonvalue []

            foldername =
                case Prelude.lookup "name" value1 of
                    Nothing -> ""
                    Just v2 -> T.unpack $ extractUnderlyingTextFromAesonValueString v2 ""

            contents =
                case Prelude.lookup "contents" value1 of
                    Nothing -> []
                    Just c1 -> extractUnderlyingListOfStringsFromAesonValueVectorString c1 []
        in TAionPointDirectory foldername contents

-- -----------------------------------------------------------
-- Commit TAionPoint to disk
-- -----------------------------------------------------------

{-
	In this section we move from TAionPoint to JSON String on Disk
	passing through a Aeson Value.
	In this case we could as well build the JSON string directly from the TAionPoint
-}

makeAesonValueForFileUsingFileContents :: String -> Integer -> Char8.ByteString -> A.Value
makeAesonValueForFileUsingFileContents filename filesize filecontents =
    makeAesonValueForFileUsingKnownFileHash filename filesize ( SHA.showDigest $ SHA.sha1 filecontents )

makeAesonValueForFileUsingKnownFileHash :: String -> Integer -> String -> A.Value
makeAesonValueForFileUsingKnownFileHash filename filesize hash =
    A.Object $ E.fromList [
        ("aion-type" , A.String "file"),
        ("version"   , A.Number 1),
        ("name"      , A.String $ T.pack filename),
        ("size"      , A.Number $ S.scientific filesize 1 ),
        ("hash"      , A.String $ T.pack hash) ]

makeAesonValueForDirectoryUsingContentsAesonValues :: String -> [A.Value] -> A.Value
makeAesonValueForDirectoryUsingContentsAesonValues foldername aesonvalues =
    A.Object $ E.fromList [
            ("aion-type" , A.String "directory"),
            ("version"   , A.Number 1),
            ("name"      , A.String $ T.pack foldername),
            ("contents"  , A.Array $ V.fromList aesonvalues ) ]

makeAesonValueForDirectoryUsingContentsHashes :: String -> [String] -> A.Value
makeAesonValueForDirectoryUsingContentsHashes foldername hashes =
    A.Object $ E.fromList [
            ("aion-type" , A.String "directory"),
            ("version"   , A.Number 1),
            ("name"      , A.String $ T.pack foldername),
            ("contents"  , A.Array $ V.fromList ( map (A.String . T.pack ) hashes ) ) ]

aesonVAlueToString :: A.Value -> String
aesonVAlueToString value = Char8.unpack $ A.encode value

commitAesonValueToCAS :: A.Value -> IO String
commitAesonValueToCAS value = CAS.set $ Char8.pack $ aesonVAlueToString value

tAionPointToAesonValue :: TAionPoint -> A.Value
tAionPointToAesonValue ( TAionPointFile filename1 filesize1 hash1 )  = makeAesonValueForFileUsingKnownFileHash filename1 filesize1 hash1
tAionPointToAesonValue ( TAionPointDirectory foldername2 contents2 ) = makeAesonValueForDirectoryUsingContentsHashes foldername2 contents2



