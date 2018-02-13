{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
-- | Constant-time field accessors for extensible records. The
-- trade-off is the usual lists vs arrays one: it is fast to add an
-- element to the head of a list, but element access is linear time;
-- array access time is uniform, but extending the array is more
-- slower.
module Data.Vinyl.ARec where
import Data.Vinyl.Core
import Data.Vinyl.Lens (RecElem(..), RecSubset(..))
import Data.Vinyl.TypeLevel

import qualified Data.Array as Array
import qualified Data.Array.Base as BArray
import Data.Proxy
import GHC.Exts (Any)
import Unsafe.Coerce

-- | An array-backed extensible record with constant-time field
-- access.
newtype ARec (f :: k -> *) (ts :: [k]) = ARec (Array.Array Int Any)

-- | Convert a 'Rec' into an 'ARec' for constant-time field access.
toARec :: forall f ts. (NatToInt (RLength ts)) => Rec f ts -> ARec f ts
toARec = go id
  where go :: ([Any] -> [Any]) -> Rec f ts' -> ARec f ts
        go acc RNil = ARec $! Array.listArray (0, n - 1) (acc [])
        go acc (x :& xs) = go (acc . (unsafeCoerce x :)) xs
        n = natToInt @(RLength ts)
{-# INLINE toARec #-}

-- | Defines a constraint that lets us index into an 'ARec' in order
-- to produce a 'Rec' using 'fromARec'.
class (NatToInt (RIndex t ts)) => IndexableField ts t where
instance (NatToInt (RIndex t ts)) => IndexableField ts t where

-- | Convert an 'ARec' into a 'Rec'.
fromARec :: forall f ts.
            (RecApplicative ts, AllConstrained (IndexableField ts) ts)
         => ARec f ts -> Rec f ts
fromARec (ARec arr) = rpureConstrained (Proxy :: Proxy (IndexableField ts)) aux
  where aux :: forall t. NatToInt (RIndex t ts) => f t
        aux = unsafeCoerce (arr Array.! natToInt @(RIndex t ts))
{-# INLINE fromARec #-}

-- | Get a field from an 'ARec'.
aget :: forall t f ts. (NatToInt (RIndex t ts)) => ARec f ts -> f t
aget (ARec arr) =
  unsafeCoerce (BArray.unsafeAt arr (natToInt @(RIndex t ts)))
{-# INLINE aget #-}

-- | Set a field in an 'ARec'.
aput :: forall t f ts. (NatToInt (RIndex t ts))
      => f t -> ARec f ts -> ARec f ts
aput x (ARec arr) = ARec (arr Array.// [(i, unsafeCoerce x)])
  where i = natToInt @(RIndex t ts)
{-# INLINE aput #-}

-- | Define a lens for a field of an 'ARec'.
alens :: (Functor g, NatToInt (RIndex t ts))
      => (f t -> g (f t)) -> ARec f ts -> g (ARec f ts)
alens f ar = fmap (flip aput ar) (f (aget ar))
{-# INLINE alens #-}

instance (i ~ RIndex t ts, NatToInt (RIndex t ts)) => RecElem ARec t ts i where
  rlens _ = alens
  rget _ = aget
  rput = aput

-- | Get a subset of a record's fields.
arecGetSubset :: forall rs ss f.
                 (IndexWitnesses (RImage rs ss), NatToInt (RLength rs))
              => ARec f ss -> ARec f rs
arecGetSubset (ARec arr) = ARec (Array.listArray (0, n-1) $
                                 go (indexWitnesses @(RImage rs ss)))
  where go :: [Int] -> [Any]
        go = map (arr Array.!)
        n = natToInt @(RLength rs)
{-# INLINE arecGetSubset #-}

-- | Set a subset of a larger record's fields to all of the fields of
-- a smaller record.
arecSetSubset :: forall rs ss f. (IndexWitnesses (RImage rs ss))
              => ARec f ss -> ARec f rs -> ARec f ss
arecSetSubset (ARec arrBig) (ARec arrSmall) = ARec (arrBig Array.// updates)
  where updates = zip (indexWitnesses @(RImage rs ss)) (Array.elems arrSmall)
{-# INLINE arecSetSubset #-}

instance (is ~ RImage rs ss, IndexWitnesses is, NatToInt (RLength rs))
         => RecSubset ARec rs ss is where
  rsubset f big = fmap (arecSetSubset big) (f (arecGetSubset big))
  {-# INLINE rsubset #-}