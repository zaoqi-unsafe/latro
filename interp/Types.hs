module Types where

import AlphaConvert
import Common
import Control.Error.Util (hoistEither)
import Control.Monad.Except
import Control.Monad.State
import Data.Either.Utils (maybeToEither)
import Data.List
import qualified Data.Map as Map
import Errors
import Semant
import Text.Printf (printf)


data TCEnv = TCEnv
  { typeEnv :: Map.Map UniqId TyCon
  , varEnv :: Map.Map UniqId Ty
  , curModule :: TyCon
  , alphaEnv :: AlphaEnv
  }
  deriving (Eq)

mtEnv :: AlphaEnv -> TCEnv
mtEnv alphaEnv =
  TCEnv
    { typeEnv = Map.empty
    , varEnv = Map.empty
    , curModule = TyConModule [] []
    , alphaEnv = alphaEnv
    }

type Checked a = ExceptT Err (State TCEnv) a


pushNewModuleContext :: [TyVarId] -> Checked TCEnv
pushNewModuleContext tyParamIds = do
  oldEnv <- get
  modify (\tcEnv -> tcEnv { curModule = TyConModule tyParamIds [] })
  return oldEnv


restoreEnv :: TCEnv -> Checked ()
restoreEnv tcEnv = put tcEnv


-- Convenience methods for manipulating the environment
addModuleTyBinding :: TyCon -> UniqId -> TyCon -> TyCon
addModuleTyBinding (TyConModule tyParamIds bindings) id tyCon =
  TyConModule tyParamIds ((ModuleBindingTyCon id tyCon) : bindings)


addModuleVarBinding :: TyCon -> UniqId -> Ty -> TyCon
addModuleVarBinding (TyConModule tyParamIds bindings) id ty =
  TyConModule tyParamIds ((ModuleBindingTy id ty) : bindings)


putTyBinding :: UniqId -> TyCon -> Checked ()
putTyBinding id ty = do
  modify (\tcEnv -> tcEnv { typeEnv = Map.insert id ty (typeEnv tcEnv)
                          , curModule = addModuleTyBinding (curModule tcEnv) id ty
                          })


putVarBinding :: UniqId -> Ty -> Checked ()
putVarBinding id ty = do
  modify (\tcEnv -> tcEnv { varEnv = Map.insert id ty (varEnv tcEnv)
                          , curModule = addModuleVarBinding (curModule tcEnv) id ty
                          })


mtApp :: TyCon -> Ty
mtApp tyCon = TyApp tyCon []


-- Shortcuts for primitive types
tyInt :: Ty
tyInt = mtApp TyConInt

tyBool :: Ty
tyBool = mtApp TyConBool

tyStr :: Ty
tyStr = mtApp TyConString

tyUnit :: Ty
tyUnit = mtApp TyConUnit


