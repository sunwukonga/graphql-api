{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-} -- for TypeError

module GraphQL.Server
  ( QueryError(..) -- XXX: Exporting constructor for tests. Not sure if that's what we really want.
  , HasGraph(..)
  , (:<>)(..)
  , (:<|>)(..)
  , ReadValue(..)
  , BuildFieldResolver(..)
  ) where

-- TODO (probably incomplete, the spec is large)
-- - input objects - I'm not super clear from the spec on how
--   they differ from normal objects.
-- - "extend type X" is used in examples in the spec but it's not
--   explained anywhere?
-- - Directives (https://facebook.github.io/graphql/#sec-Type-System.Directives)
-- - Enforce non-empty lists (might only be doable via value-level validation)

import Protolude hiding (Enum)
import GHC.TypeLits (KnownSymbol, symbolVal)
import qualified GHC.TypeLits as TypeLits

import qualified GraphQL.Value as GValue
import qualified Data.GraphQL.AST as AST
import GraphQL.API
import GraphQL.Internal.Input (CanonicalQuery)

import Control.Monad.Catch (MonadThrow, Exception)

-- | MonadThrow requires an instance of Exception so we create a
-- newtype for GraphQL errors.
newtype QueryError = QueryError Text deriving (Show, Eq)
instance Exception QueryError

-- TODO: throwM throws in the base monad, and that's often IO. If we
-- want to support PartialSuccess we need a different error model to
-- throwM.
queryError :: forall m a. MonadError QueryError m => Text -> m a
queryError = throwError . QueryError

-- | Object field separation operator.
--
-- Use this to provide handlers for fields of an object.
--
-- Say you had the following GraphQL type with \"foo\" and \"bar\" fields,
-- e.g.
--
-- @
--   type MyObject {
--     foo: Int!
--     bar: String!
--   }
-- @
--
-- You could provide handlers for it like this:
--
-- >>> :m +System.Environment
-- >>> let fooHandler = pure 42
-- >>> let barHandler = System.Environment.getProgName
-- >>> let myObjectHandler = pure $ fooHandler :<> barHandler :<> ()
data a :<> b = a :<> b
infixr 8 :<>

-- | Union type separation operator.
data a :<|> b = a :<|> b
infixr 8 :<|>


-- TODO instead of SelectionSet we want something like
-- NormalizedSelectionSet which has query fragments etc. resolved.
class HasGraph m a where
  type Handler m a
  buildResolver :: Handler m a -> CanonicalQuery -> m GValue.Value

-- | The ReadValue instance converts AST.Value types like ValueInt to
-- the type expected by the handler function. It's the boundary
-- between incoming types and your custom application Haskell types.
class ReadValue a where
  -- | Convert the already-parsed value into the type needed for the
  -- function call.
  readValue :: AST.Value -> Either Text a

  -- | valueMissing is a separate function so we can provide default
  -- values for certain cases. E.g. there is an instance for @@Maybe a@@
  -- that returns Nothing if the value is missing.
  valueMissing :: AST.Name -> Either Text a
  valueMissing name' = Left ("Value missing: " <> name')


-- TODO not super hot on individual values having to be instances of
-- HasGraph but not sure how else we can nest either types or
-- (Object _ _ fields). Maybe instead of field we need a "SubObject"?
instance forall m. Functor m => HasGraph m Int32 where
  type Handler m Int32 = m Int32
  -- TODO check that selectionset is empty (we expect a terminal node)
  buildResolver handler _ =  map GValue.toValue handler


instance forall m. Functor m => HasGraph m Double where
  type Handler m Double = m Double
  -- TODO check that selectionset is empty (we expect a terminal node)
  buildResolver handler _ =  map GValue.toValue handler

instance forall m. Functor m => HasGraph m Text where
  type Handler m Text = m Text
  -- TODO check that selectionset is empty (we expect a terminal node)
  buildResolver handler _ =  map GValue.toValue handler


instance forall m hg. (Applicative m, HasGraph m hg) => HasGraph m (List hg) where
  type Handler m (List hg) = [Handler m hg]
  buildResolver handler selectionSet =
    let a = traverse (flip (buildResolver @m @hg) selectionSet) handler
    in map GValue.toValue a

instance forall m ks enum. (MonadThrow m, MonadIO m, GraphQLEnum enum) => HasGraph m (Enum ks enum) where
  type Handler m (Enum ks enum) = enum
  buildResolver handler _ = pure (enumToValue handler)


