{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DoAndIfThenElse #-}
module Data.Time.Parsers where

import Data.Time.Parsers.Types
import Data.Time.Parsers.Util
import Data.Time.Parsers.Tables             (weekdays)

import Control.Applicative                  ((<$>),(<*>),(<|>))
import Control.Monad.Reader
import Data.Attoparsec.Char8                as A
import Data.Attoparsec.FastSet              (set, FastSet, memberChar)
import Data.Char                            (toUpper)
import Data.Fixed                           (Pico)
import Data.Set                             (fromList)
import Data.Time                            hiding (parseTime)
import Data.Time.Clock.POSIX                (POSIXTime)
import qualified Data.ByteString.Char8      as B

--Utility Parsers

nDigit :: (Read a, Num a) => Int -> Parser a
nDigit n = read <$> count n digit

parseDateToken :: FastSet -> Parser DateToken
parseDateToken seps' = readDateToken =<< (takeTill $ flip memberChar seps')

parsePico :: Parser Pico
parsePico = (+) <$> (fromInteger <$> decimal) <*> (option 0 postradix)
  where
    postradix = do
        _ <- char '.'
        bs <- A.takeWhile isDigit
        let i = fromInteger . read . B.unpack $ bs
            l = B.length bs
        return (i/10^l)

isBCE :: OptionedParser Bool
isBCE = lift . option False $ const True <$> isBCE'
  where
    isBCE' = skipSpace >> (string "BCE" <|> string "BC")

skipWeekday :: Parser ()
skipWeekday = option () $
              ( choice $ map stringCI weekdays ) >>
              (option undefined $ char ',')      >>
              skipSpace

onlyParse :: OptionedParser a -> OptionedParser a
onlyParse p = p >>= (\r -> lift endOfInput >> return r)

--Date Parsers

fourTwoTwo :: OptionedParser Day
fourTwoTwo = lift fourTwoTwo'

fourTwoTwo' :: Parser Day
fourTwoTwo' = skipWeekday >>
              (fromGregorianValid <$> nDigit 4 <*> nDigit 2 <*> nDigit 2) >>=
              maybe (fail "Invalid Date Range") return

twoTwoTwo :: OptionedParser Day
twoTwoTwo = isFlagSet MakeRecent >>= lift . twoTwoTwo'

twoTwoTwo' :: Bool -> Parser Day
twoTwoTwo' mr =
    skipWeekday >>
    (fromGregorianValid <$> nDigit 2 <*> nDigit 2 <*> nDigit 2) >>=
    maybe (fail "Invalid Date Range") return'
  where
    return' = if mr then return . forceRecent else return

charSeparated :: OptionedParser Day
charSeparated = do
    s <- asks seps
    f <- asks formats
    m <- isFlagSet MakeRecent
    lift $ charSeparated' s f m

charSeparated' :: FastSet -> [DateFormat] -> Bool -> Parser Day
charSeparated' seps' formats' makeRecent' = do
    a   <- parseDateToken seps'
    sep <- satisfy $ flip memberChar seps'
    b   <- parseDateToken seps'
    _   <- satisfy (==sep)
    c   <- readDateToken =<< A.takeWhile isDigit
    let noYear (Year _) = False
        noYear _        = True
        noExplicitYear  = and . map noYear $ [a,b,c]
    date <- tryFormats formats' =<< (return $ makeDate a b c)
    if (makeRecent' && noExplicitYear)
    then return $ forceRecent date
    else return date

fullDate :: OptionedParser Day
fullDate = isFlagSet MakeRecent >>= lift . fullDate'

fullDate' :: Bool -> Parser Day
fullDate' makeRecent' = do
    skipWeekday
    month <- maybe mzero (return . Month) <$>
             lookupMonth =<< (A.takeWhile isAlpha_ascii)
    _     <- space
    day   <- Any . read . B.unpack <$> A.takeWhile isDigit
    _     <- string ", "
    year  <- readDateToken =<< A.takeWhile isDigit
    let forceRecent' = if (noYear year && makeRecent')
                       then forceRecent
                       else id
    forceRecent' <$> makeDate month day year MDY
  where
    noYear (Year _) = False
    noYear _        = True

yearDayOfYear :: OptionedParser Day
yearDayOfYear = do
    s <- asks seps
    lift $ yearDayOfYear' s

