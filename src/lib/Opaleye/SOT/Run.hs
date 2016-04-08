{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Opaleye.SOT.Run
  ( -- * Connection
    Conn
  , Conn'
  , unConn
  , connect
  , connect'
  , close
    -- * Permissions
  , Perm(..)
  , Allow
  , Forbid
  , DropPerm
  , withoutPerm
    -- * Transaction
  , withTransaction
  , IsolationLevel(..)
  , ReadWriteMode(..)
  , TransactionPerms
  , withSavepoint
    -- * Query
  , runQueryMany
  , runQuery1
  , runQueryHead
    -- * Insert
  , runInsertMany
  , runInsert1
    -- ** Returning
  , runInsertReturningMany
  , runInsertReturning1
  , runInsertReturningHead
    -- * Update
  , runUpdate
  , runUpdateTabla
  , runUpdateTabla'
    -- * Delete
  , runDelete
  , runDeleteTabla
  , runDeleteTabla'
    -- * Exception
  , ErrTooManyRows(..)
  , ErrNoRows(..)
  ) where

import           Control.Monad.IO.Class
import qualified Control.Monad.Catch as Cx
import           Data.Int (Int64)
import qualified Data.Profunctor.Product.Default as PP
import           Data.Typeable (Typeable)
import qualified Data.ByteString.Char8 as B8
import qualified Database.PostgreSQL.Simple as Pg
import qualified Database.PostgreSQL.Simple.Transaction as Pg
import           GHC.Exts (Constraint)
import qualified Opaleye as O
import qualified Opaleye.Internal.RunQuery as OI

import           Opaleye.SOT.Internal

--------------------------------------------------------------------------------

-- | 'Perm' is only used at the type level to index 'Conn'.
data Perm
  = Fetch
    -- ^ Allow fetching a value from the database
    -- (i.e., @SELECT@, @... RETURNING@).
  | Update
    -- ^ Allow updating data in the database (i.e., @UPDATE@)
  | Insert
    -- ^ Allow inserting new data to the database (i.e., @INSERT@)
  | Delete
    -- ^ Allow deleting data from the database (i.e., @DELETE@)
  | Transact
    -- ^ Allow starting and finishing transactions (i.e., @BEGIN@,
    -- @COMMIT@, @ROLLBACK@).
  | Savepoint
    -- ^ Allow creating transactions savepoints and rolling back to them.
  deriving (Eq, Ord, Show)

-- | @'Conn' perms@ is just a wrapper around @postgresql-simple@'s
-- 'Pg.Connection' that carries, in @perms@, type-level information about which
-- kind of operations can be performed on this connection.
--
-- The problem with 'Pg.Connection' is that it allows us to perform any operation
-- on it (reading, inserting, commiting a transaction, etc.), but sometimes we
-- would prefer to limit the type of operations this connection might support.
-- For example, we might want to forbid transactions from being commited because
-- they are being handled by someone else. @'Conn' perms@ carries type-level
-- information about this.
--
-- Note that 'Conn' is not thread-safe, you are encouraged to maintain a
-- multithreaded pool of 'Conn' instead. See "Data.Pool" from the @ex-pool@
-- package.
newtype Conn (perms :: [Perm]) = Conn Pg.Connection

unConn :: Conn ps -> Pg.Connection
unConn (Conn conn) = conn

-- | A type synonym for a 'Conn' with all the permissions enabled.
type Conn' = Conn ['Fetch, 'Insert, 'Update, 'Delete, 'Transact]

-- | @'Allow' p ps@ ensures that @p@ is present in @ps@.
--
-- The kind of @p@ can be 'Perm' or @['Perm']@.
type Allow (p :: k) (ps :: [Perm]) = Allow' p ps

type family Allow' (p :: k) (ps :: [Perm]) :: Constraint where
  Allow' ('[] :: [Perm]) ps = ()
  Allow' ((p ': ps) :: [Perm]) qs = (Allow' p qs, Allow' ps qs)
  Allow' (p :: Perm) '[] =
     "Opaleye.SOT.Run.Allow'" ~
     "Allow': The required permission is forbidden"
  Allow' (p :: Perm) (p ': ps) = ()
  Allow' (p :: Perm) (q ': ps) = Allow' p ps

-- | @'Forbid'' p ps@ ensures that @p@ is not present in @ps@.
--
-- The kind of @p@ can be 'Perm' or @['Perm']@.
type Forbid (p :: k) (ps :: [Perm]) = Forbid' p ps

type family Forbid' (p :: k) (ps :: [Perm]) :: Constraint where
  Forbid' ('[] :: [Perm]) ps = ()
  Forbid' ((p ': ps) :: [Perm]) qs = (Forbid' p qs, Forbid' ps qs)
  Forbid' (p :: Perm) (p ': ps) =
     "Opaleye.SOT.Run.Forbid'" ~
     "Forbid': The forbidden permission is allowed"
  Forbid' (p :: Perm) (q ': ps) = Forbid' p ps
  Forbid' (p :: Perm) '[] = ()

