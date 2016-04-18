{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | This is an internal module. You are very discouraged from using it directly.
module Opaleye.SOT.Internal where

import           Control.Applicative
import           Control.Arrow
import           Control.Lens
import qualified Control.Exception as Ex
import           Control.Monad (MonadPlus(..))
import           Control.Monad.Fix (MonadFix(..))
import           Data.Data (Data)
import           Data.Foldable
import           Data.Typeable (Typeable)
import qualified Data.Aeson
import qualified Data.ByteString
import qualified Data.ByteString.Lazy
import qualified Data.CaseInsensitive
import qualified Data.Text
import qualified Data.Text.Lazy
import qualified Data.Time
import qualified Data.UUID
import           Data.Int
import           Data.Proxy (Proxy(..))
import           Data.HList (Tagged(Tagged, unTagged), HList(HCons, HNil))
import qualified Data.HList as HL
import qualified Data.Profunctor as P
import qualified Data.Profunctor.Product as PP
import qualified Data.Profunctor.Product.Default as PP
import           Data.Singletons
import qualified Data.Promotion.Prelude.List as List (Map)
import           GHC.Exts (Constraint)
import           GHC.Generics (Generic)
import           GHC.Float (float2Double)
import qualified GHC.TypeLits as GHC
import qualified Opaleye as O
import qualified Opaleye.Internal.HaskellDB.PrimQuery as OI
import qualified Opaleye.Internal.PGTypes as OI
import qualified Opaleye.Internal.RunQuery as OI
import qualified Opaleye.Internal.Join as OI
import qualified Opaleye.Internal.TableMaker as OI

-------------------------------------------------------------------------------

-- | Hack to workaround the current represenation for nullable columns.
-- See 'Koln'.
type family NotNullable (x :: k) :: Constraint where
  NotNullable (O.Nullable x) =
     "NotNullable" ~ "NotNullable: expected `x` but got `Nullable x`"
  NotNullable x = ()

-- | Only 'PgType' instances are allowed as indexes to 'Kol' and 'Koln'
class NotNullable a => PgType (a :: k)
instance PgType O.PGBool
instance PgType O.PGBytea
instance PgType O.PGCitext
instance PgType O.PGDate
instance PgType O.PGFloat4
instance PgType O.PGFloat8
instance PgType O.PGInt2
instance PgType O.PGInt4
instance PgType O.PGInt8
instance PgType O.PGJsonb
instance PgType O.PGJson
instance PgType O.PGNumeric
instance PgType O.PGText
instance PgType O.PGTimestamptz
instance PgType O.PGTimestamp
instance PgType O.PGTime
instance PgType O.PGUuid

-------------------------------------------------------------------------------

-- | Like @opaleye@'s @('O.Column' a)@, but with @a@ guaranteed to be not
-- 'O.Nullable'. If you need to have a 'O.Nullable' column type, use 'Koln'
-- instead.
--
-- Build using 'kol' or 'Kol'.
--
-- /Notice that 'Kol' is very different from 'Col': 'Col' is used to describe/
-- /the properties of a column at compile time. 'Kol' is used at runtime/
-- /for manipulating with values stored in columns./
--
-- We do not use @('O.Column' a)@, instead we use @('Kol' a)@ This is where we
-- drift a bit appart from Opaleye. See
-- https://github.com/tomjaguarpaw/haskell-opaleye/issues/97
--
-- Also, even if the @a@ in @'Kol' a@ is never used at the term level, its
-- kind is unfortunately restriced to @*@ by Opaleye.
data Kol (a :: *) = PgType a => Kol { unKol :: O.Column a }

deriving instance Show (O.Column a) => Show (Kol a)

-- | Converts an unary function on Opaleye's 'O.Column' to an unary
-- function on 'Kol'.
--
-- /Hint/: You can further compose the result of this function with 'op1'
-- to widen the range of accepted argument types.
liftKol1
  :: (PgType a, PgType b)
  => (O.Column a -> O.Column b)
  -> (Kol a -> Kol b) -- ^
liftKol1 f = Kol . f . unKol

-- | Converts a binary function on Opaleye's 'O.Column's to an binary
-- function on 'Koln'.
--
-- /Hint/: You can further compose the result of this function with 'op2'
-- to widen the range of accepted argument types.
liftKol2
  :: (PgType a, PgType b, PgType c)
  => (O.Column a -> O.Column b -> O.Column c)
  -> (Kol a -> Kol b -> Kol c)
liftKol2 f = \ka kb -> Kol (f (unKol ka) (unKol kb))

instance
    ( PgType a
    , Profunctor p, PP.Default p (O.Column a) (O.Column b)
    ) => PP.Default p (Kol a) (O.Column b) where
  def = P.lmap unKol PP.def

instance forall p a b.
    ( PgType b, Profunctor p, PP.Default p (O.Column a) (O.Column b)
    ) => PP.Default p (O.Column a) (Kol b) where
  def = P.rmap Kol (PP.def :: p (O.Column a) (O.Column b))

instance forall p a b.
    ( PgType a, PgType b
    , Profunctor p, PP.Default p (O.Column a) (O.Column b)
    ) => PP.Default p (Kol a) (Kol b) where
  def = P.dimap unKol Kol (PP.def :: p (O.Column a) (O.Column b))

instance
    ( PgType a, PP.Default O.QueryRunner (O.Column a) b
    ) => PP.Default O.QueryRunner (Kol a) b where
  def = P.lmap unKol PP.def

instance (PgType a, Fractional (O.Column a)) => Fractional (Kol a) where
  fromRational = Kol . fromRational
  (/) = liftKol2 (/)

instance (PgType a, Num (O.Column a)) => Num (Kol a) where
  fromInteger = Kol . fromInteger
  (*) = liftKol2 (*)
  (+) = liftKol2 (+)
  (-) = liftKol2 (-)
  abs = liftKol1 abs
  negate = liftKol1 negate
  signum = liftKol1 signum

-- | Build a 'Kol'.
--
-- You need to provide a 'ToKol' instance for every Haskell type you plan to
-- convert to its PostgreSQL representation as 'Kol'.
--
-- A a default implementation of 'kol' is available for 'Wrapped'
-- instances:
--
-- @
-- default 'kol' :: ('Wrapped' a, 'ToKol' ('Unwrapped' a) b) => a -> 'Kol' b
-- 'kol' = 'kol' . 'view' '_Wrapped''
-- @
--
-- /Implementation notice/: This class overlaps in purpose with Opaleye's
-- 'O.Constant'. Technicaly, we don't really need to repeat those instances
-- here: we could just rely on Opaleye's 'O.Constant'. However, as of today,
-- Opaleye's 'O.Constant' provides some undesired support which we
-- deliberately want to avoid here. Namely, we don't want to support
-- converting 'Int' to 'O.PGInt4'. If this is fixed upstream,
-- we might go back to relying on 'O.Constant' if suitable. See
-- https://github.com/tomjaguarpaw/haskell-opaleye/pull/110
class PgType b => ToKol (a :: *) (b :: *) where
  -- | Convert a constant Haskell value (say, a 'Bool') to its equivalent
  -- PostgreSQL representation as a @('Kol' 'O.PGBool')@.
  --
  -- Some example simplified types:
  --
  -- @
  -- 'kol' :: 'Bool' -> 'Kol' 'O.PGBool'
  -- 'kol' :: 'Int32' -> 'Kol' 'O.PGInt4'
  -- @
  kol :: a -> Kol b
  default kol :: (Wrapped a, ToKol (Unwrapped a) b) => a -> Kol b
  kol = kol . view _Wrapped'

instance ToKol String O.PGText where kol = Kol . O.pgString
instance ToKol Data.Text.Text O.PGText where kol = Kol . O.pgStrictText
instance ToKol Data.Text.Lazy.Text O.PGText where kol = Kol . O.pgLazyText
instance ToKol Char O.PGText where kol = Kol . O.pgString . (:[])
instance ToKol Bool O.PGBool where kol = Kol . O.pgBool
instance ToKol Int32 O.PGInt4 where kol = Kol . O.pgInt4 . fromIntegral
instance ToKol Int32 O.PGInt8 where kol = Kol . O.pgInt8 . fromIntegral
instance ToKol Int64 O.PGInt8 where kol = Kol . O.pgInt8
instance ToKol Float O.PGFloat4 where kol = Kol . pgFloat4
instance ToKol Float O.PGFloat8 where kol = Kol . pgFloat8
instance ToKol Double O.PGFloat8 where kol = Kol . O.pgDouble
instance ToKol Data.ByteString.ByteString O.PGBytea where kol = Kol . O.pgStrictByteString
instance ToKol Data.ByteString.Lazy.ByteString O.PGBytea where kol = Kol . O.pgLazyByteString
instance ToKol Data.Time.UTCTime O.PGTimestamptz where kol = Kol . O.pgUTCTime
instance ToKol Data.Time.LocalTime O.PGTimestamp where kol = Kol . O.pgLocalTime
instance ToKol Data.Time.TimeOfDay O.PGTime where kol = Kol . O.pgTimeOfDay
instance ToKol Data.Time.Day O.PGDate where kol = Kol . O.pgDay
instance ToKol Data.UUID.UUID O.PGUuid where kol = Kol . O.pgUUID
instance ToKol (Data.CaseInsensitive.CI Data.Text.Text) O.PGCitext where kol = Kol . O.pgCiStrictText
instance ToKol (Data.CaseInsensitive.CI Data.Text.Lazy.Text) O.PGCitext where kol = Kol . O.pgCiLazyText
instance ToKol Data.Aeson.Value O.PGJson where kol = Kol . O.pgLazyJSON . Data.Aeson.encode
instance ToKol Data.Aeson.Value O.PGJsonb where kol = Kol . O.pgLazyJSONB . Data.Aeson.encode

---

-- | Like @opaleye@'s @('O.Column' ('O.Nullable' a))@, but with @a@ guaranteed
-- to be not-'O.Nullable'.
--
-- Think of @'Koln' a@ as @'Maybe' ('Kol' a)@, with 'nul' being analogous to
-- 'Nothing' and 'koln' being analogous to 'Just'.
--
-- Build safely using 'nul', 'koln', 'fromKol' or 'Koln'.
--
-- /Notice that 'Koln' is very different from 'Col': 'Col' is used to describe/
-- /the properties of a column at compile time. 'Koln' is used at runtime/
-- /for manipulating with values stored in columns./
--
-- We do not use @'O.Column' ('O.Nullable' a)@, but instead we use
-- @('Koln' a)@. This is where we drift a bit appart from Opaleye.
-- see https://github.com/tomjaguarpaw/haskell-opaleye/issues/97
--
-- Also, even if the @a@ in @'Koln' a@ is never used at the term level, its
-- kind is unfortunately restriced to @*@ by Opaleye.
data Koln (a :: *) = PgType a => Koln { unKoln :: O.Column (O.Nullable a) }

deriving instance Show (O.Column (O.Nullable a)) => Show (Koln a)

-- | Build a 'Koln' from a Haskell term. This is like the 'Just' constructor for
-- 'Maybe'
koln :: ToKol a b => a -> Koln b
koln = fromKol . kol

-- | PostgreSQL's @NULL@ value. This is like the 'Nothing' constructor for
-- 'Maybe'
nul :: PgType a => Koln a
nul = Koln O.null

-- | Convert a 'Kol' to a 'Koln'.
fromKol :: PgType a => Kol a -> Koln a
fromKol = Koln . O.toNullable . unKol

-- | Case analysis for 'Koln'. Like 'maybe' for 'Maybe'.
--
-- If @('Koln' a)@ is @NULL@, then evaluate to the first argument,
-- otherwise it applies the given function to the underlying @('Kol' a)@.
matchKoln :: (PgType a, PgType b) => Kol b -> (Kol a -> Kol b) -> Koln a -> Kol b
matchKoln kb0 f kna = Kol $
  O.matchNullable (unKol kb0) (unKol . f . Kol) (unKoln kna)

-- | Like 'fmap' for 'Maybe'.
--
-- Apply the given function to the underlying @('Kol' a)@ only as long as the
-- given @('Koln' a)@ is not @NULL@, otherwise, evaluates to @NULL@.
mapKoln :: (PgType a, PgType b) => (Kol a -> Kol b) -> Koln a -> Koln b
mapKoln f kna = bindKoln kna (fromKol . f)

-- | Monadic bind like the one for 'Maybe'.
--
-- Apply the given function to the underlying @('Kol' a)@ only as long as the
-- given @('Koln' a)@ is not @NULL@, otherwise, evaluates to @NULL@.
bindKoln :: (PgType a, PgType b) => Koln a -> (Kol a -> Koln b) -> Koln b
bindKoln kna f = Koln $
  O.matchNullable O.null (unKoln . f . Kol) (unKoln kna)

-- | Like @('<|>') :: 'Maybe' a -> 'Maybe' a -> 'Maybe' a@.
--
-- Evaluates to the first argument if it is not @NULL@, otherwise
-- evaluates to the second argument.
altKoln :: (PgType a) => Koln a -> Koln a -> Koln a
altKoln kna0 kna1 = Koln $
  O.matchNullable (unKoln kna1) O.toNullable (unKoln kna0)

-- | Converts an unary function on @opaleye@'s 'O.Nullable' 'O.Column'
-- to an unary function on 'Koln'.
--
-- /Hint/: You can further compose the result of this function with 'op1'
-- to widen the range of accepted argument types.
liftKoln1
  :: (PgType a, PgType b)
  => (O.Column (O.Nullable a) -> O.Column (O.Nullable b))
  -> (Koln a -> Koln b) -- ^
liftKoln1 f = Koln . f . unKoln

-- | Converts a binary function on Opaleye's 'O.Nullable' 'O.Column's
-- to a binary function on 'Koln's.
--
-- /Hint/: You can further compose the result of this function with 'op2'
-- to widen the range of accepted argument types.
liftKoln2
  :: (PgType a, PgType b, PgType c)
  => (O.Column (O.Nullable a) -> O.Column (O.Nullable b) -> O.Column (O.Nullable c))
  -> (Koln a -> Koln b -> Koln c) -- ^
liftKoln2 f = \kna knb -> Koln (f (unKoln kna) (unKoln knb))

-- | OVERLAPPABLE.
instance {-# OVERLAPPABLE #-} forall p x a.
    ( P.Profunctor p, PgType a
    , PP.Default p x (O.Column (O.Nullable a))
    ) => PP.Default p x (Koln a) where
  def = P.rmap Koln (PP.def :: p x (O.Column (O.Nullable a)))
  {-# INLINE def #-}

-- | OVERLAPPABLE.
instance {-# OVERLAPPABLE #-}
    ( P.Profunctor p, PgType a
    , PP.Default p (O.Column (O.Nullable a)) x
    ) => PP.Default p (Koln a) x where
  def = P.lmap unKoln PP.def
  {-# INLINE def #-}

instance
    ( P.Profunctor p, PgType a, PgType b
    , PP.Default p (O.Column (O.Nullable a)) (O.Column (O.Nullable b))
    ) => PP.Default p (Koln a) (Koln b) where
  def = P.dimap unKoln Koln (PP.def :: p (O.Column (O.Nullable a)) (O.Column (O.Nullable b)))
  {-# INLINE def #-}

-- | OVERLAPPABLE.
instance {-# OVERLAPPABLE #-}
    ( O.QueryRunnerColumnDefault pg hs
    ) => O.QueryRunnerColumnDefault pg (Maybe hs) where
  queryRunnerColumnDefault = OI.QueryRunnerColumn u (fmap (fmap (fmap Just)) fp)
    where OI.QueryRunnerColumn u fp = O.queryRunnerColumnDefault

instance (PgType a, Fractional (Kol a)) => Fractional (Koln a) where
  fromRational = fromKol . fromRational
  (/) kna knb = bindKoln kna (\ka -> bindKoln knb (\kb -> fromKol (ka / kb)))

instance (PgType a, Num (Kol a)) => Num (Koln a) where
  fromInteger = fromKol . fromInteger
  (*) kna knb = bindKoln kna (\ka -> bindKoln knb (\kb -> fromKol (ka * kb)))
  (+) kna knb = bindKoln kna (\ka -> bindKoln knb (\kb -> fromKol (ka + kb)))
  (-) kna knb = bindKoln kna (\ka -> bindKoln knb (\kb -> fromKol (ka - kb)))
  abs = mapKoln abs
  negate = mapKoln negate
  signum = mapKoln signum

-------------------------------------------------------------------------------

-- | @'PgTypeCast' a b@ says that the 'PgType' @a@ can be safely coerced to the
-- 'PgType' @b@'.
--
-- To perform the actual coercion, use 'kolCast' or 'kolnCast'.
class (PgType a, PgType b) => PgTypeCast (a :: ka) (b :: kb) where
-- | Identity.
instance (PgType a) => PgTypeCast a a

kolCast :: PgTypeCast a b => Kol a -> Kol b
kolCast = liftKol1 O.unsafeCoerceColumn

kolnCast :: PgTypeCast a b => Koln a -> Koln b
kolnCast = mapKoln kolCast

-------------------------------------------------------------------------------

-- | Whether to read a plain value or possibly @NULL@.
data RN = R  -- ^ Read plain value.
        | RN -- ^ Possibly read @NULL@.

-- | Whether to write a specific value or possibly @DEFAULT@.
data WD = W  -- ^ Write a specific value.
        | WD -- ^ Possibly write @DEFAULT@. See 'WDef'.
--- | Whether to write @DEFAULT@ or a specific value when writing to a column.

--------------------------------------------------------------------------------

-- | Whether to write a @DEFAUT@ value or a specific value into a database column.
--
-- 'WDef' is isomorphic to 'Maybe'. It exists mainly to avoid accidentally
-- mixing the two of them together.
data WDef a
  = WDef   -- ^ Write @DEFAULT@.
  | WVal a -- ^ Write the specified value.
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable,
            Data, Generic, Typeable)

-- | Case analysis for 'WDef'.
--
-- Like 'maybe', evaluates to the first argument if 'WDef',
-- otherwise applies the given function to the @a@ in 'WVal'.
wdef :: b -> (a -> b) -> WDef a -> b
wdef b f = \w -> case w of { WDef -> b; WVal a -> f a }
{-# INLINE wdef #-}

instance Applicative WDef where
  pure = WVal
  {-# INLINE pure #-}
  (<*>) (WVal f) (WVal a) = WVal (f a)
  (<*>) _        _        = WDef
  {-# INLINE (<*>) #-}

instance Alternative WDef where
  empty = WDef
  {-# INLINE empty #-}
  (<|>) WDef wb = wb
  (<|>) wa   _  = wa
  {-# INLINE (<|>) #-}

instance Monad WDef where
  return = pure
  {-# INLINE return #-}
  (>>=) (WVal a) k = k a
  (>>=) _        _ = WDef
  {-# INLINE (>>=) #-}

instance MonadPlus WDef where
  mzero = empty
  {-# INLINE mzero #-}
  mplus = (<|>)
  {-# INLINE mplus #-}

instance MonadFix WDef where
  mfix f = let a = f (unWVal a) in a
    where unWVal (WVal x) = x
          unWVal WDef     = error "mfix WDef: WDef"

--------------------------------------------------------------------------------

-- | Column description.
--
-- This is only used as a promoted datatype expected to have kind
-- @'Col' 'GHC.Symbol' 'WD' 'RN' * *@.
--
-- * @name@: Column name.
--
-- * @wd@: Whether @DEFAULT@ can be written to this column ('WD') or not ('W').
--
-- * @rn@: Whether @NULL@ might be read from this column ('RN') or not ('R').
--
-- * @pgType@: Type of the column value used in Opaleye queries
--   (e.g., 'O.PGText', 'O.PGInt2').
--
-- * @hsType@: Type of the column value used in Haskell outside Opaleye
--   queries. Hint: don't use something like @'Maybe' 'Bool'@ here if you
--   want to indicate that this is an optional 'Bool' column. Instead, use
--   'Int' here and 'RN' in the @rn@ field.
--
-- /Notice that 'Col' is very different from 'Kol' and 'Koln': 'Kol' and 'Koln'/
-- /are used at runtime for manipulating values stored in columns, 'Col' is used/
-- /to describe the properties of a column at compile time./
data Col name wd rn pgType hsType
   = Col name wd rn pgType hsType

--

type family Col_Name (col :: Col GHC.Symbol WD RN * *) :: GHC.Symbol where
  Col_Name ('Col n w r p h) = n
data Col_NameSym0 (col :: TyFun (Col GHC.Symbol WD RN * *) GHC.Symbol)
type instance Apply Col_NameSym0 col = Col_Name col

type family Col_PgType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgType ('Col n w r p h) = p
data Col_PgTypeSym0 (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply Col_PgTypeSym0 col = Col_PgType col

type family Col_PgRType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgRType ('Col n w 'R  p h) = Kol p
  Col_PgRType ('Col n w 'RN p h) = Koln p

type family Col_PgRNType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgRNType ('Col n w r p h) = Koln p

type family Col_PgWType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgWType ('Col n 'W  r p h) = Col_PgRType ('Col n 'W r p h)
  Col_PgWType ('Col n 'WD r p h) = WDef (Col_PgRType ('Col n 'WD r p h))

type family Col_HsRType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_HsRType ('Col n w 'R  p h) = h
  Col_HsRType ('Col n w 'RN p h) = Maybe h

type family Col_HsIType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_HsIType ('Col n 'W  r p h) = Col_HsRType ('Col n 'W r p h)
  Col_HsIType ('Col n 'WD r p h) = WDef (Col_HsRType ('Col n 'WD r p h))

---

-- | Lookup a column in @'Tabla' t@ by its name.
type Col_ByName t (c :: GHC.Symbol) = Col_ByName' c (Cols t)
type family Col_ByName' (name :: GHC.Symbol) (cols :: [Col GHC.Symbol WD RN * *]) :: Col GHC.Symbol WD RN * * where
  Col_ByName' n ('Col n  w r p h ': xs) = 'Col n w r p h
  Col_ByName' n ('Col n' w r p h ': xs) = Col_ByName' n xs

type HasColName t (c :: GHC.Symbol) =  HasColName' c (Cols t)
type family HasColName' (name :: GHC.Symbol) (cols :: [Col GHC.Symbol WD RN * *]) :: Constraint where
  HasColName' n ('Col n  w r p h ': xs) = ()
  HasColName' n ('Col n' w r p h ': xs) = HasColName' n xs

---

-- | Payload for @('HsR' t)@
type Cols_HsR t = List.Map (Col_HsRFieldSym1 t) (Cols t)
type Col_HsRField t (col :: Col GHC.Symbol WD RN * *)
  = Tagged (TC t (Col_Name col)) (Col_HsRType col)
data Col_HsRFieldSym1 t (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_HsRFieldSym1 t) col = Col_HsRField t col

-- | Payload for @('HsI' t)@
type Cols_HsI t = List.Map (Col_HsIFieldSym1 t) (Cols t)
type Col_HsIField t (col :: Col GHC.Symbol WD RN * *)
  = Tagged (TC t (Col_Name col)) (Col_HsIType col)
data Col_HsIFieldSym1 t (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_HsIFieldSym1 t) col = Col_HsIField t col

-- | Payload for @('PgR' t)@
type Cols_PgR t = List.Map (Col_PgRSym1 t) (Cols t)
type family Col_PgR t (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgR t ('Col n w r p h) = Tagged (TC t n) (Col_PgRType ('Col n w r p h))
data Col_PgRSym1 t (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_PgRSym1 t) col = Col_PgR t col

-- | Payload for @('PgRN' t)@
type Cols_PgRN t = List.Map (Col_PgRNSym1 t) (Cols t)
type family Col_PgRN t (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgRN t ('Col n w r p h) = Tagged (TC t n) (Col_PgRNType ('Col n w r p h))
data Col_PgRNSym1 t (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_PgRNSym1 t) col = Col_PgRN t col

-- | Type of the 'HL.Record' columns when inserting or updating a row. Also,
-- payload for @('PgW' t)@.
type Cols_PgW t = List.Map (Col_PgWSym1 t) (Cols t)
type family Col_PgW t (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgW t ('Col n w r p h) = Tagged (TC t n) (Col_PgWType ('Col n w r p h))
data Col_PgWSym1 t (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_PgWSym1 t) col = Col_PgW t col

--------------------------------------------------------------------------------

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- table in a specific schema.
data T (t :: k) = Tabla t => T

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- column in a specific table in a specific schema.
data TC (t :: k) (c :: GHC.Symbol) = Tabla t => TC

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- column in an unknown table.
data C (c :: GHC.Symbol) = C

--------------------------------------------------------------------------------

-- | All the representation of @t@ used within @opaleye-sot@ are @('Rec' t)@.
type Rec t xs = Tagged (T t) (HL.Record xs)

-- | Expected output type for 'O.runQuery' on a @('PgR' t)@.
--
-- Important: If you are expecting a @('PgR' t)@ on the right side
-- of a 'O.leftJoin', you will need to use @('Maybe' ('PgR' t))@.
--
-- Mnemonic: Haskell Read.
type HsR t = Rec t (Cols_HsR t)

-- | Output type of 'toHsI', used when inserting a new row to the table.
--
-- This type is used internally as an intermediate representation between
-- your own Haskell representation for a to-be-inserted @t@ and @('PgW' t)@.
--
-- Mnemonic: Haskell Insert.
type HsI t = Rec t (Cols_HsI t)

-- | Output type of @'queryTabla' ('T' t)@.
--
-- Mnemonic: PostGresql Read.
type PgR t = Rec t (Cols_PgR t)

-- | Like @('PgRN' t)@ but every field is 'Koln', as in the
-- output type of the right hand side of a 'O.leftJoin' with @'('table' t)@.
--
-- Mnemonic: PostGresql Read Nulls.
type PgRN t = Rec t (Cols_PgRN t)

-- | Representation of @('ToHsI' t)@ as 'Kols'. To be used when
-- writing to the database.
--
-- Mnemonic: PostGresql Write.
type PgW t = Rec t (Cols_PgW t)

--------------------------------------------------------------------------------

-- | All these constraints need to be satisfied by tools that work with 'Tabla'.
-- It's easier to just write all the constraints once here and make 'ITabla' a
-- superclass of 'Tabla'. Moreover, they enforce some sanity constraints on our
-- 'Tabla' so that we can get early compile time errors.
type ITabla t
  = ( GHC.KnownSymbol (SchemaName t)
    , GHC.KnownSymbol (TableName t)
    , All PgType (List.Map Col_PgTypeSym0 (Cols t))
    , HDistributeProxy (Cols t)
    , HL.HMapAux HList (FnCol_Props t) (List.Map ProxySym0 (Cols t)) (Cols_Props t)
    , HL.HMapAux HList (HL.HFmap FnPgWfromHsIField) (Cols_HsI t) (Cols_PgW t)
    , HL.HMapAux HList (HL.HFmap FnPgWfromPgRField) (Cols_PgR t) (Cols_PgW t)
    , HL.HRLabelSet (Cols_HsR t)
    , HL.HRLabelSet (Cols_HsI t)
    , HL.HRLabelSet (Cols_PgR t)
    , HL.HRLabelSet (Cols_PgRN t)
    , HL.HRLabelSet (Cols_PgW t)
    , HL.SameLength (Cols_Props t) (List.Map ProxySym0 (Cols t))
    , HL.SameLength (Cols_HsI t) (Cols_PgW t)
    , HL.SameLength (Cols_PgR t) (Cols_PgW t)
    , ProductProfunctorAdaptor O.TableProperties (HL.Record (Cols_Props t)) (HL.Record (Cols_PgW t)) (HL.Record (Cols_PgR t))
    , PP.Default OI.ColumnMaker (PgR t) (PgR t)
    )

-- | Tabla means table in spanish.
--
-- An instance of this class can uniquely describe a PostgreSQL table and
-- how to convert back and forth between it and its Haskell representation
-- used when writing Opaleye queries.
--
-- The @t@ type is only used as a tag for the purposes of uniquely identifying
-- this 'Tabla'.
class ITabla t => Tabla (t :: k) where
  -- | Some kind of unique identifier used for telling appart the database where
  -- this table exists from other databases, so as to avoid accidentally mixing
  -- tables from different databases in queries.
  type Database t :: *
  -- | PostgreSQL schema name where to find the table (defaults to @"public"@,
  -- PostgreSQL's default schema name).
  type SchemaName t :: GHC.Symbol
  type SchemaName t = "public"
  -- | Table name.
  type TableName t :: GHC.Symbol
  -- | Columns in this table. See the documentation for 'Col'.
  type Cols t :: [Col GHC.Symbol WD RN * *]

--------------------------------------------------------------------------------

-- | Convert an Opaleye-compatible Haskell representation of @a@ to @a@ when
-- /reading/ from the database.
--
-- Notice that you are not required to provide instances of this class if working
-- with @'HsR' t@ is sufficient for you, or if you already have a function
-- @('HsR' t -> a)@ at hand. Nevertheless, readability wise, it can be useful to
-- have a single overloaded function used to decode each @('HsR' t)@.
class Tabla t => UnHsR t (a :: *) where
  -- | Convert an Opaleye-compatible Haskell representation of @a@ to @a@.
  --
  -- For your convenience, you are encouraged to use 'cola', but you may also use
  -- other tools from "Data.HList.Record" as you see fit:
  --
  -- @
  -- 'unHsR'' r = Person (r '^.' 'cola' ('C' :: 'C' "name"))
  --                   (r '^.' 'cola' ('C' :: 'C' "age"))
  -- @
  --
  -- Hint: If the type checker is having trouble inferring @('HsR' t)@,
  -- consider using 'unHsR' instead.
  unHsR' :: HsR t -> Either Ex.SomeException a

-- | Like 'unHsR'', except it takes @t@ explicitely for the times when it
-- can't be inferred.
unHsR :: UnHsR t a => T t -> HsR t -> Either Ex.SomeException a
unHsR _ = unHsR'
{-# INLINE unHsR #-}

-- | Like 'unHsR'', except it takes both @t@ and @a@ explicitely for the times
-- when they can't be inferred.
unHsR_ :: UnHsR t a => T t -> Proxy a -> HsR t -> Either Ex.SomeException a
unHsR_ _ _ = unHsR'
{-# INLINE unHsR_ #-}

--------------------------------------------------------------------------------

-- | Build a @('HsR' t)@ representation for @a@ for /inserting/ it to the database.
--
-- Notice that you are not required to provide instances of this class if working
-- with @'HsI' t@ is sufficient for you, or if you already have a function
-- @(a -> 'HsI' t)@ at hand.
class Tabla t => ToHsI t (a :: *) where
  -- | Convert an @a@ to an Opaleye-compatible Haskell representation
  -- to be used when inserting a new row to this table.
  --
  -- For your convenience, you may use 'mkHsI' together with 'HL.hBuild' to build
  -- 'toHsI':
  --
  -- @
  -- 'toHsI' (Person name age) = 'mkHsI' $ \\set_ -> 'HL.hBuild'
  --     (set_ ('C' :: 'C' "name") name)
  --     (set_ ('C' :: 'C' "age") age)
  -- @
  --
  -- You may also use other tools from "Data.HList.Record" as you see fit.
  --
  -- Hint: If the type checker is having trouble inferring @('HsI' t)@,
  -- consider using 'toHsI' instead. Nevertheless, it is more
  -- likely that you use 'toPgW' directly, which skips the 'HsI' intermediate
  -- representation altogether.
  toHsI' :: a -> HsI t

-- | OVERLAPPABLE. Identity.
instance {-# OVERLAPPABLE #-} (Tabla t, HsI t ~ a) => ToHsI t a where
  toHsI' = id
  {-# INLINE toHsI' #-}

-- | Like 'toHsI'', except it takes @t@ explicitely for the times when
-- it can't be inferred.
toHsI :: ToHsI t a => T t -> a -> HsI t
toHsI _ = toHsI'
{-# INLINE toHsI #-}

-- | Convenience intended to be used within 'toHsI'', together with 'HL.hBuild'.
--
-- @
-- 'toHsI' (Person name age) = 'mkHsI' $ \\set_ -> 'HL.hBuild'
--     (set_ ('C' :: 'C' "name") name)
--     (set_ ('C' :: 'C' "age") age)
-- @

-- TODO: see if it is posisble to pack 'hsi' and 'HL.hBuild' into
-- a single thing.
mkHsI
  :: forall t xs
  .  (Tabla t, HL.HRearrange (HL.LabelsOf (Cols_HsI t)) xs (Cols_HsI t))
  => ((forall c a. (C c -> a -> Tagged (TC t c) a)) -> HList xs)
  -> HsI t -- ^
mkHsI k = Tagged
        $ HL.Record
        $ HL.hRearrange2 (Proxy :: Proxy (HL.LabelsOf (Cols_HsI t)))
        $ k (const Tagged)
{-# INLINE mkHsI #-}

--------------------------------------------------------------------------------

-- | Use with 'HL.ApplyAB' to apply convert a field in a
-- @('HList' ('Cols_HsI' t)@) to a field in a @('HList' ('Cols_PgW' t))@.
data FnPgWfromHsIField = FnPgWfromHsIField
instance HL.ApplyAB FnPgWfromHsIField x x where
  applyAB _ = id
instance (ToKol a b) => HL.ApplyAB FnPgWfromHsIField a (Kol b) where
  applyAB _ = kol
instance (ToKol a b) => HL.ApplyAB FnPgWfromHsIField (WDef a) (WDef (Kol b)) where
  applyAB _ = fmap kol
instance (ToKol a b) => HL.ApplyAB FnPgWfromHsIField (Maybe a) (Koln b) where
  applyAB _ = maybe nul koln
instance (ToKol a b) => HL.ApplyAB FnPgWfromHsIField (WDef (Maybe a)) (WDef (Koln b)) where
  applyAB _ = fmap (maybe nul koln)

-- | You'll need to use this function to convert a 'HsI' to a 'PgW' when using 'O.runInsert'.
toPgW_fromHsI' :: Tabla t => HsI t -> PgW t
toPgW_fromHsI' = Tagged . HL.hMap FnPgWfromHsIField . unTagged
{-# INLINE toPgW_fromHsI' #-}

-- | Like 'toPgW_fromHsI'', but takes an explicit @t@.
toPgW_fromHsI :: Tabla t => T t -> HsI t -> PgW t
toPgW_fromHsI _ = toPgW_fromHsI'
{-# INLINE toPgW_fromHsI #-}

--------------------------------------------------------------------------------

-- | Convert a custom Haskell type to a representation appropiate for /inserting/
-- it as a new row.
toPgW' :: ToHsI t a => a -> PgW t
toPgW' = toPgW_fromHsI' . toHsI'
{-# INLINE toPgW' #-}

-- | Like 'toPgW'', but takes an explicit @t@.
toPgW :: ToHsI t a => T t -> a -> PgW t
toPgW _ = toPgW'
{-# INLINE toPgW #-}

--------------------------------------------------------------------------------

-- | Use with 'HL.ApplyAB' to apply convert a field in a
-- @('HList' ('Cols_PgR' t)@) to a field in a @('HList' ('Cols_PgW' t))@.
data FnPgWfromPgRField = FnPgWfromPgRField
instance HL.ApplyAB FnPgWfromPgRField x x where
  applyAB _ = id
instance PgType pg => HL.ApplyAB FnPgWfromPgRField (Kol pg) (WDef (Kol pg)) where
  applyAB _ = WVal
instance PgType pg => HL.ApplyAB FnPgWfromPgRField (Koln pg) (WDef (Koln pg)) where
  applyAB _ = WVal

-- | Convert a @('PgR' t)@ resulting from a 'O.queryTable'-like operation
-- to a @('PgW' t)@ that can be used in a 'Opaleye.SOT.runUpdate'-like
-- operation.
update' :: Tabla t => PgR t -> PgW t
update' = Tagged . HL.hMap FnPgWfromPgRField . unTagged
{-# INLINE update' #-}

-- | Like 'update'', but takes an explicit @t@ for when it can't be inferred.
update :: Tabla t => T t -> PgR t -> PgW t
update _ = update'
{-# INLINE update #-}

--------------------------------------------------------------------------------

-- | Column properties: Write (no default), Read (not nullable).
colProps_wr :: PgType a => String -> O.TableProperties (Kol a) (Kol a)
colProps_wr = P.dimap unKol Kol . O.required

-- | Column properties: Write (no default), Read (nullable).
colProps_wrn :: PgType a => String -> O.TableProperties (Koln a) (Koln a)
colProps_wrn = P.dimap unKoln Koln . O.required

-- | Column properties: Write (optional default), Read (not nullable).
colProps_wdr :: PgType a => String -> O.TableProperties (WDef (Kol a)) (Kol a)
colProps_wdr = P.dimap (wdef Nothing Just . fmap unKol) Kol . O.optional

-- | Column properties: Write (optional default), Read (nullable).
colProps_wdrn :: PgType a => String -> O.TableProperties (WDef (Koln a)) (Koln a)
colProps_wdrn = P.dimap (wdef Nothing Just . fmap unKoln) Koln . O.optional

--------------------------------------------------------------------------------

-- | 'O.TableProperties' for all the columns in 'Tabla' @t@.
type Cols_Props t = List.Map (Col_PropsSym1 t) (Cols t)

-- | 'O.TableProperties' for a single column in 'Tabla' @t@.
type Col_Props t (col :: Col GHC.Symbol WD RN * *)
  = O.TableProperties (Col_PgW t col) (Col_PgR t col)
data Col_PropsSym1 t (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_PropsSym1 t) col = Col_Props t col
data Col_PropsSym0 (col :: TyFun t (TyFun (Col GHC.Symbol WD RN * *) * -> *))
type instance Apply Col_PropsSym0 t = Col_PropsSym1 t

class ICol_Props (col :: Col GHC.Symbol WD RN * *) where
  colProps :: Tabla t => Proxy t -> Proxy col -> Col_Props t col

-- | 'colProps' is equivalent 'colProps_wr'.
instance forall n p h. (GHC.KnownSymbol n, PgType p) => ICol_Props ('Col n 'W 'R p h) where
  colProps _ = \_ -> ppaUnTagged (colProps_wr (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'colProps_wrn'.
instance forall n p h. (GHC.KnownSymbol n, PgType p) => ICol_Props ('Col n 'W 'RN p h) where
  colProps _ = \_ -> ppaUnTagged (colProps_wrn (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'colProps_wdr'.
instance forall n p h. (GHC.KnownSymbol n, PgType p) => ICol_Props ('Col n 'WD 'R p h) where
  colProps _ = \_ -> ppaUnTagged (colProps_wdr (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'colProps_wdrn'.
instance forall n p h. (GHC.KnownSymbol n, PgType p) => ICol_Props ('Col n 'WD 'RN p h) where
  colProps _ = \_ -> ppaUnTagged (colProps_wdrn (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}

-- | Use with 'HL.ApplyAB' to apply 'colProps' to each element of an 'HList'.
data FnCol_Props t = FnCol_Props

instance forall t (col :: Col GHC.Symbol WD RN * *) pcol out n w r p h
  . ( Tabla t
    , GHC.KnownSymbol n
    , ICol_Props col
    , pcol ~ Proxy col
    , col ~ 'Col n w r p h
    , out ~ Col_Props t col
    ) => HL.ApplyAB (FnCol_Props t) pcol out
    where
      applyAB _ = colProps (Proxy :: Proxy t)
      {-# INLINE applyAB #-}

--------------------------------------------------------------------------------

-- | Build the Opaleye 'O.Table' for a 'Tabla'.
table' :: forall t. Tabla t => O.Table (PgW t) (PgR t)
table' = O.TableWithSchema
   (GHC.symbolVal (Proxy :: Proxy (SchemaName t)))
   (GHC.symbolVal (Proxy :: Proxy (TableName t)))
   (ppaUnTagged $ ppa $ HL.Record
      (HL.hMapL (FnCol_Props :: FnCol_Props t)
      (hDistributeProxy (Proxy :: Proxy (Cols t)))))

-- | Like 'table'', but takes @t@ explicitly to help the compiler when it
-- can't infer @t@.
table :: Tabla t => T t -> O.Table (PgW t) (PgR t)
table _ = table'

-- | Like Opaleye's 'O.queryTable', but for a 'Tabla'.
queryTabla' :: Tabla t => O.Query (PgR t)
queryTabla' = O.queryTable table'

-- | Like 'queryTabla'', but takes @t@ explicitly to help the compiler when it
-- can't infer @t@.
queryTabla :: Tabla t => T t -> O.Query (PgR t)
queryTabla _ = queryTabla'

--------------------------------------------------------------------------------

-- | Lens to a column.
--
-- Mnemonic: The COLumn.
col :: forall t c xs xs' a a'
    .  HL.HLensCxt (TC t c) HL.Record xs xs' a a'
    => C c
    -> Lens (Rec t xs) (Rec t xs') a a'
col _ = _Wrapped . HL.hLens (HL.Label :: HL.Label (TC t c))
{-# INLINE col #-}

-- | Like 'col', but the column is tagged with 'TC'.
--
-- Mnemonic: the COLumn, Tagged.
--
-- TODO: Do we really need this? Can it be removed?
colt :: forall t c xs xs' a a'
      . HL.HLensCxt (TC t c) HL.Record xs xs' a a'
     => C c
     -> Lens (Rec t xs) (Rec t xs') (Tagged (TC t c) a) (Tagged (TC t c) a')
colt prx = col prx . _Unwrapped
{-# INLINE colt #-}

--------------------------------------------------------------------------------
-- Unary operations on columns

-- | Constraint on arguments to 'lnot'.
type Op_lnot a b = Op1' O.PGBool O.PGBool (Kol O.PGBool) (Kol O.PGBool) a b
-- | Polymorphic Opaleye's 'O.not'. See 'eq' for the type of arguments this
-- function can take.
--
-- Mnemonic: Logical NOT.
lnot :: Op_lnot a b => a -> b
lnot = op1 (liftKol1 O.not)

--------------------------------------------------------------------------------
-- Binary operations on columns

-- | Constraints on arguments to 'eq'.
--
-- Given as @a@ and @b@ any combination of @('Kol' x)@, @('Koln' x)@ or their
-- respective wrappings in @('Tagged' ('TC' t c))@, get @c@ as result, which
-- will be @('Koln' 'O.PGBool')@ if there was a @('Koln' x)@ among the given
-- arguments, otherwise it will be @('Kol' 'O.PGBool')@.
--
-- This type synonym is exported for two reasons:
--
-- 1. It increases the readability of the type of 'eq' and any type errors
--    resulting from its misuse.
--
-- 2. If you are taking any of @a@ or @b@ as arguments to a function
--    where 'eq' is used, then you will need to ensure that some
--    constraints are satisfied by those arguments. Adding 'Op_eq' as a
--    constraint to that function will solve the problem.
--
-- /To keep in mind/: The type @c@ is fully determined by @x@, @a@, and @b@. This
-- has the practical implication that when both @('Kol' z)@ and @('Koln' z)@
-- would be suitable types for @c@, we make a choice and prefer to only support
-- @('Kol' z)@, leaving you to use 'koln' on the return type if you want to
-- convert it to @('Koln' z)@. This little inconvenience, however, significantly
-- improves type inference when using 'eq'.
type Op_eq x a b c = Op2' x x O.PGBool (Kol x) (Kol x) (Kol O.PGBool) a b c

-- | Polymorphic Opaleye's @('O..==')@.
--
-- Mnemonic reminder: EQual.
--
-- @
-- 'eq' :: 'Kol' x -> 'Kol' x -> 'Kol' 'O.PGBool'
-- 'eq' :: 'Kol' x -> 'Koln' x -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Kol' x -> 'Tagged' t ('Kol' x) -> 'Kol' 'O.PGBool'
-- 'eq' :: 'Kol' x -> 'Tagged' t ('Koln' x) -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Koln' x -> 'Kol' x -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Koln' x -> 'Koln' x -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Koln' x -> 'Tagged' t ('Kol' x) -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Koln' x -> 'Tagged' t ('Koln' x) -> 'Koln' 'O.PGBool'
-- @
--
-- Any of the above combinations with the arguments fliped is accepted too.
--
-- /Important/: Opaleye's 'O.Column' is deliberately not supported. Use 'kol'
-- or 'koln' to convert a 'O.Column' to a 'Kol' or 'Koln' respectively.
--
-- /Debugging hint/: If the combination of @a@ and @b@ that you give to 'eq' is
-- unacceptable, you will get an error from the typechecker saying that an
-- 'Op2'' instance is missing. Do not try to add a new instance for 'Op2'', it
-- is an internal class that already supports all the possible combinations of
-- @x@, @a@, @b@, and @c@. Instead, make sure your are not trying to do
-- something funny such as comparing two 'Koln's for equality and expecting a
-- 'Kol' as a result (that is, you would be trying to compare two nullable
-- columns and ignoring the possibilty that one of the arguments might be
-- @NULL@, leading to a @NULL@ result).
eq :: Op_eq x a b c => a -> b -> c
eq = go where -- we hide the 'forall' from the type signature
  go :: forall x a b c. Op_eq x a b c => a -> b -> c
  go = op2 (liftKol2 (O..==) :: Kol x -> Kol x -> Kol O.PGBool)

-- | Constraint on arguments to 'eqs'. See 'Op_eq' for a detailed explanation.
type Op_eqs f x a b c = (Op_eq x a b c, Op_lors c, Functor f, Foldable f)
-- | Like Opaleye's @('O.eqs')@, but can accept more arguments than just 'O.Column'.
-- See 'eq' for a detailed explanation.
--
-- Mnemonic reminder: EQualS.
eqs :: Op_eqs f x a b c => a -> f b -> c
eqs a = lors . fmap (eq a)

---
-- | Constraint on arguments to 'lt'. See 'Op_eq' for a detailed explanation.
type Op_lt x a b c = (O.PGOrd x, Op2' x x O.PGBool (Kol x) (Kol x) (Kol O.PGBool) a b c)
-- | Like Opaleye's @('O..<')@, compares whether the first argument is less
-- than the second argument, but can accept more arguments than just 'O.Column'.
-- See 'eq' for a detailed explanation.
--
-- Mnemonic reminder: Less Than.
lt :: Op_lt x a b c => a -> b -> c
lt = go where -- we hide the 'forall' from the type signature
  go :: forall x a b c. Op_lt x a b c => a -> b -> c
  go = op2 (liftKol2 (O..<) :: Kol x -> Kol x -> Kol O.PGBool)

---
-- | Constraint on arguments to 'lte'. See 'Op_eq' for a detailed explanation.
type Op_lte x a b c = (O.PGOrd x, Op2' x x O.PGBool (Kol x) (Kol x) (Kol O.PGBool) a b c)
-- | Like Opaleye's @('O..<=')@, compares whether the first argument is less
-- than or equal to the second argument, but can accept more arguments than just
-- 'O.Column'.  See 'eq' for a detailed explanation.
--
-- Mnemonic reminder: Less Than or Equal.
lte :: Op_lte x a b c => a -> b -> c
lte = go where -- we hide the 'forall' from the type signature
  go :: forall x a b c. Op_lte x a b c => a -> b -> c
  go = op2 (liftKol2 (O..<=) :: Kol x -> Kol x -> Kol O.PGBool)

---
-- | Constraint on arguments to 'gt'. See 'Op_eq' for a detailed explanation.
type Op_gt x a b c = (O.PGOrd x, Op2' x x O.PGBool (Kol x) (Kol x) (Kol O.PGBool) a b c)
-- | Like Opaleye's @('O..>')@, compares whether the first argument is greater
-- than the second argument, but can accept more arguments than just 'O.Column'.
-- See 'eq' for a detailed explanation.
--
-- Mnemonic reminder: Less Than.
gt :: Op_gt x a b c => a -> b -> c
gt = go where -- we hide the 'forall' from the type signature
  go :: forall x a b c. Op_gt x a b c => a -> b -> c
  go = op2 (liftKol2 (O..<) :: Kol x -> Kol x -> Kol O.PGBool)

---
-- | Constraint on arguments to 'gte'. See 'Op_eq' for a detailed explanation.
type Op_gte x a b c = (O.PGOrd x, Op2' x x O.PGBool (Kol x) (Kol x) (Kol O.PGBool) a b c)
-- | Like Opaleye's @('O..>=')@, compares whether the first argument is greater
-- than or equal to the second argument, but can accept more arguments than just
-- 'O.Column'.  See 'eq' for a detailed explanation.
--
-- Mnemonic reminder: Greater Than or Equal.
gte :: Op_gte x a b c => a -> b -> c
gte = go where -- we hide the 'forall' from the type signature
  go :: forall x a b c. Op_gte x a b c => a -> b -> c
  go = op2 (liftKol2 (O..>=) :: Kol x -> Kol x -> Kol O.PGBool)

---
-- | Constraint on arguments to 'lor'. See 'Op_eq' for a detailed explanation.
type Op_lor a b c = Op2' O.PGBool O.PGBool O.PGBool (Kol O.PGBool) (Kol O.PGBool) (Kol O.PGBool) a b c
-- | Like Opaleye's @('O..||')@, but can accept more arguments than just 'O.Column'.
-- See 'eq' for a detailed explanation.
--
-- Mnemonic: Logical OR.
lor :: Op_lor a b c => a -> b -> c
lor = op2 (liftKol2 (O..||))

---
-- | Internal. We don't export this because 'or' is more general.
class Op_lors a where
  -- | Like Opaleye's @('O.lors')@, but can accept more arguments than just
  -- 'O.Column'. See 'eq' for a detailed explanation.
  lors :: Foldable f => f a -> a
instance Op_lors (Kol O.PGBool) where lors = foldl' lor (kol False)
instance Op_lors (Koln O.PGBool) where lors = foldl' lor (koln False)

---
-- | Constraint on arguments to 'land'. See 'Op_eq' for a dlandailed explanation.
type Op_land a b c = Op2' O.PGBool O.PGBool O.PGBool (Kol O.PGBool) (Kol O.PGBool) (Kol O.PGBool) a b c
-- | Like Opaleye's @('O..&&')@, but can accept more arguments than just 'O.Column'.
-- See 'eq' for a dlandailed explanation.
--
-- Mnemonic: Logical AND.
land :: Op_land a b c => a -> b -> c
land = op2 (liftKol2 (O..&&))

--------------------------------------------------------------------------------

-- | Look up a 'Kol' inside some kind of wrapper.
--
-- This class makes it possible to accept both @('Kol' a)@ and
-- @('Tagged' ('TC' t c) ('Kol' a))@ as arguments in various @opaleye-sot@
-- functions.
class PgType a => GetKol w a | w -> a where getKol :: w -> Kol a
-- | Identity.
instance PgType a => GetKol (Kol a) a where getKol = id
instance PgType a => GetKol (Tagged (TC t c) (Kol a)) a where getKol = unTagged

-- | Look up a 'Koln' inside some kind of wrapper.
--
-- This class makes it possible to accept both @('Koln' a)@ and
-- @('Tagged' ('TC' t c) ('Koln' a))@ as arguments in various @opaleye-sot@
-- functions.
class PgType a => GetKoln w a | w -> a where getKoln :: w -> Koln a
-- | Identity.
instance PgType a => GetKoln (Koln a) a where getKoln = id
instance PgType a => GetKoln (Tagged (TC t c) (Koln a)) a where getKoln = unTagged

--------------------------------------------------------------------------------

-- | Like Opaleye's 'O.isNull', but works for any 'GetKoln'.
isNull :: GetKoln w a => w -> Kol O.PGBool
isNull = Kol . O.isNull . unKoln . getKoln

-- | Flatten @('Koln' 'O.PGBool')@ or compatible (see 'GetKoln') to
-- @('Kol' 'O.PGBool')@. An outer @NULL@ is converted to @TRUE@.
--
-- This can be used as a function or as a 'O.QueryArr', whatever works best
-- for you. The 'O.QueryArr' support is often convenient when working with
-- 'restrict':
--
-- @
-- 'restrict' '<<<' 'nullTrue' -< ...
-- @
--
-- Simplified types:
--
-- @
-- 'nullTrue' :: 'Koln' 'O.PGBool' -> 'Kol' 'O.PGBool'
-- 'nullTrue' :: 'Koln' ('Tagged' ('TC' t c) 'O.PGBool') -> 'Kol' 'O.PGBool'
-- 'nullTrue' :: 'O.QueryArr' ('Koln' 'O.PGBool') ('Kol' 'O.PGBool')
-- 'nullTrue' :: 'O.QueryArr' ('Koln' ('Tagged' ('TC' t c) 'O.PGBool')) ('Kol' 'O.PGBool')
-- @
nullTrue :: (Arrow f, GetKoln w O.PGBool) => f w (Kol O.PGBool)
nullTrue = arr $ matchKoln (kol True) id . getKoln

-- | Like 'nullTrue', but an outer @NULL@ is converted to @FALSE@.
nullFalse :: (Arrow f, GetKoln w O.PGBool) => f w (Kol O.PGBool)
nullFalse = arr $ matchKoln (kol False) id . getKoln

-- | Like Opaleye's 'O.restric', but takes a 'Kol' as input.
--
-- @
-- 'restrict' :: 'O.QueryArr' ('Kol' 'O.PGBool') ()
-- 'restrict' :: 'O.QueryArr' ('Kol' ('Tagged' ('TC' t c) 'O.PGBool')) ()
-- @
restrict :: GetKol w O.PGBool => O.QueryArr w ()
restrict = O.restrict <<^ unKol <<^ getKol

-- | Like Opaleye's 'O.leftJoin', but the predicate is expected to
-- return a @('GetKol' w 'O.PGBool')@.
leftJoin
  :: ( PP.Default O.Unpackspec a a
     , PP.Default O.Unpackspec b b
     , PP.Default OI.NullMaker b nb
     , GetKol gkb O.PGBool )
   => O.Query a -> O.Query b -> ((a, b) -> gkb) -> O.Query (a, nb) -- ^
leftJoin = leftJoinExplicit PP.def PP.def PP.def

-- | Like Opaleye's 'O.leftJoinExplicit', but the predicate is expected to
-- return a @('GetKol' w 'O.PGBool')@.
leftJoinExplicit
  :: GetKol gkb O.PGBool
  => O.Unpackspec a a -> O.Unpackspec b b -> OI.NullMaker b nb
  -> O.Query a -> O.Query b -> ((a, b) -> gkb) -> O.Query (a, nb) -- ^
leftJoinExplicit ua ub nmb qa qb fil =
  O.leftJoinExplicit ua ub nmb qa qb (unKol . getKol . fil)

--------------------------------------------------------------------------------
-- Ordering

-- | Ascending order, no @NULL@s involved.
asc :: (GetKol w b, O.PGOrd b) => (a -> w) -> O.Order a
asc f = O.asc (unKol . getKol . f)

-- | Ascending order, @NULL@s last.
ascnl :: (GetKoln w b, O.PGOrd b) => (a -> w) -> O.Order a
ascnl f = O.asc (unsafeUnNullableColumn . unKoln . getKoln . f)

-- | Ascending order, @NULL@s first.
ascnf :: (GetKoln w b, O.PGOrd b) => (a -> w) -> O.Order a
ascnf f = O.ascNullsFirst (unsafeUnNullableColumn . unKoln . getKoln . f)

-- | Descending order, no @NULL@s involved.
desc :: (GetKol w b, O.PGOrd b) => (a -> w) -> O.Order a
desc f = O.desc (unKol . getKol . f)

-- | Descending order, @NULL@s first.
descnf :: (GetKoln w b, O.PGOrd b) => (a -> w) -> O.Order a
descnf f = O.desc (unsafeUnNullableColumn . unKoln . getKoln . f)

-- | Descending order, @NULL@s last.
descnl :: (GetKoln w b, O.PGOrd b) => (a -> w) -> O.Order a
descnl f = O.descNullsLast (unsafeUnNullableColumn . unKoln . getKoln . f)

--------------------------------------------------------------------------------

ppaUnTagged :: P.Profunctor p => p a b -> p (Tagged ta a) (Tagged tb b)
ppaUnTagged = P.dimap unTagged Tagged
{-# INLINE ppaUnTagged #-}

-- | A generalization of product profunctor adaptors such as 'PP.p1', 'PP.p4', etc.
--
-- The functional dependencies make type inference easier, but also forbid some
-- otherwise acceptable instances.
class P.Profunctor p => ProductProfunctorAdaptor p l ra rb | p l -> ra rb, p ra rb -> l where
  ppa :: l -> p ra rb

-- | 'HList' of length 0.
instance PP.ProductProfunctor p => ProductProfunctorAdaptor p (HList '[]) (HList '[]) (HList '[]) where
  ppa = const (P.dimap (const ()) (const HNil) PP.empty)
  {-# INLINE ppa #-}

-- | 'HList' of length 1 or more.
instance
    ( PP.ProductProfunctor p
    , ProductProfunctorAdaptor p (HList pabs) (HList as) (HList bs)
    ) => ProductProfunctorAdaptor p (HList (p a1 b1 ': pabs)) (HList (a1 ': as)) (HList (b1 ': bs)) where
  ppa = \(HCons pab1 pabs) -> P.dimap (\(HCons x xs) -> (x,xs)) (uncurry HCons) (pab1 PP.***! ppa pabs)

instance
    ( ProductProfunctorAdaptor p (HList pabs) (HList as) (HList bs)
    ) => ProductProfunctorAdaptor p (HL.Record pabs) (HL.Record as) (HL.Record bs) where
  ppa = P.dimap unRecord HL.Record . ppa . unRecord
  {-# INLINE ppa #-}

--------------------------------------------------------------------------------

-- | Orphan. 'Opaleye.SOT.Internal'.
instance (PP.ProductProfunctor p, PP.Default p a b) => PP.Default p (Tagged ta a) (Tagged tb b) where
  def = ppaUnTagged PP.def
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance PP.ProductProfunctor p => PP.Default p (HList '[]) (HList '[]) where
  def = ppa HNil
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p a1 b1, PP.Default p (HList as) (HList bs)
    ) => PP.Default p (HList (a1 ': as)) (HList (b1 ': bs)) where
  def = P.dimap (\(HCons x xs) -> (x,xs)) (uncurry HCons) (PP.def PP.***! PP.def)

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p (HList as) (HList bs)
    ) => PP.Default p (HL.Record as) (HL.Record bs) where
  def = P.dimap unRecord HL.Record PP.def
  {-# INLINE def #-}

-- Maybes on the rhs

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p a (Maybe b)
    ) => PP.Default p (Tagged ta a) (Maybe (Tagged tb b)) where
  def = P.dimap unTagged (fmap Tagged) PP.def
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'. Defaults to 'Just'.
instance PP.ProductProfunctor p => PP.Default p (HList '[]) (Maybe (HList '[])) where
  def = P.rmap Just PP.def
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p
    , PP.Default p a (Maybe b)
    , PP.Default p (HList as) (Maybe (HList bs))
    ) => PP.Default p (HList (a ': as)) (Maybe (HList (b ': bs))) where
  def = P.dimap (\(HCons a as) -> (a, as))
                (\(mb, mbs) -> HCons <$> mb <*> mbs)
                (PP.def PP.***! PP.def)

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p (HList as) (Maybe (HList bs))
    ) => PP.Default p (HL.Record as) (Maybe (HL.Record bs)) where
  def = P.dimap unRecord (fmap HL.Record) PP.def
  {-# INLINE def #-}

--------------------------------------------------------------------------------
-- Misc

-- | Apply a same constraint to all the types in the list.
type family All (c :: k -> Constraint) (xs :: [k]) :: Constraint where
  All c '[]       = ()
  All c (x ': xs) = (c x, All c xs)

---

-- | Defunctionalized 'Proxy'. To be used with 'Apply'.
data ProxySym0 (a :: TyFun k *)
type instance Apply ProxySym0 a = Proxy a

class HDistributeProxy (xs :: [k]) where
  hDistributeProxy :: Proxy xs -> HList (List.Map ProxySym0 xs)
instance HDistributeProxy ('[] :: [k]) where
  hDistributeProxy _ = HNil
  {-# INLINE hDistributeProxy #-}
instance forall (x :: k) (xs :: [k]). HDistributeProxy xs => HDistributeProxy (x ': xs) where
  hDistributeProxy _ = HCons (Proxy :: Proxy x) (hDistributeProxy (Proxy :: Proxy xs))

---

unRecord :: HL.Record xs -> HList xs
unRecord = \(HL.Record x) -> x
{-# INLINE unRecord #-}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Belongs in Opaleye

unsafeUnNullableColumn :: O.Column (O.Nullable a) -> O.Column a
unsafeUnNullableColumn = O.unsafeCoerceColumn

pgFloat4 :: Float -> O.Column O.PGFloat4
pgFloat4 = OI.literalColumn . OI.DoubleLit . float2Double

pgFloat8 :: Float -> O.Column O.PGFloat8
pgFloat8 = OI.literalColumn . OI.DoubleLit . float2Double

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Support for overloaded unary operators working on Kol or Koln

-- |This is just a synonym for 'Op1'' in order to reduce the noise in the
-- Hadocks.
type Op1 a b fa fb xa xb = Op1' a b fa fb xa xb

-- | Internal. Do not add any new 'Op1'' instances.
--
-- Instances of this class can be used to convert an unary function
-- @(fa -> fb)@ to an unary function @(xa -> xb)@, provided the functional
-- dependencies are satisfied.
--
-- We use the instances of this class to predicatably generalize the
-- type of negative and positive arguments to unary functions on 'Kol' or
-- 'Koln'.
class (PgType a, PgType b) => Op1' a b fa fb xa xb | fa -> a, fb -> b, xa -> a, xb -> b, xa fa fb -> xb where
  -- | Generalize the negative and positive arguments of the given function
  -- so that it works for as many combinations of @('Kol' x)@, @('Koln' x)@,
  -- @('Tagged' ('TC' t c) ('Kol' x))@ or @('Tagged' ('TC' t c) ('Koln' x))@ as
  -- possible.
  op1 :: (fa -> fb) -> (xa -> xb)

-- Note: possibly some of these instances could be generalized, but it's hard
-- to keep track of them, so I write all the possible combinations explicitely.

-- | kk -> kk
instance (PgType a, PgType b) => Op1' a b (Kol a) (Kol b) (Kol a) (Kol b) where op1 f ka = f ka
-- | kk -> nn
instance (PgType a, PgType b) => Op1' a b (Kol a) (Kol b) (Koln a) (Koln b) where op1 f na = mapKoln f na
-- | kk -> tx
instance (Op1' a b (Kol a) (Kol b) xa xb) => Op1' a b (Kol a) (Kol b) (Tagged (TC t c) xa) xb where op1 f (Tagged xa) = op1 f xa
-- | kn -> kn
instance (PgType a, PgType b) => Op1' a b (Kol a) (Koln b) (Kol a) (Koln b) where op1 f ka = f ka
-- | kn -> nn
instance (PgType a, PgType b) => Op1' a b (Kol a) (Koln b) (Koln a) (Koln b) where op1 f na = bindKoln na f
-- | kn -> tn
instance (Op1' a b (Kol a) (Koln b) xa (Koln b)) => Op1' a b (Kol a) (Koln b) (Tagged (TC t c) xa) (Koln b) where op1 f (Tagged xa) = op1 f xa
-- | nk -> kk
instance (PgType a, PgType b) => Op1' a b (Koln a) (Kol b) (Kol a) (Kol b) where op1 f ka = f (fromKol ka)
-- | nk -> nk
instance (PgType a, PgType b) => Op1' a b (Koln a) (Kol b) (Koln a) (Kol b) where op1 f na = f na
-- | nk -> tk
instance (Op1' a b (Koln a) (Kol b) xa (Kol b)) => Op1' a b (Koln a) (Kol b) (Tagged (TC t c) xa) (Kol b) where op1 f (Tagged xa) = op1 f xa
-- | nn -> kn
instance (PgType a, PgType b) => Op1' a b (Koln a) (Koln b) (Kol a) (Koln b) where op1 f ka = f (fromKol ka)
-- | nn -> nn
instance (PgType a, PgType b) => Op1' a b (Koln a) (Koln b) (Koln a) (Koln b) where op1 f na = f na
-- | nn -> tn
instance (Op1' a b (Koln a) (Koln b) xa (Koln b)) => Op1' a b (Koln a) (Koln b) (Tagged (TC t c) xa) (Koln b) where op1 f (Tagged xa) = op1 f xa

--------------------------------------------------------------------------------
-- Support for overloaded binary operators working on Kol or Koln

-- |This is just a synonym for 'Op2'' in order to reduce the noise in the
-- Hadocks.
type Op2 a b c fa fb fc xa xb xc = Op2' a b c fa fb fc xa xb xc

-- | Internal. Do not add any new 'Op2'' instances.
--
-- Instances of this class can be used to convert an unary function
-- @(fa -> fb)@ to an unary function @(xa -> xb)@, provided the functional
-- dependencies are satisfied.
--
-- We use the instances of this class to predicatably generalize the
-- type of negative and positive arguments to unary functions on 'Kol' or
-- 'Koln'.
class (PgType a, PgType b, PgType c) => Op2' a b c fa fb fc xa xb xc | fa -> a, fb -> b, fc -> c, xa -> a, xb -> b, xc -> c, xa xb fa fb fc -> xc where
  -- | Generalize the negative and positive arguments of the given function
  -- so that it works for as many combinations of @('Kol' x)@, @('Koln' x)@,
  -- @('Tagged' ('TC' t c) ('Kol' x))@ or @('Tagged' ('TC' t c) ('Koln' x))@ as
  -- possible.
  op2 :: (fa -> fb -> fc) -> (xa -> xb -> xc)

-- Note: possibly some of these instances could be generalized, but it's hard
-- to keep track of them, so I write all the possible combinations explicitely.

-- | kkk -> kkk -- @k@ means 'Kol'
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Kol b) (Kol c) (Kol a) (Kol b) (Kol c) where op2 f ka kb = f ka kb
-- | kkk -> knn -- @n@ means 'Koln'
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Kol b) (Kol c) (Kol a) (Koln b) (Koln c) where op2 f ka nb = mapKoln (f ka) nb
-- | kkk -> ktx -- @t@ means 'Tagged' with 'TC', @x@ means any.
instance (Op2' a b c (Kol a) (Kol b) (Kol c) (Kol a) xb xc) => Op2' a b c (Kol a) (Kol b) (Kol c) (Kol a) (Tagged (TC tb cb) xb) xc where op2 f ka (Tagged xb) = op2 f ka xb
-- | kkk -> nkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Kol b) (Kol c) (Koln a) (Kol b) (Koln c) where op2 f na kb = mapKoln (flip f kb) na
-- | kkk -> nnn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Kol b) (Kol c) (Koln a) (Koln b) (Koln c) where op2 f na nb = bindKoln na (\ka -> mapKoln (f ka) nb)
-- | kkk -> ntn
instance (Op2' a b c (Kol a) (Kol b) (Kol c) (Koln a) xb (Koln c)) => Op2' a b c (Kol a) (Kol b) (Kol c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where op2 f na (Tagged xb) = op2 f na xb
-- | kkk -> tkx
instance (Op2' a b c (Kol a) (Kol b) (Kol c) xa (Kol b) xc) => Op2' a b c (Kol a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Kol b) xc  where op2 f (Tagged xa) kb = op2 f xa kb
-- | kkk -> tnk
instance (Op2' a b c (Kol a) (Kol b) (Kol c) xa (Koln b) (Koln c)) => Op2' a b c (Kol a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where op2 f (Tagged xa) nb = op2 f xa nb
-- | kkk -> ttx
instance (Op2' a b c (Kol a) (Kol b) (Kol c) xa xb xc) => Op2' a b c (Kol a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) xc where op2 f (Tagged xa) (Tagged xb) = op2 f xa xb

-- | kkn -> kkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Kol b) (Koln c) (Kol a) (Kol b) (Koln c) where op2 f ka kb = f ka kb
-- | kkn -> knn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Kol b) (Koln c) (Kol a) (Koln b) (Koln c) where op2 f ka nb = bindKoln nb (f ka)
-- | kkn -> ktn
instance (Op2' a b c (Kol a) (Kol b) (Koln c) (Kol a) xb (Koln c)) => Op2' a b c (Kol a) (Kol b) (Koln c) (Kol a) (Tagged (TC tb cb) xb) (Koln c) where op2 f ka (Tagged xb) = op2 f ka xb
-- | kkn -> nkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Kol b) (Koln c) (Koln a) (Kol b) (Koln c) where op2 f na kb = bindKoln na (flip f kb)
-- | kkn -> nnn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Kol b) (Koln c) (Koln a) (Koln b) (Koln c) where op2 f na nb = bindKoln na (\ka -> bindKoln nb (f ka))
-- | kkn -> ntn
instance (Op2' a b c (Kol a) (Kol b) (Koln c) (Koln a) xb (Koln c)) => Op2' a b c (Kol a) (Kol b) (Koln c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where op2 f na (Tagged xb) = op2 f na xb
-- | kkn -> tkn
instance (Op2' a b c (Kol a) (Kol b) (Koln c) xa (Kol b) (Koln c)) => Op2' a b c (Kol a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Kol b) (Koln c) where op2 f (Tagged xa) kb = op2 f xa kb
-- | kkn -> tnn
instance (Op2' a b c (Kol a) (Kol b) (Koln c) xa (Koln b) (Koln c)) => Op2' a b c (Kol a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where op2 f (Tagged xa) nb = op2 f xa nb
-- | kkn -> ttn
instance (Op2' a b c (Kol a) (Kol b) (Koln c) xa xb (Koln c)) => Op2' a b c (Kol a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Koln c) where op2 f (Tagged xa) (Tagged xb) = op2 f xa xb

-- | knk -> kkk
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Koln b) (Kol c) (Kol a) (Kol b) (Kol c) where op2 f ka kb = f ka (fromKol kb)
-- | knk -> knk
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Koln b) (Kol c) (Kol a) (Koln b) (Kol c) where op2 f ka nb = f ka nb
-- | knk -> ktk
instance (Op2' a b c (Kol a) (Koln b) (Kol c) (Kol a) xb (Kol c)) => Op2' a b c (Kol a) (Koln b) (Kol c) (Kol a) (Tagged (TC tb cb) xb) (Kol c) where op2 f ka (Tagged xb) = op2 f ka xb
-- | knk -> nkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Koln b) (Kol c) (Koln a) (Kol b) (Koln c) where op2 f na kb = mapKoln (flip f (fromKol kb)) na
-- | knk -> nnn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Koln b) (Kol c) (Koln a) (Koln b) (Koln c) where op2 f na nb = mapKoln (flip f nb) na
-- | knk -> ntn
instance (Op2' a b c (Kol a) (Koln b) (Kol c) (Koln a) xb (Koln c)) => Op2' a b c (Kol a) (Koln b) (Kol c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where op2 f na (Tagged xb) = op2 f na xb
-- | knk -> tkx
instance (Op2' a b c (Kol a) (Koln b) (Kol c) xa (Kol b) xc) => Op2' a b c (Kol a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Kol b) xc  where op2 f (Tagged xa) kb = op2 f xa kb
-- | knk -> tnx
instance (Op2' a b c (Kol a) (Koln b) (Kol c) xa (Koln b) (Koln c)) => Op2' a b c (Kol a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where op2 f (Tagged xa) nb = op2 f xa nb
-- | knk -> ttx
instance (Op2' a b c (Kol a) (Koln b) (Kol c) xa xb xc) => Op2' a b c (Kol a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) xc where op2 f (Tagged xa) (Tagged xb) = op2 f xa xb

-- | knn -> kkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Koln b) (Koln c) (Kol a) (Kol b) (Koln c) where op2 f ka kb = f ka (fromKol kb)
-- | knn -> knn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Koln b) (Koln c) (Kol a) (Koln b) (Koln c) where op2 f ka nb = f ka nb
-- | knn -> ktn
instance (Op2' a b c (Kol a) (Koln b) (Koln c) (Kol a) xb (Koln c)) => Op2' a b c (Kol a) (Koln b) (Koln c) (Kol a) (Tagged (TC tb cb) xb) (Koln c) where op2 f ka (Tagged xb) = op2 f ka xb
-- | knn -> nkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Koln b) (Koln c) (Koln a) (Kol b) (Koln c) where op2 f na kb = bindKoln na (flip f (fromKol kb))
-- | knn -> nnn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Kol a) (Koln b) (Koln c) (Koln a) (Koln b) (Koln c) where op2 f na nb = bindKoln na (flip f nb)
-- | knn -> ntn
instance (Op2' a b c (Kol a) (Koln b) (Koln c) (Koln a) xb (Koln c)) => Op2' a b c (Kol a) (Koln b) (Koln c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where op2 f na (Tagged xb) = op2 f na xb
-- | knn -> tkn
instance (Op2' a b c (Kol a) (Koln b) (Koln c) xa (Kol b) (Koln c)) => Op2' a b c (Kol a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Kol b) (Koln c) where op2 f (Tagged xa) kb = op2 f xa kb
-- | knn -> tnn
instance (Op2' a b c (Kol a) (Koln b) (Koln c) xa (Koln b) (Koln c)) => Op2' a b c (Kol a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where op2 f (Tagged xa) nb = op2 f xa nb
-- | knn -> ttn
instance (Op2' a b c (Kol a) (Koln b) (Koln c) xa xb (Koln c)) => Op2' a b c (Kol a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Koln c) where op2 f (Tagged xa) (Tagged xb) = op2 f xa xb

-- | nkk -> kkk
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Kol b) (Kol c) (Kol a) (Kol b) (Kol c) where op2 f ka kb = f (fromKol ka) kb
-- | nkk -> knn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Kol b) (Kol c) (Kol a) (Koln b) (Koln c) where op2 f ka nb = mapKoln (f (fromKol ka)) nb
-- | nkk -> ktx
instance (Op2' a b c (Koln a) (Kol b) (Kol c) (Kol a) xb xc) => Op2' a b c (Koln a) (Kol b) (Kol c) (Kol a) (Tagged (TC tb cb) xb) xc where op2 f ka (Tagged xb) = op2 f ka xb
-- | nkk -> nkk
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Kol b) (Kol c) (Koln a) (Kol b) (Kol c) where op2 f na kb = f na kb
-- | nkk -> nnn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Kol b) (Kol c) (Koln a) (Koln b) (Koln c) where op2 f na nb = mapKoln (f na) nb
-- | nkk -> ntx
instance (Op2' a b c (Koln a) (Kol b) (Kol c) (Koln a) xb xc) => Op2' a b c (Koln a) (Kol b) (Kol c) (Koln a) (Tagged (TC tb cb) xb) xc where op2 f na (Tagged xb) = op2 f na xb
-- | nkk -> tkk
instance (Op2' a b c (Koln a) (Kol b) (Kol c) xa (Kol b) xc) => Op2' a b c (Koln a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Kol b) xc  where op2 f (Tagged xa) kb = op2 f xa kb
-- | nkk -> tnn
instance (Op2' a b c (Koln a) (Kol b) (Kol c) xa (Koln b) (Koln c)) => Op2' a b c (Koln a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where op2 f (Tagged xa) nb = op2 f xa nb
-- | nkk -> ttx
instance (Op2' a b c (Koln a) (Kol b) (Kol c) xa xb xc) => Op2' a b c (Koln a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) xc where op2 f (Tagged xa) (Tagged xb) = op2 f xa xb

-- | nkn -> kkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Kol b) (Koln c) (Kol a) (Kol b) (Koln c) where op2 f ka kb = f (fromKol ka) kb
-- | nkn -> knn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Kol b) (Koln c) (Kol a) (Koln b) (Koln c) where op2 f ka nb = bindKoln nb (f (fromKol ka))
-- | nkn -> ktn
instance (Op2' a b c (Koln a) (Kol b) (Koln c) (Kol a) xb (Koln c)) => Op2' a b c (Koln a) (Kol b) (Koln c) (Kol a) (Tagged (TC tb cb) xb) (Koln c) where op2 f ka (Tagged xb) = op2 f ka xb
-- | nkn -> nkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Kol b) (Koln c) (Koln a) (Kol b) (Koln c) where op2 f na kb = f na kb
-- | nkn -> nnn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Kol b) (Koln c) (Koln a) (Koln b) (Koln c) where op2 f na nb = bindKoln nb (f na)
-- | nkn -> ntn
instance (Op2' a b c (Koln a) (Kol b) (Koln c) (Koln a) xb (Koln c)) => Op2' a b c (Koln a) (Kol b) (Koln c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where op2 f na (Tagged xb) = op2 f na xb
-- | nkn -> tkn
instance (Op2' a b c (Koln a) (Kol b) (Koln c) xa (Kol b) (Koln c)) => Op2' a b c (Koln a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Kol b) (Koln c) where op2 f (Tagged xa) kb = op2 f xa kb
-- | nkn -> tnn
instance (Op2' a b c (Koln a) (Kol b) (Koln c) xa (Koln b) (Koln c)) => Op2' a b c (Koln a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where op2 f (Tagged xa) nb = op2 f xa nb
-- | nkn -> ttn
instance (Op2' a b c (Koln a) (Kol b) (Koln c) xa xb (Koln c)) => Op2' a b c (Koln a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Koln c) where op2 f (Tagged xa) (Tagged xb) = op2 f xa xb

-- | nnk -> kkk
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Koln b) (Kol c) (Kol a) (Kol b) (Kol c) where op2 f ka kb = f (fromKol ka) (fromKol kb)
-- | nnk -> knk
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Koln b) (Kol c) (Kol a) (Koln b) (Kol c) where op2 f ka nb = f (fromKol ka) nb
-- | nnk -> ktk
instance (Op2' a b c (Koln a) (Koln b) (Kol c) (Kol a) xb (Kol c)) => Op2' a b c (Koln a) (Koln b) (Kol c) (Kol a) (Tagged (TC tb cb) xb) (Kol c) where op2 f ka (Tagged xb) = op2 f ka xb
-- | nnk -> nkk
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Koln b) (Kol c) (Koln a) (Kol b) (Kol c) where op2 f na kb = f na (fromKol kb)
-- | nnk -> nnk
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Koln b) (Kol c) (Koln a) (Koln b) (Kol c) where op2 f na nb = f na nb
-- | nnk -> ntk
instance (Op2' a b c (Koln a) (Koln b) (Kol c) (Koln a) xb (Kol c)) => Op2' a b c (Koln a) (Koln b) (Kol c) (Koln a) (Tagged (TC tb cb) xb) (Kol c) where op2 f na (Tagged xb) = op2 f na xb
-- | nnk -> tkk
instance (Op2' a b c (Koln a) (Koln b) (Kol c) xa (Kol b) (Kol c)) => Op2' a b c (Koln a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Kol b) (Kol c)  where op2 f (Tagged xa) kb = op2 f xa kb
-- | nnk -> tnk
instance (Op2' a b c (Koln a) (Koln b) (Kol c) xa (Koln b) (Kol c)) => Op2' a b c (Koln a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Koln b) (Kol c) where op2 f (Tagged xa) nb = op2 f xa nb
-- | nnk -> ttk
instance (Op2' a b c (Koln a) (Koln b) (Kol c) xa xb (Kol c)) => Op2' a b c (Koln a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Kol c) where op2 f (Tagged xa) (Tagged xb) = op2 f xa xb

-- | nnn -> kkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Koln b) (Koln c) (Kol a) (Kol b) (Koln c) where op2 f ka kb = f (fromKol ka) (fromKol kb)
-- | nnn -> knn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Koln b) (Koln c) (Kol a) (Koln b) (Koln c) where op2 f ka nb = f (fromKol ka) nb
-- | nnn -> ktn
instance (Op2' a b c (Koln a) (Koln b) (Koln c) (Kol a) xb (Koln c)) => Op2' a b c (Koln a) (Koln b) (Koln c) (Kol a) (Tagged (TC tb cb) xb) (Koln c) where op2 f ka (Tagged xb) = op2 f ka xb
-- | nnn -> nkn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Koln b) (Koln c) (Koln a) (Kol b) (Koln c) where op2 f na kb = f na (fromKol kb)
-- | nnn -> nnn
instance (PgType a, PgType b, PgType c) => Op2' a b c (Koln a) (Koln b) (Koln c) (Koln a) (Koln b) (Koln c) where op2 f na nb = f na nb
-- | nnn -> ntn
instance (Op2' a b c (Koln a) (Koln b) (Koln c) (Koln a) xb (Koln c)) => Op2' a b c (Koln a) (Koln b) (Koln c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where op2 f na (Tagged xb) = op2 f na xb
-- | nnn -> tkn
instance (Op2' a b c (Koln a) (Koln b) (Koln c) xa (Kol b) (Koln c)) => Op2' a b c (Koln a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Kol b) (Koln c)  where op2 f (Tagged xa) kb = op2 f xa kb
-- | nnk -> tnn
instance (Op2' a b c (Koln a) (Koln b) (Koln c) xa (Koln b) (Koln c)) => Op2' a b c (Koln a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where op2 f (Tagged xa) nb = op2 f xa nb
-- | nnn -> ttn
instance (Op2' a b c (Koln a) (Koln b) (Koln c) xa xb (Koln c)) => Op2' a b c (Koln a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Koln c) where op2 f (Tagged xa) (Tagged xb) = op2 f xa xb

