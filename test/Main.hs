{-# LANGUAGE ScopedTypeVariables #-}
import Common
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.HStore
import Control.Exception as E
import Control.Monad
import Data.ByteString (ByteString)
import Data.Typeable
import qualified Data.ByteString as B
import qualified Data.Map as Map
import Data.Text(Text)
import System.Exit (exitFailure)
import System.IO
import qualified Data.Vector as V

import Notify
import Serializable
import Time

tests :: [TestEnv -> Test]
tests =
    [ TestLabel "Bytea"         . testBytea
    , TestLabel "ExecuteMany"   . testExecuteMany
    , TestLabel "Fold"          . testFold
    , TestLabel "Notify"        . testNotify
    , TestLabel "Serializable"  . testSerializable
    , TestLabel "Time"          . testTime
    , TestLabel "Array"         . testArray
    , TestLabel "HStore"        . testHStore
    ]

testBytea :: TestEnv -> Test
testBytea TestEnv{..} = TestList
    [ testStr "empty"                  []
    , testStr "\"hello\""              $ map (fromIntegral . fromEnum) ("hello" :: String)
    , testStr "ascending"              [0..255]
    , testStr "descending"             [255,254..0]
    , testStr "ascending, doubled up"  $ doubleUp [0..255]
    , testStr "descending, doubled up" $ doubleUp [255,254..0]
    ]
  where
    testStr label bytes = TestLabel label $ TestCase $ do
        let bs = B.pack bytes

        [Only h] <- query conn "SELECT md5(?::bytea)" [Binary bs]
        assertBool "Haskell -> SQL conversion altered the string" $ md5 bs == h

        [Only (Binary r)] <- query conn "SELECT ?::bytea" [Binary bs]
        assertBool "SQL -> Haskell conversion altered the string" $ bs == r

    doubleUp = concatMap (\x -> [x, x])

testExecuteMany :: TestEnv -> Test
testExecuteMany TestEnv{..} = TestCase $ do
    execute_ conn "CREATE TEMPORARY TABLE tmp_executeMany (i INT, t TEXT, b BYTEA)"

    let rows :: [(Int, String, Binary ByteString)]
        rows = [ (1, "hello", Binary "bye")
               , (2, "world", Binary "\0\r\t\n")
               , (3, "?",     Binary "")
               ]

    count <- executeMany conn "INSERT INTO tmp_executeMany VALUES (?, ?, ?)" rows
    count @?= fromIntegral (length rows)

    rows' <- query_ conn "SELECT * FROM tmp_executeMany"
    rows' @?= rows

    return ()

testFold :: TestEnv -> Test
testFold TestEnv{..} = TestCase $ do
    xs <- fold_ conn "SELECT generate_series(1,10000)"
            [] $ \xs (Only x) -> return (x:xs)
    reverse xs @?= ([1..10000] :: [Int])

    -- TODO: add more complete tests, e.g.:
    --
    --  * Fold in a transaction
    --
    --  * Fold in a transaction after a previous fold has been performed
    --
    --  * Nested fold

    return ()

queryFailure :: forall a. (FromField a, Typeable a, Show a)
             => Connection -> Query -> a -> Assertion
queryFailure conn q resultType = do
  x :: Either SomeException [Only a] <- E.try $ query_ conn q
  case x of
    Left  _   -> return ()
    Right val -> assertFailure ("Did not fail as expected:  "
                              ++ show q
                              ++ " :: "
                              ++ show (typeOf resultType)
                              ++ " -> " ++ show val)

testArray :: TestEnv -> Test
testArray TestEnv{..} = TestCase $ do
    xs <- query_ conn "SELECT '{1,2,3,4}'::_int4"
    xs @?= [Only (V.fromList [1,2,3,4 :: Int])]
    xs <- query_ conn "SELECT '{{1,2},{3,4}}'::_int4"
    xs @?= [Only (V.fromList [V.fromList [1,2],
                              V.fromList [3,4 :: Int]])]
    queryFailure conn "SELECT '{1,2,3,4}'::_int4" (undefined :: V.Vector Bool)
    queryFailure conn "SELECT '{{1,2},{3,4}}'::_int4" (undefined :: V.Vector Int)

testHStore :: TestEnv -> Test
testHStore TestEnv{..} = TestCase $ do
    roundTrip []
    roundTrip [("foo","bar"),("bar","baz"),("baz","hello")]
    roundTrip [("fo\"o","bar"),("b\\ar","baz"),("baz","\"value\\with\"escapes")]
  where
    roundTrip :: [(Text,Text)] -> Assertion
    roundTrip xs = do
      let m = Only (HStoreMap (Map.fromList xs))
      m' <- query conn "SELECT ?::hstore" m
      [m] @?= m'

------------------------------------------------------------------------

-- | Action for connecting to the database that will be used for testing.
--
-- Note that some tests, such as Notify, use multiple connections, and assume
-- that 'testConnect' connects to the same database every time it is called.
testConnect :: IO Connection
testConnect = connectPostgreSQL ""

withTestEnv :: (TestEnv -> IO a) -> IO a
withTestEnv cb =
    withConn $ \conn ->
        cb TestEnv
            { conn     = conn
            , withConn = withConn
            }
  where
    withConn = bracket testConnect close

main :: IO ()
main = do
    mapM_ (`hSetBuffering` LineBuffering) [stdout, stderr]
    Counts{cases, tried, errors, failures} <-
        withTestEnv $ \env -> runTestTT $ TestList $ map ($ env) tests
    when (cases /= tried || errors /= 0 || failures /= 0) $ exitFailure