-- | @'DropPerm' p ps@ removes @p@ from @ps@ if present.
--
-- The kind of @p@ can be 'Perm' or @['Perm']@.
type DropPerm (p :: k) (ps :: [Perm]) = DropPerm' p ps

type family DropPerm' (p :: k) (ps :: [Perm]) :: [Perm] where
  DropPerm' ('[] :: [Perm]) ps = ps
  DropPerm' ((p ': ps) :: [Perm]) qs = DropPerm' p (DropPerm' ps qs)
  DropPerm' (p :: Perm) (p ': ps) = DropPerm' p ps
  DropPerm' (p :: Perm) (q ': ps) = q ': DropPerm' p ps
  DropPerm' (p :: Perm) '[] = '[]

-- | Drop a permission from the connection.
withoutPerm
  :: (MonadIO m, Cx.MonadMask m, Allow p ps, ps' ~ DropPerm p ps)
  => proxy (p :: k)
  -- ^ @k@ may be 'Perm' or @['Perm']@.
  -> Conn ps
  -> (Conn ps' -> m a)
  -- ^ The usage of @'Conn' ps@ is undefined within this function,
  -- and @'Conn' ps'@ mustn't escape the scope of this function.
  -> m a
withoutPerm _ (Conn conn) f = f (Conn conn)

-- | Return a new connection.
connect :: MonadIO m => Pg.ConnectInfo -> m Conn'
connect = connect' . Pg.postgreSQLConnectionString

-- | Like 'connect', except it takes a @libpq@ connection string instead of a
-- 'Pg.ConnectInfo'.
connect' :: MonadIO m => B8.ByteString -> m Conn'
connect' = liftIO . fmap Conn . Pg.connectPostgreSQL

-- | Warning: Using the given @'Conn' ps@ after calling 'close' will result in
-- a runtime exception.
close :: (MonadIO m, Cx.MonadMask m) => Conn ps -> m ()
close (Conn conn) = liftIO (Pg.close conn)

--------------------------------------------------------------------------------

-- | Like 'Pg.IsolationLevel', but without support for default values.
data IsolationLevel = ReadCommitted | RepeatableRead | Serializable
  deriving (Eq, Ord, Show, Enum, Bounded)

pgIsolationLevel :: IsolationLevel -> Pg.IsolationLevel
pgIsolationLevel ReadCommitted = Pg.ReadCommitted
pgIsolationLevel RepeatableRead = Pg.RepeatableRead
pgIsolationLevel Serializable = Pg.Serializable

---

-- | Internal. Index to 'ReadWriteMode'
data RWM = RO | RW

-- | Like 'Pg.ReadWriteMode', but without support for default values.
data ReadWriteMode :: RWM -> * where
  ReadWrite :: ReadWriteMode 'RW
  ReadOnly  :: ReadWriteMode 'RO

pgReadWriteMode :: ReadWriteMode a -> Pg.ReadWriteMode
pgReadWriteMode ReadWrite = Pg.ReadWrite
pgReadWriteMode ReadOnly = Pg.ReadOnly

-- | Permissions for a transaction initiated on @'Conn' ps@ with 'ReadWriteMode'
-- @rwm@.
type family TransactionPerms (rwm :: RWM) (ps :: [Perm]) :: [Perm] where
  TransactionPerms 'RW ps = DropPerm 'Transact ps
  TransactionPerms 'RO ps
    = DropPerm ['Transact, 'Savepoint, 'Insert, 'Update, 'Delete] ps

withTransaction
  :: (MonadIO m, Cx.MonadMask m, Allow 'Transact ps,
      ps' ~ TransactionPerms rwm ps)
  => Conn ps
  -> IsolationLevel
  -> ReadWriteMode rwm
  -> (Conn ps' -> m (Either a b))
  -- ^ The usage of @'Conn' ps@ is undefined within this function,
  -- and @'Conn' ps'@ mustn't escape the scope of this function.
  -- A 'Left' return value rollbacks the transaction, 'Right' commits it.
  -> m (Either a b)
withTransaction (Conn conn) il rwm f = Cx.mask $ \restore -> do
  let tmode = Pg.TransactionMode (pgIsolationLevel il) (pgReadWriteMode rwm)
  liftIO $ Pg.beginMode tmode conn
  eab <- restore (f (Conn conn)) `Cx.onException` liftIO (Pg.rollback conn)
  eab <$ liftIO (either (const Pg.rollback) (const Pg.commit) eab conn)

-- | You can use this function within `withTransaction` as a sort of nested
-- transaction.
withSavepoint
  :: (MonadIO m, Cx.MonadMask m, Allow 'Savepoint ps)
  => Conn ps
  -> (Conn ps -> m (Either a b))
  -- ^ A 'Left' return value rollbacks the savepoint, 'Right' keeps it.
  -> m (Either a b)
withSavepoint (Conn conn) f = Cx.mask $ \restore -> do
  sp <- liftIO $ Pg.newSavepoint conn
  let abort = liftIO $ Pg.rollbackToAndReleaseSavepoint conn sp
  eab <- restore (f (Conn conn)) `Cx.onException` abort
  eab <$ either (const abort) (const (return ())) eab

--------------------------------------------------------------------------------

-- | Query and fetch zero or more resulting rows.
runQueryMany
 :: (MonadIO m, Cx.MonadThrow m, PP.Default O.QueryRunner v hs, Allow 'Fetch ps)
 => Conn ps -> (hs -> Either Cx.SomeException r) -> O.Query v -> m [r] -- ^
runQueryMany (Conn conn) f q =
  liftIO $ traverse (either Cx.throwM return . f) =<< O.runQuery conn q

-- | Query and fetch zero or one resulting row.
--
-- Throws 'ErrTooManyRows' if there is more than one row in the result.
runQuery1
 :: forall v hs r m ps
  . (MonadIO m, Cx.MonadThrow m, PP.Default O.QueryRunner v hs, Allow 'Fetch ps)
 => Conn ps -> (hs -> Either Cx.SomeException r) -> O.Query v
 -> m (Maybe r) -- ^
runQuery1 pc f q = do
    rs <- runQueryMany pc f q
    case rs of
      [r] -> return (Just r)
      []  -> return Nothing
      _   -> Cx.throwM $ ErrTooManyRows (length rs) sql
  where
    sql = let OI.QueryRunner u _ _ = PP.def :: OI.QueryRunner v hs
          in  O.showSqlForPostgresExplicit u q

-- | Query and fetch one resulting row.
--
-- Throws 'ErrTooManyRows' if there is more than one row in the result, and
-- 'ErrNoRows' if there is no row in the result.
runQueryHead
 :: forall v hs r m ps
  . (MonadIO m, Cx.MonadThrow m, PP.Default O.QueryRunner v hs, Allow 'Fetch ps)
 => Conn ps -> (hs -> Either Cx.SomeException r) -> O.Query v
 -> m r -- ^
runQueryHead pc f q = do
    rs <- runQueryMany pc f q
    case rs of
      [r] -> return r
      []  -> Cx.throwM $ ErrNoRows sql
      _   -> Cx.throwM $ ErrTooManyRows (length rs) sql
  where
    sql = let OI.QueryRunner u _ _ = PP.def :: OI.QueryRunner v hs
          in  O.showSqlForPostgresExplicit u q


--------------------------------------------------------------------------------

-- | Insert zero or more rows.
runInsertMany
  :: (MonadIO m, Allow 'Insert ps)
  => Conn ps -> O.Table w v -> [w] -> m Int64 -- ^
runInsertMany (Conn conn) t ws = liftIO $ O.runInsertMany conn t ws

-- | Insert one row.
runInsert1
  :: (MonadIO m, Allow 'Insert ps)
  => Conn ps -> O.Table w v -> w -> m Int64 -- ^
runInsert1 pc t w = runInsertMany pc t [w]

--------------------------------------------------------------------------------

-- | Insert zero or more rows, returning data from the rows actually inserted.
runInsertReturningMany
  :: (MonadIO m, PP.Default O.QueryRunner v hs, Allow ['Insert, 'Fetch] ps)
  => Conn ps -> (hs -> Either Cx.SomeException r) -> O.Table w v -> w
  -> m [r] -- ^
runInsertReturningMany (Conn conn) f t w = liftIO $
   traverse (either Cx.throwM return . f) =<< O.runInsertReturning conn t w id

-- | Insert 1 row, returning data from the zero or one rows actually inserted.
--
-- Throws 'ErrTooManyRows' if there is more than one row in the result.
runInsertReturning1
  :: forall m v hs w r ps
   . (MonadIO m, Cx.MonadThrow m, PP.Default O.QueryRunner v hs,
      Allow ['Insert, 'Fetch] ps)
  => Conn ps -> (hs -> Either Cx.SomeException r) -> O.Table w v -> w
  -> m (Maybe r) -- ^
runInsertReturning1 pc f t w = do
   rs <- runInsertReturningMany pc f t w
   case rs of
     [r] -> return (Just r)
     []  -> return Nothing
     _   -> Cx.throwM $ ErrTooManyRows (length rs) sql
  where
    sql = let OI.QueryRunner u _ _ = PP.def :: OI.QueryRunner v hs
          in  O.arrangeInsertReturningSql u t w id

-- | Insert 1 row, returning data from the one row actually inserted.
--
-- Throws 'ErrTooManyRows' if there is more than one row in the result, and
-- 'ErrNoRows' if there is no row in the result.
runInsertReturningHead
  :: forall m hs w v r ps
   . (MonadIO m, Cx.MonadThrow m, PP.Default O.QueryRunner v hs,
      Allow ['Insert, 'Fetch] ps)
  => Conn ps -> (hs -> Either Cx.SomeException r) -> O.Table w v -> w
  -> m r -- ^
runInsertReturningHead pc f t w = do
   rs <- runInsertReturningMany pc f t w
   case rs of
     [r] -> return r
     []  -> Cx.throwM $ ErrNoRows sql
     _   -> Cx.throwM $ ErrTooManyRows (length rs) sql
  where
    sql = let OI.QueryRunner u _ _ = PP.def :: OI.QueryRunner v hs
          in  O.arrangeInsertReturningSql u t w id

--------------------------------------------------------------------------------

-- | Like Opaleye's 'O.runUpdate', but the predicate is expected to
-- return a @('GetKol' w 'O.PGBool')@.
--
-- It is recommended that you use 'runUpdateTabla' if you are trying to update
-- a table that is an instance of 'Tabla'. The result is the same, but
-- this function might be less convenient to use.
runUpdate
  :: (MonadIO m, GetKol gkb O.PGBool, Allow 'Update ps)
  => Conn ps -> O.Table w r -> (r -> w) -> (r -> gkb) -> m Int64 -- ^
runUpdate (Conn conn) t upd fil =
  liftIO $ O.runUpdate conn t upd (unKol . getKol . fil)

-- | Like 'runUpdate', but specifically designed to work well with 'Tabla'.
runUpdateTabla'
  :: forall t m gkb ps
   . (Tabla t, MonadIO m, GetKol gkb O.PGBool, Allow 'Update ps)
  => Conn ps
  -> (PgW t -> PgW t) -- ^ Upgrade current values to new values.
  -> (PgR t -> gkb)   -- ^ Whether a row should be updated.
  -> m Int64          -- ^ Number of updated rows.
runUpdateTabla' pc = runUpdateTabla pc (T::T t)

-- | Like 'runUpdateTabla'', but takes @t@ explicitely for the times when
-- it can't be inferred.
runUpdateTabla
  :: (Tabla t, MonadIO m, GetKol gkb O.PGBool, Allow 'Update ps)
  => Conn ps -> T t -> (PgW t -> PgW t) -> (PgR t -> gkb) -> m Int64 -- ^
runUpdateTabla pc t upd = runUpdate pc (table t) (upd . update')

--------------------------------------------------------------------------------

-- | Like Opaleye's 'O.runDelete', but the predicate is expected to return
-- a @('GetKol' w 'O.PGBool')@.
--
-- It is recommended that you use 'runDeleteTabla' if you are trying to update
-- a table that is an instance of 'Tabla', the result is the same, but
-- this function might be less convenient to use.
runDelete
  :: (MonadIO m, GetKol gkb O.PGBool, Allow 'Delete ps)
  => Conn ps -> O.Table w r -> (r -> gkb) -> m Int64 -- ^
runDelete (Conn conn) t fil =
  liftIO $ O.runDelete conn t (unKol . getKol . fil)

-- | Like 'runDelete', but specifically designed to work well with 'Tabla'.
runDeleteTabla'
  :: forall t m gkb ps
   . (Tabla t, MonadIO m, GetKol gkb O.PGBool, Allow 'Delete ps)
  => Conn ps
  -> (PgR t -> gkb) -- ^ Whether a row should be deleted.
  -> m Int64
runDeleteTabla' pc = runDeleteTabla pc (T::T t)

-- | Like 'runDeleteTabla'', but takes @t@ explicitely for the times when it
-- can't be inferred.
runDeleteTabla
  :: (Tabla t, MonadIO m, GetKol gkb O.PGBool, Allow 'Delete ps)
  => Conn ps
  -> T t
  -> (PgR t -> gkb) -- ^ Whether a row should be deleted.
  -> m Int64
runDeleteTabla pc t = runDelete pc (table t)

--------------------------------------------------------------------------------
-- Exceptions

-- | Exception thrown when indicating more rows than expected are available.
data ErrTooManyRows = ErrTooManyRows Int String -- ^ Number of rows, SQL string
  deriving (Typeable, Show)
instance Cx.Exception ErrTooManyRows

-- | Exception thrown when indicating no rows are available.
data ErrNoRows = ErrNoRows String -- ^ SQL string
  deriving (Typeable, Show)
instance Cx.Exception ErrNoRows