freshId :: Checked UniqId
freshId = do
  alphaEnv <- gets alphaEnv
  let (uniqId, alphaEnv') = fresh "t" alphaEnv
  modify (\tcEnv -> tcEnv { alphaEnv = alphaEnv' })
  return uniqId


lookupTy :: UniqId -> Checked TyCon
lookupTy id = do
  tyConEnv <- gets typeEnv
  hoistEither $ maybeToEither (ErrUnboundUniqIdentifier id)
              $ Map.lookup id tyConEnv


lookupVar :: UniqId -> Checked Ty
lookupVar id = do
  varEnv <- gets varEnv
  hoistEither $ maybeToEither (ErrUnboundUniqIdentifier id)
              $ Map.lookup id varEnv


unify :: Ty -> Ty -> Checked Ty
unify a@(TyApp tyconA tyArgsA) b@(TyApp tyconB tyArgsB) =
  if tyconA == tyconB
  then do mapM_ (uncurry unify) $ zip tyArgsA tyArgsB
          return a
  else throwError $ ErrCantUnify a b

unify TyAny b = return b


unifyAll :: [Ty] -> Checked Ty
unifyAll [] = freshId >>= return . TyVar
unifyAll [ty] = return ty
unifyAll (ta:tb:tys) = do
  ty' <- unify ta tb
  unifyAll (ty':tys)


tcArith :: Exp UniqId -> Exp UniqId -> Checked Ty
tcArith a b = do
  tc a >>= unify tyInt
  tc b >>= unify tyInt
  return tyInt


tcTy :: SynTy UniqId -> Checked Ty
tcTy SynTyInt = return tyInt
tcTy SynTyBool = return tyBool
tcTy SynTyString = return tyStr
tcTy SynTyUnit = return tyUnit


tcTyDec :: TypeDec UniqId -> Checked TyCon
tcTyDec (TypeDecTy id SynTyInt) = return TyConInt
tcTyDec (TypeDecTy id (SynTyStruct fields)) =
  let (fieldNames, fieldSynTys) = unzip fields
  in do
    fieldTys <- mapM tcTy fieldSynTys
    return $ TyConTyFun [] $ TyApp (TyConStruct fieldNames) fieldTys


-- The language grammar only permits the expression
-- to be a MemberAccessExp, which is either an application
-- followed by a '. ID', or an atom expression.
-- The reason this must be an expression (and not a qualified identifier)
-- is that we can access some type defined on an inline module, for example.
-- module { type t = ...; }.t { ... };
--
-- Which is odd, but is permitted (at least at the syntactic level).
-- The question is (1) why anyone would want to do that, and (2)
-- how (or if) we need to refer to the type of this object elsewhere.
-- We are allowing a value to escape "further" than its corresponding type.
tcTyconExp :: Exp UniqId -> Checked TyCon
tcTyconExp (ExpRef id) = lookupTy id


tcStructFields :: [(UniqId, Ty)] -> [(UniqId, Exp UniqId)] -> Checked Ty
tcStructFields _ [] = return tyUnit
tcStructFields tyFields ((fieldId, fieldExp):fieldInitExps) =
  let maybeField = find (flip ((==) . fst) fieldId) tyFields
  in
    case maybeField of
      Nothing -> throwError $ ErrUndefinedMember fieldId
      Just (matchedFieldId, matchedTy) -> do
        initExpTy <- tc fieldExp
        unify matchedTy initExpTy
        tcStructFields tyFields fieldInitExps


tcPatExp :: PatExp UniqId -> Checked Ty
tcPatExp (PatExpNumLiteral _) = return tyInt
tcPatExp (PatExpBoolLiteral _) = return tyBool
tcPatExp (PatExpTuple es) = do
  eTys <- mapM tcPatExp es
  return $ TyApp TyConTuple eTys

tcPatExp (PatExpAdt _ _) = throwError $ ErrNotImplemented "tcPatExp for ADT's"
tcPatExp (PatExpList es) = do
  eTys <- mapM tcPatExp es
  unifyAll eTys

tcPatExp (PatExpListCons eHd eTl) = do
  hdTy <- tcPatExp eHd
  tlTy <- tcPatExp eTl
  case tlTy of
    TyApp TyConList [elemTy] ->
      unify elemTy hdTy
    _ -> unify (TyApp TyConList [hdTy]) tlTy

tcPatExp (PatExpId id) = return TyAny
tcPatExp PatExpWildcard = return TyAny


addBindingsForPat :: PatExp UniqId -> Ty -> Checked ()
addBindingsForPat (PatExpTuple patEs) (TyApp TyConTuple tyArgs) =
  let componentEsTys = zip patEs tyArgs
  in do mapM_ (uncurry addBindingsForPat) componentEsTys

addBindingsForPat (PatExpAdt _ _) _ = throwError $ ErrNotImplemented "addBindingsForPat for ADT's"

addBindingsForPat (PatExpList elemEs) (TyApp TyConList [tyArg]) =
  let addBindingsForPatWithTy = (flip addBindingsForPat) tyArg
  in do mapM_ addBindingsForPatWithTy elemEs

addBindingsForPat (PatExpListCons hdE tlE) _ = throwError $ ErrNotImplemented "addBindingsForPat for list cons"

addBindingsForPat (PatExpId id) ty = putVarBinding id ty
addBindingsForPat _ _ = return ()


tc :: Exp UniqId -> Checked Ty
tc ExpUnit = return $ mtApp TyConUnit
tc (ExpRef id) = lookupVar id
tc (ExpString _) = return $ mtApp TyConString
tc (ExpBool _) = return $ mtApp TyConBool
tc (ExpNum _) = return $ mtApp TyConInt

tc (ExpAdd a b) = tcArith a b
tc (ExpSub a b) = tcArith a b
tc (ExpDiv a b) = tcArith a b
tc (ExpMul a b) = tcArith a b

tc (ExpCons headE listE) = do
  tyListE <- tc listE
  tyHeadE <- tc headE
  case tyListE of
    TyApp TyConList _ -> unify tyListE $ TyApp TyConList [tyHeadE]
    _ -> unify (TyApp TyConList [tyHeadE]) tyListE

tc (ExpNot e) = do
  te <- tc e >>= unify tyBool
  return tyBool

tc (ExpMemberAccess e id) = do
  eTy <- tc e
  case eTy of
    TyApp (TyConModule tyParamIds bindings) [] ->
      let match = find (\binding -> case binding of
                                      (ModuleBindingTy name _) -> name == id
                                      _ -> False
                       )
                       bindings
      in do
        (ModuleBindingTy _ ty) <- hoistEither $ maybeToEither (ErrUnboundUniqIdentifier id)
                                              match
        return ty
    _ -> throwError $ ErrNotImplemented "Failed member access"

tc (ExpModule paramIds es) = do
  oldEnv <- pushNewModuleContext paramIds
  mapM_ tc es
  moduleTy <- gets curModule
  restoreEnv oldEnv
  let tyApp = TyApp moduleTy $ map TyVar paramIds
  case paramIds of
    [] -> return tyApp
    _ -> return $ TyPoly paramIds tyApp

tc (ExpAssign patE rhe) = do
  rheTy <- tc rhe
  patTy <- tcPatExp patE
  unify patTy rheTy
  addBindingsForPat patE rheTy
  return tyUnit

tc (ExpFun _ _) = throwError $ ErrNotImplemented "tc"

tc (ExpList []) = do
  newTyVar <- freshId
  return $ TyPoly [newTyVar] $ TyApp TyConList [TyVar newTyVar]

tc (ExpList es) = do
  tys <- mapM tc es
  elemTy <- unifyAll tys
  return $ TyApp TyConList [elemTy]

tc (ExpSwitch e clauses) = throwError $ ErrNotImplemented "tc"

tc (ExpTuple es) = do
  tys <- mapM tc es
  return $ TyApp TyConTuple tys

tc (ExpMakeAdt synTy i es) = throwError $ ErrNotImplemented "tc"

tc (ExpStruct strSynTyE fieldInitEs) = do
  structTyCon <- tcTyconExp strSynTyE
  case structTyCon of
    TyConTyFun [] structTyConApp@(TyApp (TyConStruct fids) ftys) -> do
      tcStructFields (zip fids ftys) fieldInitEs
      return structTyConApp
    _ -> throwError $ ErrInvalidStructType structTyCon

tc (ExpIfElse testE thenEs elseEs) = do
  testTy <- tc testE >>= unify tyBool
  thenTy <- tcEs thenEs
  elseTy <- tcEs elseEs
  unify thenTy elseTy

tc (ExpTypeDec tyDec) =
  let id = getTypeDecId tyDec
  in do
    tycon <- tcTyDec tyDec
    putTyBinding id tycon
    return tyUnit

tc e = throwError $ ErrInterpFailure $ printf "In function tc: %s" $ show e


tcEs :: [Exp UniqId] -> Checked Ty
tcEs [] = return $ mtApp TyConUnit
tcEs es = do
  tys <- mapM tc es
  return $ last tys


typeCheck :: CompUnit UniqId -> AlphaEnv -> Either Err (Ty, AlphaEnv)
typeCheck (CompUnit es) aEnv = do
  (tyResult, tcEnv) <- return $ runState (runExceptT $ tcEs es) $ mtEnv aEnv
  ty <- tyResult
  return (ty, alphaEnv tcEnv)