yearDayOfYear' :: FastSet -> Parser Day
yearDayOfYear' seps' = do
    year <- nDigit 4
    day  <- maybeSep >> nDigit 3
    yearDayToDate year day
  where
    maybeSep = option () $ satisfy (flip memberChar seps') >> return ()

julianDay :: OptionedParser Day
julianDay = lift julianDay'

julianDay' :: Parser Day
julianDay' = skipWeekday >>
             (string "Julian" <|> string "JD" <|> string "J") >>
             ModifiedJulianDay <$> signed decimal

--Time Parsers

twelveHour :: OptionedParser TimeOfDay
twelveHour = lift twelveHour'

twelveHour' :: Parser TimeOfDay
twelveHour' = do
    h'   <- (nDigit 2 <|> nDigit 1)
    m    <- option 0 $ char ':' >> nDigit 2
    s    <- option 0 $ char ':' >> parsePico
    ampm <- B.map toUpper <$> (skipSpace >> (stringCI "AM" <|> stringCI "PM"))
    h    <- case ampm of
      "AM" -> make24 False h'
      "PM" -> make24 True h'
      _    -> fail "Should be impossible."
    maybe (fail "Invalid Time Range") return $
      makeTimeOfDayValid h m s
  where
    make24 pm h = case compare h 12 of
        LT -> return $ if pm then (h+12) else h
        EQ -> return $ if pm then 12 else 0
        GT -> mzero

twentyFourHour :: OptionedParser TimeOfDay
twentyFourHour = lift twentyFourHour'

twentyFourHour' :: Parser TimeOfDay
twentyFourHour' = maybe (fail "Invalid Time Range") return =<<
                  (colon <|> nocolon)
  where
    colon = makeTimeOfDayValid <$>
            (nDigit 2 <|> nDigit 1) <*>
            (char ':' >> nDigit 2) <*>
            (option 0 $ char ':' >> parsePico)
    nocolon = makeTimeOfDayValid <$>
              nDigit 2 <*>
              option 0 (nDigit 2) <*>
              option 0 parsePico

--TimeZone Parsers

offsetTimezone :: OptionedParser TimeZone
offsetTimezone = lift offsetTimezone'

offsetTimezone' :: Parser TimeZone
offsetTimezone' =  (char 'Z' >> return utc) <|>
                   ((plus <|> minus) <*> timezone'')
  where
    plus  = char '+' >> return minutesToTimeZone
    minus = char '-' >> return (minutesToTimeZone . negate)
    hour p = p >>= (\n -> if (n < 24) then (return $ 60*n) else mzero)
    minute  p = option () (char ':' >> return ()) >> p >>=
                (\n -> if (n < 60) then return n else mzero)
    timezone'' = choice [ (+) <$> (hour $ nDigit 2) <*> (minute $ nDigit 2)
                        , (+) <$> (hour $ nDigit 1) <*> (minute $ nDigit 2)
                        , hour $ nDigit 2
                        , hour $ nDigit 1
                        ]

namedTimezone :: OptionedParser TimeZone
namedTimezone = isFlagSet AustralianTimezones >>= lift . namedTimezone'

namedTimezone' :: Bool -> Parser TimeZone
namedTimezone' aussie = (lookup' <$> A.takeWhile isAlpha_ascii) >>=
                        maybe (fail "Invalid Timezone") return
  where
    lookup' = if aussie then lookupAusTimezone else lookupTimezone

--Timestamp Parsers

posixTime :: OptionedParser POSIXTime
posixTime = isFlagSet RequirePosixUnit >>= lift . posixTime'

posixTime' :: Bool -> Parser POSIXTime
posixTime' requireS = do
    r <- rational
    when requireS $ char 's' >> return ()
    return r

zonedTime :: OptionedParser LocalTime ->
             OptionedParser TimeZone ->
             OptionedParser ZonedTime
zonedTime localT timezone = do
    defaultToUTC <- isFlagSet DefaultToUTC
    let timezone'  = (option undefined $ lift space) >> timezone
        mtimezone  = if defaultToUTC
                     then (option utc timezone')
                     else timezone'
    zonedT <- ZonedTime <$> localT <*> mtimezone
    bce <- isBCE
    if bce then makeBCE' zonedT else return zonedT
  where
    makeBCE' (ZonedTime (LocalTime d t) tz) =
        makeBCE d >>= \d' -> return $ ZonedTime (LocalTime d' t) tz

localTime :: OptionedParser Day ->
             OptionedParser TimeOfDay ->
             OptionedParser LocalTime
localTime date time = do
    defaultToMidnight <- isFlagSet DefaultToMidnight
    let time' = (lift $ char 'T' <|> space) >> time
        mtime = if defaultToMidnight
                then (option midnight time')
                else time'
    localT <- LocalTime <$> date <*> mtime
    bce <- isBCE
    if bce then makeBCE' localT else return localT
  where
    makeBCE' (LocalTime d t) = makeBCE d >>= \d' -> return $ LocalTime d' t

--Defaults and Debugging

defaultOptions :: Options
defaultOptions = Options { formats = [YMD,DMY,MDY]
                         , seps = set ". /-"
                         , flags = fromList [ MakeRecent
                                            , DefaultToUTC
                                            , DefaultToMidnight
                                            ]
                         }

defaultDay :: OptionedParser Day
defaultDay = do date <- defaultDayCE
                bce  <- isBCE
                if bce then makeBCE date else return date

defaultDayCE :: OptionedParser Day
defaultDayCE = charSeparated <|>
                fourTwoTwo    <|>
                yearDayOfYear <|>
                twoTwoTwo     <|>
                fullDate      <|>
                julianDay

defaultTimeOfDay :: OptionedParser TimeOfDay
defaultTimeOfDay = twelveHour <|> twentyFourHour

defaultTimeZone :: OptionedParser TimeZone
defaultTimeZone = namedTimezone <|> offsetTimezone

defaultLocalTime :: OptionedParser LocalTime
defaultLocalTime = localTime defaultDayCE defaultTimeOfDay

defaultZonedTime :: OptionedParser ZonedTime
defaultZonedTime = zonedTime defaultLocalTime defaultTimeZone

defaultTimeStamp :: FromZonedTime a => OptionedParser a
defaultTimeStamp = fromZonedTime <$> defaultTimeStamp'
  where
    defaultTimeStamp' = onlyParse defaultZonedTime <|>
                        (posixToZoned <$> posixTime)

parseWithOptions :: Options -> OptionedParser a ->
                    B.ByteString -> Result a
parseWithOptions opt p = flip feed B.empty . (parse $ runReaderT p' opt)
  where
    p' = onlyParse p

parseWithDefaultOptions :: OptionedParser a -> B.ByteString -> Result a
parseWithDefaultOptions = parseWithOptions defaultOptions