{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Vehicle.Language.Print
  ( PrettyUsing(..)
  , PrettyWith
  , Tags(..)
  , prettySimple
  , prettyVerbose
  , prettyFriendly
  , prettyFriendlyDB
  , prettyFriendlyDBClosed
  ) where

import GHC.TypeLits (TypeError, ErrorMessage(..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.IntMap (IntMap)
import Control.Exception (assert)
import Prettyprinter (list)

import Vehicle.Internal.Print as Internal (printTree, Print)
import Vehicle.External.Print as External (printTree, Print)
import Vehicle.Internal.Abs qualified as BC
import Vehicle.External.Abs qualified as BF

import Vehicle.Prelude
import Vehicle.Language.AST
import Vehicle.Compile.Simplify
import Vehicle.Compile.Delaborate.Internal as Internal
import Vehicle.Compile.Delaborate.External as External
import Vehicle.Compile.Descope
import Vehicle.Compile.SupplyNames
import Vehicle.Compile.Type.Constraint
import Vehicle.Compile.Type.MetaSubstitution (MetaSubstitution(MetaSubstitution))
import Vehicle.Compile.CoDeBruijnify (ConvertCodebruijn(..))
import Vehicle.Compile.Prelude


-- The old methods for compatibility:

-- |Prints to the internal language removing all implicit/instance arguments and
-- automatically inserted code. Does not convert (Co)DeBruijn indices back to names.
prettySimple :: (PrettyWith ('Simple ('As 'Internal)) a) => a -> Doc b
prettySimple = prettyWith @('Simple ('As 'Internal))

-- |Prints to the internal language in all it's gory detail. Does not convert (Co)DeBruijn
-- indices back to names. Useful for debugging.
prettyVerbose :: (PrettyWith ('As 'Internal) a) => a -> Doc b
prettyVerbose = prettyWith @('As 'Internal)

-- |Prints to the external language for things that need to be displayed to
-- the user.
prettyFriendly :: (PrettyWith ('Named ('As 'External)) a) => a -> Doc b
prettyFriendly = prettyWith @('Named ('As 'External))

-- |Prints to the external language for things that need to be displayed to
-- the user. Use this when the expression is using DeBruijn indices and is
-- not closed.
prettyFriendlyDB :: (PrettyWith ('Named ('As 'External)) ([DBBinding], a))
                 => [DBBinding] -> a -> Doc b
prettyFriendlyDB ctx e = prettyWith @('Named ('As 'External)) (ctx, e)

-- | This is identical to |prettyFriendly|, but exists for historical reasons.
prettyFriendlyDBClosed :: (PrettyWith ('Simple ('Named ('As 'External))) a) => a -> Doc b
prettyFriendlyDBClosed = prettyWith @('Simple ('Named ('As 'External)))



-- The new methods are defined in terms of tags:

type PrettyWith (tags :: Tags) a = PrettyUsing (StrategyFor tags a) a

data Tags
  = As VehicleLang -- ^ The final tag denotes which output grammar should be used
  | Named Tags     -- ^ The named tag ensures that the term is converted back to using named binders
  | Simple Tags    -- ^ The simple tag ensures that superfluous information is erased

prettyWith :: forall tags a b. PrettyWith tags a => a -> Doc b
prettyWith = prettyUsing @(StrategyFor tags a) @a @b


-- Tags are used to compute a printing strategy:
data Strategy
  = ConvertTo            VehicleLang
  | DBToNamedNaive       Strategy
  | DBToNamedOpen        Strategy
  | DBToNamedClosed      Strategy
  | CoDBToNamedNaive     Strategy
  | CoDBToDBOpen         Strategy
  | CoDBToDBClosed       Strategy
  | SupplyNamesOpen      Strategy
  | SupplyNamesClosed    Strategy
  | SimplifyWithOptions  Strategy
  | SimplifyDefault      Strategy
  | MapList              Strategy
  | MapIntMap            Strategy
  | MapTuple2            Strategy Strategy
  | MapTuple3            Strategy Strategy Strategy
  | Opaque               Strategy
  | Pretty

-- | Compute the printing strategy given the tags and the type of the expression.
type family StrategyFor (tags :: Tags) a :: Strategy where
  StrategyFor ('As lang) (t NamedBinding NamedVar ann)
    = 'ConvertTo lang

  StrategyFor ('As lang) (t NamedBinding DBVar ann)
    = 'DBToNamedNaive ('ConvertTo lang)

  StrategyFor ('As lang) (t (NamedBinding, Maybe PositionTree) CoDBVar ann)
    = 'CoDBToNamedNaive ('ConvertTo lang)

  -- Conversion to Named AST
  StrategyFor ('Named tags) (t NamedBinding NamedVar ann)
    = StrategyFor tags (t NamedBinding NamedVar ann)

  StrategyFor ('Named tags) ([NamedBinding], t NamedBinding DBVar ann)
    = 'DBToNamedOpen (StrategyFor tags (t NamedBinding NamedVar ann))

  StrategyFor ('Named tags) (t NamedBinding DBVar ann)
    = 'DBToNamedClosed (StrategyFor tags (t NamedBinding NamedVar ann))

  StrategyFor ('Named tags) ([DBBinding], t CoDBBinding CoDBVar ann, BoundVarMap)
    = 'CoDBToDBOpen (StrategyFor ('Named tags) ([DBBinding], t DBBinding DBVar ann))

  StrategyFor ('Named tags) (t CoDBBinding CoDBVar ann, BoundVarMap)
    = 'CoDBToDBClosed (StrategyFor tags (t DBBinding DBVar ann))

  -- Supplying names
  StrategyFor tags ([DBBinding], t DBBinding var ann)
    = 'SupplyNamesOpen (StrategyFor tags ([Symbol], t NamedBinding var ann))

  StrategyFor tags (t DBBinding var ann)
    = 'SupplyNamesClosed (StrategyFor tags (t NamedBinding var ann))

  StrategyFor tags ([DBBinding], t CoDBBinding var ann)
    = 'SupplyNamesOpen (StrategyFor tags ([DBBinding], t (Symbol, Maybe PositionTree) var ann))

  StrategyFor tags (t CoDBBinding var ann)
    = 'SupplyNamesClosed (StrategyFor tags (t (NamedBinding, Maybe PositionTree) var ann))

  StrategyFor tags PositionsInExpr
    = 'Opaque (StrategyFor tags CheckedExpr)

  -- Simplification
  StrategyFor ('Simple tags) (SimplifyOptions, a)
    = 'SimplifyWithOptions (StrategyFor tags a)

  StrategyFor ('Simple tags) a
    = 'SimplifyDefault (StrategyFor tags a)

  -- Other
  StrategyFor tags Constraint
    = 'Opaque (StrategyFor tags BaseConstraint)

  StrategyFor tags BaseConstraint
    = 'Opaque (StrategyFor tags CheckedExpr)

  StrategyFor tags MetaSubstitution
    = 'Opaque (StrategyFor tags CheckedExpr)

  StrategyFor tags DBBinding
    = 'Pretty

  StrategyFor tags PositionTree
    = 'Pretty

  StrategyFor tags Int
    = 'Pretty

  StrategyFor tags [a]
    = 'MapList (StrategyFor tags a)

  StrategyFor tags (IntMap a)
    = 'MapIntMap (StrategyFor tags a)

  StrategyFor tags (a, b)
    = 'MapTuple2 (StrategyFor tags a) (StrategyFor tags b)

  StrategyFor tags (a, b, c)
    = 'MapTuple3 (StrategyFor tags a) (StrategyFor tags b) (StrategyFor tags c)

  StrategyFor tags a
    = TypeError ('Text "Cannot print value of type " ':<>: 'ShowType a ':<>: 'Text "."
           ':$$: 'Text "Perhaps you could add support to Vehicle.Language.Print.StrategyFor?")


-- The printing strategy guides the type class resolution:

class PrettyUsing (strategy :: Strategy) a where
  prettyUsing :: a -> Doc b

instance (Internal.Delaborate t bnfc, Pretty bnfc)
      => PrettyUsing ('ConvertTo 'Internal) (t ann) where
  prettyUsing e = pretty (Internal.delab @t @bnfc e)

instance (External.Delaborate t bnfc, Pretty bnfc)
      => PrettyUsing ('ConvertTo 'External) (t ann) where
  prettyUsing e = pretty (External.delab @t @bnfc e)

instance (Descope t, PrettyUsing rest (t Symbol Symbol ann))
      => PrettyUsing ('DBToNamedNaive rest) (t Symbol DBVar ann) where
  prettyUsing e = prettyUsing @rest (runNaiveDBDescope e)

instance (Descope t, ExtractPositionTrees t, PrettyUsing rest (t Symbol Symbol ann))
      => PrettyUsing ('CoDBToNamedNaive rest) (t (Symbol, Maybe PositionTree) CoDBVar ann) where
  prettyUsing e = let (e', pts) = runNaiveCoDBDescope e in
    prettyUsing @rest e' <+> prettyMap pts

instance (Descope t, PrettyUsing rest (t Symbol Symbol ann))
      => PrettyUsing ('DBToNamedOpen rest) ([Symbol], t Symbol DBVar ann) where
  prettyUsing (ctx, e) = prettyUsing @rest (runDescope ctx e)

instance (Descope t, PrettyUsing rest (t Symbol Symbol ann))
      => PrettyUsing ('DBToNamedClosed rest) (t Symbol DBVar ann) where
  prettyUsing e = prettyUsing @rest (runDescope mempty e)

instance (ConvertCodebruijn t, PrettyUsing rest ([DBBinding], t DBBinding DBVar ann))
      => PrettyUsing ('CoDBToDBOpen rest) ([DBBinding], t CoDBBinding CoDBVar ann, BoundVarMap) where
  prettyUsing (ctx, e, bvm) = prettyUsing @rest (ctx , fromCoDB (e, bvm))

instance (ConvertCodebruijn t, PrettyUsing rest (t DBBinding DBVar ann))
      => PrettyUsing ('CoDBToDBClosed rest) (t CoDBBinding CoDBVar ann, BoundVarMap) where
  prettyUsing (e, bvm) = assert (null bvm) $ prettyUsing @rest (fromCoDB (e, bvm))

instance (SupplyNames t, PrettyUsing rest ([Symbol], t Symbol var ann))
      => PrettyUsing ('SupplyNamesOpen rest) ([DBBinding], t DBBinding var ann) where
  prettyUsing p = prettyUsing @rest (supplyDBNamesWithCtx p)

instance (SupplyNames t, PrettyUsing rest (t Symbol var ann))
      => PrettyUsing ('SupplyNamesClosed rest) (t DBBinding var ann) where
  prettyUsing e = prettyUsing @rest (supplyDBNames e)

instance (SupplyNames t, PrettyUsing rest ([Symbol], t (Symbol, Maybe PositionTree) var ann))
      => PrettyUsing ('SupplyNamesOpen rest) ([DBBinding], t CoDBBinding var ann) where
  prettyUsing p = prettyUsing @rest (supplyCoDBNamesWithCtx p)

instance (SupplyNames t, PrettyUsing rest (t (Symbol, Maybe PositionTree) var ann))
      => PrettyUsing ('SupplyNamesClosed rest) (t CoDBBinding var ann) where
  prettyUsing e = prettyUsing @rest (supplyCoDBNames e)

instance (Simplify a, PrettyUsing rest a)
      => PrettyUsing ('SimplifyWithOptions rest) (SimplifyOptions, a) where
  prettyUsing (options, e) = prettyUsing @rest (simplifyWith options e)

instance (Simplify a, PrettyUsing rest a)
      => PrettyUsing ('SimplifyDefault rest) a where
  prettyUsing e = prettyUsing @rest (simplify e)

instance PrettyUsing rest a
      => PrettyUsing ('MapList rest) [a] where
  prettyUsing es = list (prettyUsing @rest <$> es)

instance PrettyUsing rest a
      => PrettyUsing ('MapIntMap rest) (IntMap a) where
  prettyUsing es = prettyIntMap (prettyUsing @rest <$> es)

instance (PrettyUsing resta a, PrettyUsing restb b)
      => PrettyUsing ('MapTuple2 resta restb) (a, b) where
  prettyUsing (e1, e2) = "(" <> prettyUsing @resta e1 <> "," <+> prettyUsing @restb e2 <> ")"

instance (PrettyUsing resta a, PrettyUsing restb b, PrettyUsing restc c)
      => PrettyUsing ('MapTuple3 resta restb restc) (a, b, c) where
  prettyUsing (e1, e2, e3) =
    "(" <>  prettyUsing @resta e1 <>
    "," <+> prettyUsing @restb e2 <>
    "," <+> prettyUsing @restc e3 <>
    ")"

-- instances which defer to primitive pretty instances

instance Pretty a => PrettyUsing 'Pretty a where
  prettyUsing = pretty

-- instances for opaque types BaseConstraint, Constraint, and MetaSubstitution

instance PrettyUsing rest CheckedExpr
      => PrettyUsing ('Opaque rest) BaseConstraint where
  prettyUsing (Unify (e1, e2)) = prettyUsing @rest e1 <+> "~" <+> prettyUsing @rest e2
  prettyUsing (m `Has` e)      = pretty m <+> "<=" <+> prettyUsing @rest e

instance PrettyUsing rest BaseConstraint
      => PrettyUsing ('Opaque rest) Constraint where
  prettyUsing c = prettyUsing @rest (baseConstraint c)
    -- <+> "<boundCtx=" <> pretty (ctxNames (boundContext c)) <> ">"
    -- <+> parens (pretty (provenanceOf c))

instance PrettyUsing rest CheckedExpr
      => PrettyUsing ('Opaque rest) MetaSubstitution where
  prettyUsing (MetaSubstitution m) = prettyIntMap (prettyUsing @rest <$> m)

instance (PrettyUsing rest CheckedExpr)
      => PrettyUsing ('Opaque rest) PositionsInExpr where
  prettyUsing (PositionsInExpr e p) = prettyUsing @rest (fromCoDB (substPos hole (Just p) e))
    where hole = (Hole mempty $ Text.pack "@", mempty)

-- Pretty instances for the BNFC data types

newtype ViaBnfcInternal a = ViaBnfcInternal a

instance Internal.Print a => Pretty (ViaBnfcInternal a) where
  pretty (ViaBnfcInternal e) = pretty (bnfcPrintHack (Internal.printTree e))

deriving via (ViaBnfcInternal BC.Prog) instance Pretty BC.Prog
deriving via (ViaBnfcInternal BC.Decl) instance Pretty BC.Decl
deriving via (ViaBnfcInternal BC.Expr) instance Pretty BC.Expr

newtype ViaBnfcExternal a = ViaBnfcExternal a

instance External.Print a => Pretty (ViaBnfcExternal a) where
  pretty (ViaBnfcExternal e) = pretty $ bnfcPrintHack (External.printTree e)

deriving via (ViaBnfcExternal BF.Prog)   instance Pretty BF.Prog
deriving via (ViaBnfcExternal BF.Decl)   instance Pretty BF.Decl
deriving via (ViaBnfcExternal BF.Expr)   instance Pretty BF.Expr
deriving via (ViaBnfcExternal BF.Binder) instance Pretty BF.Binder
deriving via (ViaBnfcExternal BF.Arg)    instance Pretty BF.Arg

-- BNFC printer treats the braces for implicit arguments as layout braces and
-- therefore adds a ton of newlines everywhere. This hack attempts to undo this.
bnfcPrintHack :: String -> Text
bnfcPrintHack =
  Text.replace "{\n" "{" .
  Text.replace "\n}\n" "} " .
  Text.pack