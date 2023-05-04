{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Vehicle.Syntax.AST.Value where

import Data.List.NonEmpty (NonEmpty)
import Data.Serialize (Serialize)
import GHC.Generics (Generic)
import Vehicle.Syntax.AST.Arg (GenericArg)
import Vehicle.Syntax.AST.Binder (GenericBinder)
import Vehicle.Syntax.AST.Expr (Expr, UniverseLevel)
import Vehicle.Syntax.AST.Meta (MetaID)
import Vehicle.Syntax.AST.Name (Identifier)
import Vehicle.Syntax.AST.Provenance (Provenance)
import Vehicle.Syntax.External.Abs (Name)

data Head var builtin
  = Builtin builtin
  | BoundVar var
  | FreeVar Identifier
  | MetaID
  deriving (Eq, Show, Generic)

data Value binder var builtin env
  = -- | A universe, used to type types.
    Universe
      Provenance
      UniverseLevel
  | -- | Application of an unreduced head to a spine.
    App
      Provenance
      (Head var builtin) -- Head.
      (Spine binder var builtin env) -- Arguments.
  | -- | Dependent product (subsumes both functions and universal quantification).
    Pi
      Provenance
      (Binder binder var builtin env) -- The bound name
      (Value binder var builtin env) -- (Dependent) result type.
  | -- | Lambda expressions (i.e. anonymous functions).
    Lam
      Provenance
      (Binder binder var builtin env) -- Bound expression name.
      (env var (Value binder var builtin env)) -- Environment captured by the closure.
      (Expr binder var builtin) -- Expression body.
  deriving (Generic)

-- | A binder that cannot be normalised.
type Binder binder var builtin env = GenericBinder binder (Value binder var builtin env)

-- | An argument for an application that cannot be normalised.
type Arg binder var builtin env = GenericArg (Value binder var builtin env)

-- | A list of arguments for an application that cannot be normalised.
type Spine binder var builtin env = [Arg binder var builtin env]

--------------------------------------------------------------------------------
-- Instances

deriving instance (Eq binder, Eq var, Eq builtin, Eq (env var (Value binder var builtin env))) => Eq (Value binder var builtin env)

deriving instance (Show binder, Show var, Show builtin, Show (env var (Value binder var builtin env))) => Show (Value binder var builtin env)

instance (Serialize var, Serialize builtin) => Serialize (Head var builtin)

instance (Serialize binder, Serialize var, Serialize builtin, Serialize (env var (Value binder var builtin env))) => Serialize (Value binder var builtin env)
