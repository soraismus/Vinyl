{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE BangPatterns, CPP, ConstraintKinds, DataKinds, EmptyCase,
             FlexibleContexts, FlexibleInstances, GADTs,
             KindSignatures, MultiParamTypeClasses, PolyKinds,
             RankNTypes, ScopedTypeVariables, TypeOperators,
             UndecidableInstances #-}
-- | Co-records: open sum types.
--
-- Consider a record with three fields @A@, @B@, and @C@. A record is
-- a product of its fields; that is, it contains all of them: @A@,
-- @B@, /and/ @C@. If we want to talk about a value whose type is one
-- of those three types, it is /any one/ of type @A@, @B@, /or/
-- @C@. The type @CoRec '[A,B,C]@ corresponds to this sum type.
module Data.Vinyl.CoRec where
import Data.Maybe(fromJust)
import Data.Proxy
import Data.Vinyl
import Data.Vinyl.Functor (Compose(..), (:.), Identity(..), Const(..))
import Data.Vinyl.TypeLevel
#if __GLASGOW_HASKELL__ < 800
import GHC.Prim (Constraint)
#else
import Data.Kind (Constraint)
#endif

-- | Generalize algebraic sum types.
data CoRec :: (k -> *) -> [k] -> * where
  CoRec :: RElem a ts (RIndex a ts) => !(f a) -> CoRec f ts

-- | Apply a function to a 'CoRec' value. The function must accept
-- /any/ variant.
foldCoRec :: (forall a. RElem a ts (RIndex a ts) => f a -> b) -> CoRec f ts -> b
foldCoRec f (CoRec x) = f x

-- | A Field of a 'Rec' 'Identity' is a 'CoRec' 'Identity'.
type Field = CoRec Identity

-- | A function type constructor that takes its arguments in the
-- reverse order.
newtype Op b a = Op { runOp :: a -> b }

instance forall ts. (RPureConstrained Show ts, RecApplicative ts)
  => Show (CoRec Identity ts) where
  show (CoRec (Identity x)) = "(Col "++show' x++")"
    where shower :: Rec (Op String) ts
          shower = rpureConstrained @Show (Op show)
          show' = runOp (rget shower)

instance forall ts. (RecApplicative ts, RecordToList ts,
                     RZipWith ts, ReifyConstraint Eq Maybe ts, RMap ts)
  => Eq (CoRec Identity ts) where
  crA == crB = and . recordToList
             $ rzipWith f (toRec crA) (coRecToRec' crB)
    where
      f :: forall a. (Dict Eq :. Maybe) a -> Maybe a -> Const Bool a
      f (Compose (Dict a)) b = Const $ a == b
      toRec = reifyConstraint @Eq . coRecToRec'

-- | We can inject a a 'CoRec' into a 'Rec' where every field of the
-- 'Rec' is 'Nothing' except for the one whose type corresponds to the
-- type of the given 'CoRec' variant.
coRecToRec :: forall f ts. RecApplicative ts
           => CoRec f ts -> Rec (Maybe :. f) ts
coRecToRec (CoRec x) = rput (Compose (Just x)) (rpure (Compose Nothing))

-- | Shorthand for applying 'coRecToRec' with common functors.
coRecToRec' :: (RecApplicative ts, RMap ts)
            => CoRec Identity ts -> Rec Maybe ts
coRecToRec' = rmap (fmap getIdentity . getCompose) . coRecToRec

-- | Fold a field selection function over a 'Rec'.
class FoldRec ss ts where
  foldRec :: (CoRec f ss -> CoRec f ss -> CoRec f ss)
          -> CoRec f ss
          -> Rec f ts
          -> CoRec f ss

instance FoldRec ss '[] where foldRec _ z _ = z

instance (t ∈ ss, FoldRec ss ts) => FoldRec ss (t ': ts) where
  foldRec f z (x :& xs) = foldRec f (f z (CoRec x)) xs

-- | Apply a natural transformation to a variant.
coRecMap :: (forall x. f x -> g x) -> CoRec f ts -> CoRec g ts
coRecMap nt (CoRec x) = CoRec (nt x)

-- | This can be used to pull effects out of a 'CoRec'.
coRecTraverse :: Functor h
              => (forall x. f x -> h (g x)) -> CoRec f ts -> h (CoRec g ts)
coRecTraverse f (CoRec x) = fmap CoRec (f x)

-- | Fold a field selection function over a non-empty 'Rec'.
foldRec1 :: FoldRec (t ': ts) ts
         => (CoRec f (t ': ts) -> CoRec f (t ': ts) -> CoRec f (t ': ts))
         -> Rec f (t ': ts)
         -> CoRec f (t ': ts)
foldRec1 f (x :& xs) = foldRec f (CoRec x) xs

-- | Similar to 'Data.Monoid.First': find the first field that is not
-- 'Nothing'.
firstField :: FoldRec ts ts
           => Rec (Maybe :. f) ts -> Maybe (CoRec f ts)
firstField RNil = Nothing
firstField v@(x :& _) = coRecTraverse getCompose $ foldRec aux (CoRec x) v
  where aux :: CoRec (Maybe :. f) (t ': ts)
            -> CoRec (Maybe :. f) (t ': ts)
            -> CoRec (Maybe :. f) (t ': ts)
        aux c@(CoRec (Compose (Just _))) _ =  c
        aux _ c = c

-- | Similar to 'Data.Monoid.Last': find the last field that is not
-- 'Nothing'.
lastField :: FoldRec ts ts
          => Rec (Maybe :. f) ts -> Maybe (CoRec f ts)
lastField RNil = Nothing
lastField v@(x :& _) = coRecTraverse getCompose $ foldRec aux (CoRec x) v
  where aux :: CoRec (Maybe :. f) (t ': ts)
            -> CoRec (Maybe :. f) (t ': ts)
            -> CoRec (Maybe :. f) (t ': ts)
        aux _ c@(CoRec (Compose (Just _))) = c
        aux c _ = c

-- | Apply a type class method on a 'CoRec'. The first argument is a
-- 'Proxy' value for a /list/ of 'Constraint' constructors. For
-- example, @onCoRec [pr|Num,Ord|] (> 20) r@. If only one constraint
-- is needed, use the @pr1@ quasiquoter.
onCoRec :: forall (cs :: [* -> Constraint]) f ts b.
           (AllAllSat cs ts, Functor f, RecApplicative ts)
        => Proxy cs
        -> (forall a. AllSatisfied cs a => a -> b)
        -> CoRec f ts -> f b
onCoRec p f (CoRec x) = fmap meth x
  where meth = runOp $ rget (reifyDicts p (Op f) :: Rec (Op b) ts)

-- | Apply a type class method on a 'Field'. The first argument is a
-- 'Proxy' value for a /list/ of 'Constraint' constructors. For
-- example, @onCoRec [pr|Num,Ord|] (> 20) r@. If only one constraint
-- is needed, use the @pr1@ quasiquoter.
onField :: forall cs ts b.
           (AllAllSat cs ts, RecApplicative ts)
        => Proxy cs
        -> (forall a. AllSatisfied cs a => a -> b)
        -> Field ts -> b
onField p f x = getIdentity (onCoRec p f x)

-- | Build a record whose elements are derived solely from a
-- list of constraint constructors satisfied by each.
reifyDicts :: forall cs f proxy (ts :: [*]). (AllAllSat cs ts, RecApplicative ts)
           => proxy cs -> (forall a. AllSatisfied cs a => f a) -> Rec f ts
reifyDicts _ f = go (rpure Nothing)
  where go :: AllAllSat cs ts' => Rec Maybe ts' -> Rec f ts'
        go RNil = RNil
        go (_ :& xs) = f :& go xs

-- * Extracting values from a CoRec/Pattern matching on a CoRec

-- | If a 'CoRec' is a variant of the requested type, return 'Just'
-- that value; otherwise return 'Nothing'.
asA             :: (t ∈ ts, RecApplicative ts, RMap ts)
                => CoRec Identity ts -> Maybe t
asA c@(CoRec _) = rget $ coRecToRec' c

-- | Like 'asA', but for any interpretation functor.
asA' :: (t ∈ ts, RecApplicative ts, RMap ts)
     => CoRec f ts -> (Maybe :. f) t
asA' c@(CoRec _) = rget $ coRecToRec c

-- | Pattern match on a CoRec by specifying handlers for each case. Note that
-- the order of the Handlers has to match the type level list (t:ts).
--
-- >>> :{
-- let testCoRec = Col (Identity False) :: CoRec Identity [Int, String, Bool] in
-- match testCoRec $
--       (H $ \i -> "my Int is the successor of " ++ show (i - 1))
--    :& (H $ \s -> "my String is: " ++ s)
--    :& (H $ \b -> "my Bool is not: " ++ show (not b) ++ " thus it is " ++ show b)
--    :& RNil
-- :}
-- "my Bool is not: True thus it is False"
match :: forall ts b. CoRec Identity ts -> Handlers ts b -> b
match (CoRec (Identity t)) hs = aux t
  where aux :: forall a. RElem a ts (RIndex a ts) => a -> b
        aux x = case rget @a hs of
                  H f -> f x

-- | Helper for handling a variant of a 'CoRec': either the function
-- is applied to the variant or the type of the 'CoRec' is refined to
-- reflect the fact that the variant is /not/ compatible with the type
-- of the would-be handler.
class RIndex t ts ~ i => Match1 t ts i where
  match1' :: Handler r t -> Rec Maybe ts -> Either r (Rec Maybe (RDelete t ts))

instance Match1 t (t ': ts) 'Z where
  match1' _ (Nothing :& xs) = Right xs
  match1' (H h) (Just x :& _) = Left (h x)

instance (Match1 t ts i, RIndex t (s ': ts) ~ 'S i,
          RDelete t (s ': ts) ~ (s ': RDelete t ts))
         => Match1 t (s ': ts) ('S i) where
  match1' h (x :& xs) = (x :&) <$> match1' h xs

-- | Handle a single variant of a 'CoRec': either the function is
-- applied to the variant or the type of the 'CoRec' is refined to
-- reflect the fact that the variant is /not/ compatible with the type
-- of the would-be handler
match1 :: (Match1 t ts (RIndex t ts),
           RecApplicative ts,
           RMap ts, RMap (RDelete t ts),
           FoldRec (RDelete t ts) (RDelete t ts))
       => Handler r t
       -> CoRec Identity ts
       -> Either r (CoRec Identity (RDelete t ts))
match1 h = fmap (fromJust . firstField . rmap (Compose . fmap Identity))
         . match1' h
         . coRecToRec'

matchNil :: CoRec f '[] -> r
matchNil (CoRec x) = case x of _ -> error "matchNil: impossible"

-- | Newtype around functions for a to b
newtype Handler b a = H (a -> b)

-- | 'Handlers ts b', is essentially a list of functions, one for each type in
-- ts. All functions produce a value of type 'b'. Hence, 'Handlers ts b' would
-- represent something like the type-level list: [t -> b | t \in ts ]
type Handlers ts b = Rec (Handler b) ts

-- | A 'CoRec' is either the first possible variant indicated by its
-- type, or a 'CoRec' that must be one of the remaining types.
restrictCoRec :: forall t ts f. (RecApplicative ts, FoldRec ts ts)
              => CoRec f (t ': ts) -> Either (f t) (CoRec f ts)
restrictCoRec = go . coRecToRec
  where go :: Rec (Maybe :. f) (t ': ts) -> Either (f t) (CoRec f ts)
        go (Compose Nothing :& xs) = Right (fromJust (firstField xs))
        go (Compose (Just x) :& _) = Left x

-- | A 'CoRec' whose possible types are @ts@ may be used at a type of
-- 'CoRec' whose possible types are @t:ts@.
weakenCoRec :: (RecApplicative ts, FoldRec (t ': ts) (t ': ts))
            => CoRec f ts -> CoRec f (t ': ts)
weakenCoRec = fromJust . firstField . (Compose Nothing :&) . coRecToRec