-- TODO: lookup is O(N^2) in number of arguments (we linearly search
-- each argument in the list) but considering the graphql use case
-- where N usually < 10 this is probably OK.
lookupValue :: AST.Name -> [AST.Argument] -> Maybe AST.Value
lookupValue name args = case find (\(AST.Argument name' _) -> name' == name) args of
  Nothing -> Nothing
  Just (AST.Argument _ value) -> Just value

-- | Throw an error saying that @value@ does not have the @expected@ type.
wrongType :: (MonadError Text m, Show a) => Text -> a -> m b
wrongType expected value = throwError ("Wrong type, should be " <> expected <> show value)

instance ReadValue Int32 where
  readValue (AST.ValueInt v) = pure v
  readValue v = wrongType "Int" v

-- TODO: Double parsing is broken in graphql-haskell.
-- See https://github.com/jdnavarro/graphql-haskell/pull/16
instance ReadValue Double where
  readValue (AST.ValueFloat v) = pure v
  readValue v = wrongType "Double" v

instance ReadValue Bool where
  readValue (AST.ValueBoolean v) = pure v
  readValue v = wrongType "Bool" v

instance ReadValue Text where
  readValue (AST.ValueString (AST.StringValue v)) = pure v
  readValue v = wrongType "String" v

instance forall v. ReadValue v => ReadValue [v] where
  readValue (AST.ValueList (AST.ListValue values)) = traverse (readValue @v) values
  readValue v = wrongType "List" v

instance forall v. ReadValue v => ReadValue (Maybe v) where
  valueMissing _ = pure Nothing
  readValue v = map Just (readValue @v v)

-- TODO: variables should error, they should have been resolved already.
--
-- TODO: Objects. Maybe implement some Generic object reader? I.e. if I do
-- data Greet = Greet { name :: Text, score :: Int } deriving Generic
-- then "instance ReadValue Greet" would fall back on a default reader that
-- expects Objects?
-- Maybe we can use advanced fallbacks like these:
-- https://wiki.haskell.org/GHC/AdvancedOverlap

-- | Internal data type to capture a field's name + what to execute if
-- the name matches the query. Note that the name is *not* in monad m,
-- but the value is. This is necessary so we can skip execution if the
-- name doesn't match.
data NamedFieldExecutor m = NamedFieldExecutor AST.Name (m GValue.Value)

class (Applicative m) => BuildFieldResolver m a where
  type FieldHandler m a :: Type
  buildFieldResolver :: FieldHandler m a -> AST.Selection -> NamedFieldExecutor m

instance forall ks t m. (MonadError QueryError m, KnownSymbol ks, HasGraph m t) => BuildFieldResolver m (Field ks t) where
  type FieldHandler m (Field ks t) = Handler m t
  buildFieldResolver handler (AST.SelectionField (AST.Field _ _ _ _ selectionSet)) =
    let childResolver = buildResolver @m @t handler selectionSet
        name = toS (symbolVal (Proxy :: Proxy ks))
    in NamedFieldExecutor name childResolver
  buildFieldResolver _ f =
    NamedFieldExecutor "" (queryError ("buildFieldResolver got non AST.Field" <> show f <> ", query probably not normalized"))


instance forall ks t f m. (MonadError QueryError m, KnownSymbol ks, BuildFieldResolver m f, ReadValue t) => BuildFieldResolver m (Argument ks t :> f) where
  type FieldHandler m (Argument ks t :> f) = t -> FieldHandler m f
  buildFieldResolver handler selection@(AST.SelectionField (AST.Field _ _ arguments _ _)) =
    let argName = toS (symbolVal (Proxy :: Proxy ks))
        v = maybe (valueMissing @t argName) (readValue @t) (lookupValue argName arguments)
    in case v of
         Left err' -> NamedFieldExecutor "" (queryError err')
         Right v' -> buildFieldResolver @m @f (handler v') selection
  buildFieldResolver _ f =
    NamedFieldExecutor "" (queryError ("buildFieldResolver got non AST.Field" <> show f <> ", query probably not normalized"))


-- TODO we can probably use closed type families for RunFieldsType and
-- FieldHandler for better error reporting in case the user uses some
-- unexpected type.

class RunFields m a where
  type RunFieldsType m a :: Type
  -- Runfield is run on a single QueryTerm so it can only ever return
  -- one (Text, Value)
  runFields :: RunFieldsType m a -> AST.Selection -> m GValue.ObjectField


