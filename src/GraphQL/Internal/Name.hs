-- | Representation of GraphQL names.
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module GraphQL.Internal.Name
  ( Name(unName, Name)
  , mempty
  , NameError(..)
  , makeName
  , nameFromSymbol
  , nameParser
  -- * Named things
  , HasName(..)
  -- * Unsafe functions
  , unsafeMakeName
  ) where

import Protolude

import qualified Data.Aeson as Aeson
import GHC.TypeLits (Symbol, KnownSymbol, symbolVal)
import Data.Char (isDigit)
import Data.Text as T (Text)
import qualified Data.Attoparsec.Text as A
import Test.QuickCheck (Arbitrary(..), elements, listOf)
import Data.String (IsString(..))
import Data.Text as T (Text, append, empty)

import GraphQL.Internal.Syntax.Tokens (tok)

-- * Name

-- | A name in GraphQL.
--
-- https://facebook.github.io/graphql/#sec-Names
newtype Name = Name { unName :: T.Text } deriving (Eq, Ord, Show)

instance Monoid Name where
    mempty  = Name T.empty
--    mappend (Name {a}) mempty = Name {a}
--    mappend mempty (Name {b}) = Name {b}
    mappend (Name a1) (Name a2) = Name (T.append a1 a2)
--    mappend = append
--    mconcat = concat

--newtype Any = Any { getAny :: Bool }

--instance Monoid Any where
--    mempty = Any False
--    (Any b1) `mappend` (Any b2) = Any (b1 || b2)

-- | Create a 'Name', panicking if the given text is invalid.
--
-- Prefer 'makeName' to this in all cases.
--
-- >>> unsafeMakeName "foo"
-- Name {unName = "foo"}
unsafeMakeName :: HasCallStack => Text -> Name
unsafeMakeName name =
  case makeName name of
    Left e -> panic (show e)
    Right n -> n

-- | Create a 'Name'.
--
-- Names must match the regex @[_A-Za-z][_0-9A-Za-z]*@. If the given text does
-- not match, return Nothing.
--
-- >>> makeName "foo"
-- Right (Name {unName = "foo"})
-- >>> makeName "9-bar"
-- Left (NameError "9-bar")
makeName :: Text -> Either NameError Name
makeName name = first (const (NameError name)) (A.parseOnly nameParser name)

-- | Parser for 'Name'.
nameParser :: A.Parser Name
nameParser = Name <$> tok ((<>) <$> A.takeWhile1 isA_z
                                <*> A.takeWhile ((||) <$> isDigit <*> isA_z))
  where
    -- `isAlpha` handles many more Unicode Chars
    isA_z = A.inClass $ '_' : ['A'..'Z'] <> ['a'..'z']

-- | An invalid name.
newtype NameError = NameError Text deriving (Eq, Show)

-- | Convert a type-level 'Symbol' into a GraphQL 'Name'.
nameFromSymbol :: forall (n :: Symbol). KnownSymbol n => Either NameError Name
nameFromSymbol = makeName (toS (symbolVal @n Proxy))

-- | Types that implement this have values with a single canonical name in a
-- GraphQL schema.
--
-- e.g. a field @foo(bar: Int32)@ would have the name @\"foo\"@.
--
-- If a thing *might* have a name, or has a name that might not be valid,
-- don't use this.
--
-- If a thing is aliased, then return the *original* name.
class HasName a where
  -- | Get the name of the object.
  getName :: a -> Name

instance IsString Name where
  fromString = unsafeMakeName . toS

instance Aeson.ToJSON Name where
  toJSON = Aeson.toJSON . unName

instance Arbitrary Name where
  arbitrary = do
    initial <- elements alpha
    rest <- listOf (elements (alpha <> numeric))
    pure (Name (toS (initial:rest)))
    where
      alpha = ['A'..'Z'] <> ['a'..'z'] <> ['_']
      numeric = ['0'..'9']
