-- WARNING: This file was generated automatically by Vehicle
-- and should not be modified manually!
-- Metadata
--  - Agda version: 2.6.2
--  - AISEC version: 0.1.0.1
--  - Time generated: ???

{-# OPTIONS --allow-exec #-}

open import Vehicle
open import Data.Unit
open import Data.Integer as ℤ using (ℤ)
open import Data.Rational as ℚ using (ℚ)
open import Data.Fin as Fin using (Fin; #_)
open import Data.Vec.Functional renaming ([] to []ᵥ; _∷_ to _∷ᵥ_)

module simple-quantifier-output where

unused : Set
unused = ∀ (x : ℤ) → ⊤

postulate f : Vector ℚ 1 → Vector ℚ 1

abstract
  expandedExpr : ∀ (x : Vector ℚ 1) → x (# 0) ℚ.≥ f x (# 0)
  expandedExpr = checkSpecification record
    { proofCache   = "/home/matthew/Code/AISEC/vehicle/proofcache.vclp"
    }

abstract
  sequential : ∀ (x : Vector ℚ 1) → ∀ (y : Vector ℚ 1) → f x (# 0) ℚ.≥ f y (# 0)
  sequential = checkSpecification record
    { proofCache   = "/home/matthew/Code/AISEC/vehicle/proofcache.vclp"
    }