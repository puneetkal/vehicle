-- WARNING: This file was generated automatically by Vehicle
-- and should not be modified manually!
-- Metadata
--  - Agda version: 2.6.2
--  - AISEC version: 0.1.0.1
--  - Time generated: ???

open import Vehicle
open import Data.Unit
open import Data.Int as ℤ using (ℤ)
open import Data.List
open import Data.List.Relation.Unary.All as List

module quantifierIn-output where

private
  VEHICLE_PROJECT_FILE = TODO/vehicle/path

emptyList : List ℤ
emptyList = []

abstract
  empty : List.All (λ (x : ℤ) → ⊤) emptyList
  empty = checkProperty record
    { projectFile  = VEHICLE_PROJECT_FILE
    ; propertyUUID = ????
    }