instance forall f fs m.
         ( MonadError QueryError m
         , BuildFieldResolver m f
         , RunFields m fs
         ) => RunFields m (f:fs) where
  type RunFieldsType m (f:fs) = (FieldHandler m f) :<> RunFieldsType m fs
  -- Deconstruct object type signature and handler value at the same
  -- time and run type-directed code for each field.
  runFields (lh :<> rh) selection@(AST.SelectionField (AST.Field alias name _ _ _)) =
    let NamedFieldExecutor k mValue = buildFieldResolver @m @f lh selection
    in case name == k of
      False -> runFields @m @fs rh selection
      True -> do
        -- execute action to retrieve field value
        value <- mValue
        -- NB "alias" is encoded in-band. It cannot be set to empty in
        -- a query so the empty value means "no alias" and we use the
        -- name instead.

        -- TODO: We need to use 'unsafeMakeName' here (which might panic)
        -- because our API is currently written in terms of the Data.GraphQL
        -- parser, which provides no type-level guarantees of name safety. We
        -- should instead have our APIs in terms of 'Canonicalquery' (and the
        -- rest of 'Data.GraphQL.Input', not yet written), and have that be
        -- responsible for rejecting queries with invalid names.
        let name' = GValue.unsafeMakeName $ if alias == "" then name else alias
        pure (GValue.ObjectField name' value)

  runFields _ f = queryError ("Unexpected Selection value. Is the query normalized?: " <> show f)

instance forall m. (MonadError QueryError m) => RunFields m '[] where
  type RunFieldsType m '[] = ()
  runFields _ selection = queryError ("Query for undefined selection:" <> show selection)


instance forall typeName interfaces fields m.
         ( MonadError QueryError m
         , RunFields m fields
         ) => HasGraph m (Object typeName interfaces fields) where
  type Handler m (Object typeName interfaces fields) = m (RunFieldsType m fields)

  buildResolver mHandler selectionSet = do
    -- First we run the actual handler function itself in IO.
    handler <- mHandler
    -- We're evaluating an Object so we're collecting ObjectFields from
    -- runFields and build a GValue.Map with them.
    r <- for selectionSet $ runFields @m @fields handler
    case GValue.makeObject r of
      Nothing -> queryError $ "Duplicate fields in set: " <> show r
      Just object -> pure $ GValue.ValueObject object


-- | Closed type family to enforce the invariant that Union types
-- contain only Objects.
type family RunUnionType m (a :: [Type]) :: Type where
  RunUnionType m (Object typeName interfaces fields:rest) = Handler m (Object typeName interfaces fields) :<|> RunUnionType m rest
  RunUnionType m '[] = ()
  RunUnionType m a = TypeLits.TypeError ('TypeLits.Text "All types in a union must be Object. Got: " 'TypeLits.:<>: 'TypeLits.ShowType a)


-- Type class to execute union type queries.
class RunUnion m a where
  runUnion :: RunUnionType m a -> AST.Selection -> m GValue.Object

instance forall m typeName interfaces fields rest.
         ( MonadError QueryError m
         , RunUnion m rest
         , RunFields m fields
         , KnownSymbol typeName
         ) => RunUnion m (Object typeName interfaces fields:rest) where
  runUnion (lh :<|> rh) fragment@(AST.SelectionInlineFragment (AST.InlineFragment (AST.NamedType queryTypeName) [] subSelection))
    | typeName == queryTypeName = do
        result <- buildResolver @m @(Object typeName interfaces fields) lh subSelection
        -- TODO: See if we can prevent this from happening at compile time.
        case GValue.toObject result of
          Nothing -> panic $ "Expected object as result of union query: " <> show result
          Just object -> pure object
    | otherwise = runUnion @m @rest rh fragment
    where typeName = toS (symbolVal (Proxy :: Proxy typeName))
  runUnion _ _ =
    queryError "Non-InlineFragment used for a union type query."

instance forall m. (MonadError QueryError m) => RunUnion m '[] where
  runUnion _ selection = queryError ("Union type could not be resolved:" <> show selection)

instance forall m ks ru.
         ( Applicative m
         , RunUnion m ru
         ) => HasGraph m (Union ks ru) where
  type Handler m (Union ks ru) = RunUnionType m ru
  -- TODO: check sanity of query before executing it. E.g. we can't
  -- have the same field name in two different fragment branches
  -- (needs to take aliases into account).

  -- query "{ ... on Human { name } }"
  -- [SelectionInlineFragment (InlineFragment (NamedType "Human") [] [SelectionField (Field "" "name" [] [] [])])]
  buildResolver handler selection = do
    -- GraphQL invariant is that all items in a Union must be objects
    -- which means 1) they have fields 2) They are ValueMap
    maybe (panic $ "Duplicate fields in values") GValue.ValueObject <$> map GValue.unionObjects (traverse (runUnion @m @ru handler) selection)