{-# LANGUAGE FlexibleContexts #-}
module Types where

import AlphaConvert
import Common
import Control.Error.Util (hoistEither)
import Control.Monad.Except
import Control.Monad.ListM (sortByM)
import Control.Monad.State.Strict
import Data.Either.Utils (maybeToEither)
import Data.List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Set as Set
import Debug.Trace (trace, traceM, traceShowId, traceShowM)
import Errors
import Semant
import Semant.Display
import Sexpable (showSexp)
import Text.Printf (printf)


reportErrorAt a = reportPosOnFail a "Types"
withFailPos' p = withFailPos p "Types"


traceIt :: Show a => a -> a
traceIt v = trace (show v) v


type VarEnv = Map.Map UniqId Ty


data TCEnv = TCEnv
  { curModule :: TCModule
  , varEnv :: VarEnv
  , alphaEnv :: AlphaEnv
  , polyEnv :: Map.Map UniqId Ty
  , metaEnv :: Map.Map UniqId Ty
  , scopeLevel :: Int
  }
  deriving (Eq)


mtTCEnv :: AlphaEnv -> TCEnv
mtTCEnv alphaEnv =
  TCEnv
    { curModule   = mtTCModule
    , varEnv      = Map.empty
    , alphaEnv    = alphaEnv
    , polyEnv     = Map.empty
    , metaEnv     = Map.empty
    , scopeLevel  = 0
    }


inTopLevelScope :: Checked Bool
inTopLevelScope = do
  depth <- gets scopeLevel
  return $ depth == 0

showHum :: Show v => Map.Map UniqId v -> String
showHum =
  Map.foldlWithKey
    (\str key val -> str ++ "\n" ++ show key ++ " --> " ++ show val)
    ""

type Checked a = ExceptT Err (State TCEnv) a


-- Debugging
traceMetaEnv :: Checked ()
traceMetaEnv = do
  traceM "META ENV:  "
  metaEnv <- gets metaEnv
  traceM $ showHum metaEnv

traceVarEnv :: Checked ()
traceVarEnv = do
  traceM "VAR ENV:  "
  varEnv <- gets varEnv
  traceM $ showHum varEnv

tracePolyEnv :: Checked ()
tracePolyEnv = do
  traceM "POLY Env:  "
  polyEnv <- gets polyEnv
  traceM $ showHum polyEnv

traceFieldIndices :: Checked ()
traceFieldIndices = do
  traceM "Field indices:  "
  curMod <- gets curModule
  traceM $ showHum $ fieldIndices curMod


-- Convenience methods for manipulating the environment
newContextWith :: (TCEnv -> TCEnv) -> Checked TCEnv
newContextWith fupdate = do
  oldEnv <- get
  modify fupdate
  return oldEnv


pushNewModuleContext :: Checked TCEnv
pushNewModuleContext = do
  depth <- gets scopeLevel
  curMod <- if depth == 0
            then return mtTCModule
            else gets curModule
  let mod = mtTCModule { closedVars     = vars curMod
                       , closedTys      = types curMod
                       , closedPatFuns  = patFuns curMod
                       }
  newContextWith (\tcEnv -> tcEnv { curModule = mod
                                  , scopeLevel = depth + 1
                                  })


-- A new var env needs to close over all
-- bindings in the existing env, so
-- the update function is the identity function
markVarEnv :: Checked VarEnv
markVarEnv =
  gets varEnv


restoreVarEnv :: VarEnv -> Checked ()
restoreVarEnv varEnv =
  modify (\tcEnv -> tcEnv { varEnv = varEnv })


restoreContext :: TCEnv -> Checked ()
restoreContext = put


putModuleVarBinding :: UniqId -> Ty -> Checked ()
putModuleVarBinding id ty =
  modify (\tcEnv -> tcEnv { curModule = addModuleVar (curModule tcEnv) id ty })


exportTy :: UniqId -> TyCon -> Checked ()
exportTy id tyCon =
  modify (\tcEnv -> tcEnv { curModule = addModuleTy (curModule tcEnv) id tyCon })


bindVar :: UniqId -> Ty -> Checked ()
bindVar id ty = do
  isTopLevel <- inTopLevelScope
  modify (\tcEnv -> tcEnv { varEnv = Map.insert id ty (varEnv tcEnv) })
  unless isTopLevel $ putModuleVarBinding id ty


bindVarIfNotBound :: UniqId -> Ty -> Checked ()
bindVarIfNotBound id ty = do
  isTopLevel <- inTopLevelScope
  modify (\tcEnv -> tcEnv { varEnv = Map.insertWith (\new old -> old) id ty (varEnv tcEnv) })
  unless isTopLevel $ putModuleVarBinding id ty


putPatBinding :: UniqId -> Ty -> Checked ()
putPatBinding id ty =
  modify (\tcEnv -> tcEnv { curModule = addModulePat (curModule tcEnv) id ty })


bindPoly :: UniqId -> Ty -> Checked ()
bindPoly id ty =
  modify (\tcEnv -> tcEnv { polyEnv = Map.insert id ty (polyEnv tcEnv) })


bindMeta :: UniqId -> Ty -> Checked ()
bindMeta id (TyMeta otherMetaId) = do
  newMeta <- freshMeta
  modify (\tcEnv ->
            let env = metaEnv tcEnv
                metaEnv' = Map.insert id newMeta env
                metaEnv'' = Map.insert otherMetaId newMeta metaEnv'
            in
              tcEnv { metaEnv = metaEnv'' })

bindMeta id ty =
  modify (\tcEnv -> tcEnv { metaEnv = Map.insert id ty (metaEnv tcEnv) })


bindFieldIndex :: UniqId -> Int -> Checked ()
bindFieldIndex id ind = do
  curMod <- gets curModule
  let indices = fieldIndices curMod
  modify (\tcEnv -> tcEnv { curModule = curMod { fieldIndices = Map.insert id ind indices } })


mtApp :: TyCon -> Ty
mtApp tyCon = TyApp tyCon []


-- Shortcuts for primitive types
tyInt :: Ty
tyInt = mtApp TyConInt

tyBool :: Ty
tyBool = mtApp TyConBool


tyStr :: Ty
tyStr = TyApp TyConList [tyChar]

tyChar :: Ty
tyChar = mtApp TyConChar

tyUnit :: Ty
tyUnit = mtApp TyConUnit


makeFresh :: RawId -> Checked UniqId
makeFresh raw = do
  alphaEnv <- gets alphaEnv
  let (uniqId, alphaEnv') = fresh raw alphaEnv
  modify (\tcEnv -> tcEnv { alphaEnv = alphaEnv' })
  return uniqId


freshId :: Checked UniqId
freshId = makeFresh "t"


freshMeta :: Checked Ty
freshMeta = do
  (UniqId n raw) <- makeFresh "meta"
  return $ TyMeta $ UniqId n $ printf "meta@%i" n


lookupOrFail :: Map.Map UniqId a -> UniqId -> Checked a
lookupOrFail table id =
  let result = Map.lookup id table
  in hoistEither $ maybeToEither (ErrUnboundUniqIdentifier id) result


envLookup :: (TCEnv -> Map.Map UniqId a) -> UniqId -> Checked (Maybe a)
envLookup getTable id = do
  table <- gets getTable
  return $ Map.lookup id table


envLookupOrFail :: (TCEnv -> Map.Map UniqId a) -> UniqId -> Checked a
envLookupOrFail getTable id = do
  result <- envLookup getTable id
  hoistEither $ maybeToEither (ErrUnboundUniqIdentifier id) result


lookupFieldIndex :: UniqAst QualifiedId -> UniqId -> Checked Int
lookupFieldIndex tyId id = do
  mod <- case tyId of
          Path _ qid _ -> do modTy <- lookupVarQual qid `reportErrorAt` nodeData qid
                             case modTy of
                               TyApp (TyConModule _ mod) _ -> return mod
                               _ -> throwError (ErrInvalidModulePath qid) `reportErrorAt` nodeData qid
          _ -> gets curModule
  lookupOrFail (fieldIndices mod) id


lookupMeta :: UniqId -> Checked (Maybe Ty)
lookupMeta id = do
  result <- envLookup metaEnv id
  case result of
    Just ty -> do { ty' <- subst ty; return $ Just ty' }
    _ -> return result


isFreeMeta :: Ty -> Checked Bool
isFreeMeta (TyMeta id) = do
  ty <- lookupMeta id
  return $ isNothing ty


markPolyEnv :: Checked (Map.Map UniqId Ty)
markPolyEnv = gets polyEnv


restorePolyEnv :: Map.Map UniqId Ty -> Checked ()
restorePolyEnv env = modify (\tcEnv -> tcEnv { polyEnv = env })


markMetaEnv :: Checked (Map.Map UniqId Ty)
markMetaEnv = gets metaEnv


restoreMetaEnv :: Map.Map UniqId Ty -> Checked ()
restoreMetaEnv env = modify (\tcEnv -> tcEnv { metaEnv = env })


lookupPoly :: UniqId -> Checked (Maybe Ty)
lookupPoly = envLookup polyEnv


lookupTyIn :: Env TyCon -> UniqId -> Checked TyCon
lookupTyIn table id =
  hoistEither $ maybeToEither (ErrUnboundUniqIdentifier id) $ Map.lookup id table


lookupVarIn :: TEnv -> UniqId -> Checked Ty
lookupVarIn table id =
  hoistEither $ maybeToEither (ErrUnboundUniqIdentifier id) $ Map.lookup id table


lookupPatIn :: TEnv -> UniqId -> Checked Ty
lookupPatIn table id =
  hoistEither $ maybeToEither (ErrUnboundUniqIdentifier id) $ Map.lookup id table


lookupPatQual :: UniqAst QualifiedId -> Checked Ty
lookupPatQual (Id p id) = do
  curMod <- gets curModule
  lookupPatIn (patFuns curMod `Map.union` closedPatFuns curMod) id `reportErrorAt` p

lookupPatQual (Path p qid id) = do
  modTy <- lookupVarQual qid `reportErrorAt` nodeData qid
  case modTy of
    TyApp (TyConModule _ mod) _ ->
      lookupPatIn (patFuns mod) id `reportErrorAt` p
    _ -> throwError (ErrInvalidModulePath qid) `reportErrorAt` nodeData qid


lookupTy :: UniqId -> Checked TyCon
lookupTy id = do
  curMod <- gets curModule
  lookupTyIn (types curMod `Map.union` closedTys curMod) id


lookupVarQual :: UniqAst QualifiedId -> Checked Ty
lookupVarQual (Id p id) = lookupVar id
lookupVarQual (Path p qid id) = do
  innerTy <- lookupVarQual qid
  case innerTy of
    TyApp (TyConModule _ mod) _ ->
      hoistEither $ maybeToEither (ErrUndefinedMember p id) $ Map.lookup id $ vars mod
    TyApp (TyConStruct fieldNames) fTys ->
      do fIndex <- hoistEither $ maybeToEither (ErrUndefinedMember p id) $ elemIndex id fieldNames
         return $ fTys !! fIndex


tcQualId :: UniqAst QualifiedId -> Checked (TypedAst QualifiedId, Ty)
tcQualId (Id p id) = lookupVar id >>= \ty -> return (Id (OfTy p ty) id, ty)
tcQualId (Path p qid id) = do
  (qid', innerTy) <- tcQualId qid
  case innerTy of
    TyApp (TyConModule _ mod) _ ->
      do ty <- lookupVarIn (vars mod) id
         return (Path (OfTy p ty) qid' id, ty)
    TyApp (TyConStruct fieldNames) fTys ->
      do fIndex <- hoistEither $ maybeToEither (ErrUndefinedMember p id) $ elemIndex id fieldNames
         let ty = fTys !! fIndex
         return (Path (OfTy p ty) qid' id, ty)
    _ ->
      throwError (ErrInvalidModulePath qid) `reportErrorAt` p


lookupTyQual :: UniqAst QualifiedId -> Checked TyCon
lookupTyQual (Id p id) = lookupTy id `reportErrorAt` p
lookupTyQual (Path p qid id) = do
  ty <- lookupVarQual qid
  case ty of
    TyApp (TyConModule _ mod) _ -> lookupTyIn (types mod) id `reportErrorAt` p
    _ -> throwError (ErrInvalidModulePath qid) `reportErrorAt` p


lookupVar :: UniqId -> Checked Ty
lookupVar = envLookupOrFail varEnv


occursInTyCon :: Ty -> TyCon -> Bool
occursInTyCon tyMeta@(TyMeta metaId) tyCon =
  case tyCon of
    TyConTyFun _ ty -> occursIn tyMeta ty
    TyConUnique _ tyCon -> occursInTyCon tyMeta tyCon
    _ -> False

occursIn :: Ty -> Ty -> Bool
occursIn tyMeta@(TyMeta metaId) ty =
  case ty of
    TyApp tyCon argTys ->
      occursInTyCon tyMeta tyCon || any (occursIn tyMeta) argTys
    TyPoly _ ty -> occursIn tyMeta ty
    TyVar _ -> False
    TyMeta otherMetaId -> metaId == otherMetaId
    TyRef _ -> False
    TyInstFun instTy funTy ->
      occursIn tyMeta instTy || occursIn tyMeta funTy


occursIn _ _ = False


expand :: Ty -> Checked Ty
expand (TyApp (TyConTyFun tyParamIds ty) tyArgs) = do
  mapM_ (uncurry bindPoly) $ zip tyParamIds tyArgs
  ty' <- subst ty
  expand ty'
expand (TyApp (TyConUnique _ tyCon) tyArgs) =
  expand (TyApp tyCon tyArgs)
expand meta@(TyMeta id) = do
  maybeTy <- lookupMeta id
  case maybeTy of
    Just ty -> expand ty
    _ -> return meta

expand ty = return ty


-- generalize: Lift all free metavariables
-- up to poly type params, yielding a poly type
-- Note that applying this function to any
-- type will yield a poly type, so monomorphic
-- types will become poly types with empty
-- type param lists

allMetaIdsInTyCon :: TyCon -> [UniqId]
allMetaIdsInTyCon (TyConTyFun _ ty) = allMetaIdsIn ty
allMetaIdsInTyCon (TyConUnique _ tyCon) = allMetaIdsInTyCon tyCon
allMetaIdsInTyCon _ = []


allMetaIdsIn :: Ty -> [UniqId]
allMetaIdsIn ty =
  case ty of
    TyApp tyCon tyArgs ->
      allMetaIdsInTyCon tyCon ++ concatMap allMetaIdsIn tyArgs
    TyPoly _ ty -> allMetaIdsIn ty
    TyVar _ -> []
    TyMeta id -> [id]
    TyRef _ -> []
    TyInstFun instTy funTy ->
      allMetaIdsIn instTy ++ allMetaIdsIn funTy


referencedMetaIds :: UniqId -> Checked [UniqId]
referencedMetaIds metaId = do
  result <- lookupMeta metaId
  refdIds <- case result of
    Just ty ->
      case ty of
        TyMeta id -> referencedMetaIds id
        _ -> return []
    _ -> return []
  return (metaId : refdIds)


allMetasInEnv :: Checked [UniqId]
allMetasInEnv = do
  varEnv <- gets varEnv
  let allTys = snd $ unzip $ Map.toList varEnv
      metaTys  = filter (\ty -> case ty of
                                  TyMeta _ -> True
                                  _ -> False)
                        allTys
      allMetaIds = map (\(TyMeta id) -> id) metaTys
  allBoundMetaIdSets <- mapM referencedMetaIds allMetaIds
  return $ concat allBoundMetaIdSets


freeMetas :: Ty -> Checked [UniqId]
freeMetas ty =
  let occurringMetaIds = allMetaIdsIn ty
  in do allMetaIds <- allMetasInEnv
        let occursSet = Set.fromList occurringMetaIds
            envSet = Set.fromList allMetaIds
            freeSet = Set.difference occursSet envSet
        return $ Set.toList freeSet


trimUnusedPolyParams :: Ty -> Checked Ty
trimUnusedPolyParams (TyPoly [] ty) = return ty
trimUnusedPolyParams (TyPoly tyParamIds ty) =
    case tyParamIds' of
      [] -> return ty
      _ -> return $ TyPoly tyParamIds' ty
  where
    allTyConVarIds tyCon =
      case tyCon of
        TyConTyVar id -> [id]
        TyConTyFun _ ty -> allTyVarIds ty
        _ -> []
    allTyVarIds ty =
      case ty of
        TyApp tyCon tys -> allTyConVarIds tyCon ++ concatMap allTyVarIds tys
        TyPoly _ ty -> allTyVarIds ty
        TyVar id -> [id]
        TyMeta id -> []
        TyRef _ -> []
        TyInstFun instTy funTy -> allTyVarIds instTy ++ allTyVarIds funTy
    paramIdSet = Set.fromList tyParamIds
    usedParamIdSet = Set.fromList $ allTyVarIds ty
    tyParamIds' = Set.toList $ Set.intersection paramIdSet usedParamIdSet

trimUnusedPolyParams ty = return ty


generalize :: Ty -> Checked Ty
generalize ty = do
  -- traceM $ printf "Generalizing %s" $ showSexp ty
  ty' <- subst ty
  frees <- freeMetas ty'
  tyParamIds <- mapM (const freshId) frees
  let metasAndTyParamIds = zip frees tyParamIds
  mapM_ (\(metaId, paramId) -> bindMeta metaId $ TyVar paramId)
        metasAndTyParamIds
  ty'' <- subst ty'
  case tyParamIds of
    [] -> return ty''
    _ ->
      let retTy = TyPoly tyParamIds ty''
      in trimUnusedPolyParams retTy


instantiate :: Ty -> Checked Ty
instantiate (TyPoly tyParamIds ty) = do
  mapM_ (\paramId -> do { meta <- freshMeta; bindPoly paramId meta })
        tyParamIds
  subst ty

instantiate ty = return ty


substTyCon :: TyCon -> Checked TyCon
substTyCon (TyConTyFun varIds ty) = do
  ty' <- subst ty
  return $ TyConTyFun varIds ty'

substTyCon tyCon = return tyCon


subst :: Ty -> Checked Ty
subst ty =
  -- traceM $ printf "Substing %s" $ showSexp ty
  case ty of
    meta@(TyMeta id) -> do
      maybeTy <- lookupMeta id
      case maybeTy of
        Just ty -> subst ty
        _ -> return meta

    TyApp (TyConTyFun [] tyRef@(TyRef _)) [] -> subst tyRef

    TyApp tyCon@(TyConTyFun tyParamIds ty) tyArgs
      | length tyParamIds == length tyArgs ->
        do mapM_ (uncurry bindPoly) $ zip tyParamIds tyArgs
           subst ty >>= subst
      | otherwise ->
        do madeUpId <- freshId
           throwError $ ErrPartialTyConApp (Id (SourcePos "" 0 0) madeUpId) tyCon tyArgs

    TyApp tyCon tyArgs -> do
      tyCon' <- substTyCon tyCon
      tyArgs' <- mapM subst tyArgs
      return $ TyApp tyCon' tyArgs'

    var@(TyVar id) -> do
      maybeTy <- lookupPoly id
      case maybeTy of
        Just ty -> return ty
        _ -> return var

    TyPoly tyParamIds ty -> do
      ty' <- subst ty
      return $ TyPoly tyParamIds ty'

    TyRef (Id _ id) -> do
      tyCon <- lookupTy id
      tyCon' <- substTyCon tyCon
      return $ TyApp tyCon' []

    TyInstFun instTy funTy -> do
      instTy' <- subst instTy
      funTy' <- subst funTy
      return $ TyInstFun instTy' funTy'


-- Helper for type mismatches (we don't want
-- to expose types with free metavariables to the
-- user, so we generalize before reporting a
-- type error)
unifyFail :: Ty -> Ty -> Checked Ty
unifyFail a b = do
  a' <- generalize a
  b' <- generalize b
  throwError $ ErrCantUnify a b


unify :: Ty -> Ty -> Checked Ty
unify tya tyb = do
  -- traceM $ printf "Unifying %s --> %s" (showSexp tya) (showSexp tyb)
  oldPolyEnv <- markPolyEnv
  oldMetaEnv <- markMetaEnv
  case (tya, tyb) of
    (a@(TyApp tyconA tyArgsA), b@(TyApp tyconB tyArgsB))
      | tyconA == tyconB ->
        do mapM_ (uncurry unify) $ zip tyArgsA tyArgsB
           return a

    (TyApp (TyConTyFun paramVarIds ty) tyArgs, tyb) -> do
      mapM_ (uncurry bindPoly) $ zip paramVarIds tyArgs
      ty' <- subst ty
      unify ty' tyb

    (tya, TyApp (TyConTyFun paramVarIds ty) tyArgs) -> do
      mapM_ (uncurry bindPoly) $ zip paramVarIds tyArgs
      ty' <- subst ty
      unify tya ty'

    (TyPoly [] ty, tyb) -> unify ty tyb

    (TyPoly aParamIds aty, TyPoly bParamIds bty) ->
      let paramIds = zip bParamIds aParamIds
      in do mapM_ (\(bParamId, aParamId) -> bindPoly bParamId $ TyVar aParamId)
                  paramIds
            bty' <- subst bty
            unify aty bty'

    (meta@(TyMeta metaId), ty) -> do
      metaTy <- lookupMeta metaId
      case metaTy of
        Just mty -> unify mty ty
        _ ->
          case ty of
            TyApp (TyConTyFun _ _) _ -> do
              expanded <- expand ty
              unify meta expanded
            TyMeta rhMetaId ->
              if metaId == rhMetaId
              then return meta
              else do maybeRhMetaTy <- lookupMeta rhMetaId
                      case maybeRhMetaTy of
                        Just rhMetaTy -> unify meta rhMetaTy
                        _ -> do bindMeta metaId ty
                                return ty
            _ ->
              if meta `occursIn` ty
              then throwError $ ErrCircularType meta ty
              else do
                bindMeta metaId ty
                return ty

    (ta@(TyVar a), tb@(TyVar b)) ->
      if a == b
      then do ty <- lookupPoly a
              return $ fromMaybe ta ty
      else throwError $ ErrCantUnify ta tb

    (ty, meta@(TyMeta _)) -> unify meta ty
    (ta@(TyRef a), tb@(TyRef b)) ->
      if a == b
      then do tyCon <- lookupTyQual a
              return $ TyApp tyCon []
      else unifyFail ta tb

    (tyRef@(TyRef _), ty) -> unify ty tyRef
    (ty, TyRef qid) -> do
      tyb <- lookupTyQual qid
      unify ty $ TyApp tyb []

    (TyInstFun instTyA funTyA, TyInstFun instTyB funTyB) -> do
      instTy <- unify instTyA instTyB
      funTy <- unify funTyA funTyB
      return $ TyInstFun instTy funTy

    (ta, tb) -> unifyFail ta tb


unifyAll :: [Ty] -> Checked Ty
unifyAll [] = freshMeta
unifyAll [ty] = return ty
unifyAll (ta:tb:tys) = do
  ty' <- unify ta tb
  unifyAll (ty':tys)


tcArith :: (CheckedData -> TypedAst Exp -> TypedAst Exp -> TypedAst Exp)
        -> SourcePos
        -> UniqAst Exp
        -> UniqAst Exp
        -> Checked (Ty, TypedAst Exp)
tcArith ctor p a b = do
  (tya, a') <- tc a
  (tyb, b') <- tc b
  unify tyInt tya
  unify tyInt tyb
  return (tyInt, ctor (OfTy p tyInt) a' b')


-- A "syntax-level type" is just an
-- AST representing a type
tcTy :: UniqAst SynTy -> Checked Ty
tcTy (SynTyInt _) = return tyInt
tcTy (SynTyBool _) = return tyBool
tcTy (SynTyChar _) = return tyChar
tcTy (SynTyUnit _) = return tyUnit
tcTy (SynTyArrow _ paramTys retTy) = do
  paramTys' <- mapM tcTy paramTys
  retTy' <- tcTy retTy
  return $ TyApp TyConArrow $ paramTys' ++ [retTy']

tcTy (SynTyTuple _ tyArgs) = do
  tyArgs' <- mapM tcTy tyArgs
  return $ TyApp TyConTuple tyArgs'

tcTy (SynTyList _ tyArg) = do
  tyArg' <- tcTy tyArg
  return $ TyApp TyConList [tyArg']

tcTy (SynTyRef _ qid synTyArgs) = do
  tyCon <- lookupTyQual qid
  case tyCon of
    TyConTyVar id' -> return $ TyVar id'
    _ -> do tyArgs <- mapM tcTy synTyArgs
            return $ TyApp tyCon tyArgs


tcAdtAlt :: UniqAst AdtAlternative -> Checked (UniqId, [Ty])
tcAdtAlt (AdtAlternative _ id _ synTys) = do
  argTys <- mapM tcTy synTys
  return (id, argTys)


makeAdtCtor :: UniqAst AdtAlternative -> Ty -> Ty -> [Ty] -> Checked (TypedAst Exp)
makeAdtCtor (AdtAlternative p ctorId ctorInd synTys) adtTy ctorTy argTys = do
  paramIds <- mapM (const freshId) synTys
  let paramDs = map (\(paramId, synTy, ty) -> (paramId, nodeData synTy, ty))
                    $ zip3 paramIds synTys argTys
      paramRefs = map (\(paramId, pp, pty) -> (ExpRef (OfTy pp pty) paramId)) paramDs
      argPatEs = map (\(paramId, paramTy) -> PatExpId (OfTy p paramTy) paramId) $ zip paramIds argTys
      ctorFun = ExpFun (OfTy p ctorTy) argPatEs [ExpMakeAdt (OfTy p adtTy) ctorId ctorInd paramRefs]
  return $ ExpAssign (OfTy p tyUnit) (PatExpId (OfTy p ctorTy) ctorId) ctorFun


tcTyDec :: UniqAst TypeDec -> Checked (TyCon, [TypedAst Exp])
tcTyDec (TypeDecTy _ id tyParamIds (SynTyInt _)) = return (TyConInt, [])
tcTyDec (TypeDecTy _ id tyParamIds (SynTyBool _)) = return (TyConBool, [])
tcTyDec (TypeDecTy _ id tyParamIds (SynTyChar _)) = return (TyConChar, [])
tcTyDec (TypeDecTy _ id tyParamIds synTy@(SynTyRef _ qid synTyArgs)) = do
  mapM_ (\tyParamId -> exportTy tyParamId $ TyConTyVar tyParamId) tyParamIds
  tyArgs <- mapM tcTy synTyArgs
  ty <- tcTy synTy
  let tycon = TyConTyFun tyParamIds ty
  exportTy id tycon
  return (tycon, [])

tcTyDec (TypeDecTy _ id tyParamIds (SynTyList _ sty)) = do
  mapM_ (\tyParamId -> exportTy tyParamId $ TyConTyVar tyParamId) tyParamIds
  elemTy <- tcTy sty
  let tycon = TyConTyFun tyParamIds $ TyApp TyConList [elemTy]
  exportTy id tycon
  return (tycon, [])

-- We desugar struct types into simple product types, with getter
-- functions for each field using the following rule:
--
-- type ID = { TY0 FID0; TY1 FID1; };
--
-- -->
--
-- type ID = ID TY0 TY1;
--
-- FID0 => fun(ID) : TY0;
-- FID0(x) { get-adt-field(ID, 0); };
--
-- FID1 => fun(ID) : TY1;
-- FID1(x) { get-adt-field(x, 1); };
tcTyDec (TypeDecTy p id tyParamIds (SynTyStruct _ fields)) =
  let (fieldNames, fieldSynTys) = unzip fields
  in do
    -- Bind a 'name' type for recursive definitions
    exportTy id $ TyConTyFun tyParamIds $ TyRef $ Id p id
    -- Bind a 'tyvar' tycon for each type parameter
    mapM_ (\tyParamId -> exportTy tyParamId $ TyConTyVar tyParamId) tyParamIds
    fieldTys <- mapM tcTy fieldSynTys
    let alt = AdtAlternative p id 0 fieldSynTys
        adtDec = TypeDecAdt p id tyParamIds [alt]
    (adtTyCon, es) <- tcTyDec adtDec
    let adtTy = TyApp adtTyCon [TyApp TyConTuple fieldTys]
    getters <- mapMi (\index (fName, fTy) ->
                        let getterTy = TyApp TyConArrow [adtTy, fTy]
                        in do bindFieldIndex fName index
                              bindVar fName getterTy
                              paramId <- freshId
                              return $
                                ExpAssign
                                  (OfTy p tyUnit)
                                  (PatExpId (OfTy p getterTy) fName)
                                  (ExpFun
                                    (OfTy p getterTy)
                                    [PatExpId (OfTy p adtTy) paramId]
                                    [ExpGetAdtField (OfTy p adtTy) (ExpRef (OfTy p adtTy) paramId) index]))
                (zip fieldNames fieldTys)
    return (adtTyCon, es ++ getters)

tcTyDec (TypeDecAdt p id tyParamIds alts) = do
  -- Bind a 'name' type for recursive definitions
  exportTy id $ TyConTyFun tyParamIds $ TyRef $ Id p id
  -- Bind a 'tyvar' tycon for each type parameter
  mapM_ (\tyParamId -> exportTy tyParamId $ TyConTyVar tyParamId) tyParamIds
  altNamesTys <- mapM tcAdtAlt alts
  let (names, tys) = unzip altNamesTys
      altsTys = zip alts tys
      ctorTups = map (TyApp TyConTuple) tys
      adtTyCon = TyConUnique id $ TyConTyFun tyParamIds $ TyApp (TyConAdt names) ctorTups
  -- Add a function binding for each constructor,
  -- and return a function expression for each one
  ctorEs <- mapM (\(alt@(AdtAlternative altPos ctorName _ _), argTys) ->
                    let ctorTy = TyPoly tyParamIds $ TyApp TyConArrow (argTys ++ [TyApp adtTyCon (map TyVar tyParamIds)])
                    in do bindVar ctorName ctorTy
                          putPatBinding ctorName ctorTy
                          makeAdtCtor alt (TyApp adtTyCon argTys) ctorTy argTys)
                 altsTys
  return (adtTyCon, ctorEs)


tcStructFields :: [(UniqId, Ty)] -> [(UniqId, UniqAst Exp)] -> Checked (Ty, [(UniqId, TypedAst Exp)])
tcStructFields _ [] = return (tyUnit, [])
tcStructFields tyFields ((fieldId, fieldExp):fieldInitExps) =
  let maybeField = find (flip ((==) . fst) fieldId) tyFields
  in
    case maybeField of
      Nothing -> throwError $ ErrUndefinedMember (nodeData fieldExp) fieldId
      Just (matchedFieldId, matchedTy) -> do
        (initExpTy, fieldExp') <- tc fieldExp
        unify matchedTy initExpTy
        (ty, fieldInitExps') <- tcStructFields tyFields fieldInitExps
        return (ty, (matchedFieldId, fieldExp') : fieldInitExps')


tcPatExp :: UniqAst PatExp -> Checked (Ty, TypedAst PatExp)
tcPatExp (PatExpNumLiteral p n) = return (tyInt, PatExpNumLiteral (OfTy p tyInt) n)
tcPatExp (PatExpBoolLiteral p b) = return (tyBool, PatExpBoolLiteral (OfTy p tyBool) b)
tcPatExp (PatExpStringLiteral p s) = return (tyStr, PatExpStringLiteral (OfTy p tyStr) s)
tcPatExp (PatExpCharLiteral p s) = return (tyChar, PatExpCharLiteral (OfTy p tyChar) s)
tcPatExp (PatExpTuple p es) = do
  (eTys, es') <- mapAndUnzipM tcPatExp es
  let ty = TyApp TyConTuple eTys
  return (ty, PatExpTuple (OfTy p ty) es')

tcPatExp (PatExpAdt p qid es) = do
  patFunTy <- lookupPatQual qid
  (qid', _) <- tcQualId qid
  (eTys, es') <- mapAndUnzipM tcPatExp es
  retTyMeta@(TyMeta retTyMetaId) <- freshMeta
  let gotTy = TyApp TyConArrow $ eTys ++ [retTyMeta]
  patFunTy' <- instantiate patFunTy
  (TyApp TyConArrow eTys) <- unify patFunTy' gotTy
  let (retTy:_) = reverse eTys
  return (retTy, PatExpAdt (OfTy p retTy) qid' es')

tcPatExp (PatExpList p es) = do
  (eTys, es') <- mapAndUnzipM tcPatExp es
  patElemTy <- unifyAll eTys `reportErrorAt` p
  let ty = TyApp TyConList [patElemTy]
  return (ty, PatExpList (OfTy p ty) es')

tcPatExp (PatExpListCons p eHd eTl) = do
  (hdTy, eHd') <- tcPatExp eHd
  (tlTy, eTl') <- tcPatExp eTl
  ty <- unify tlTy $ TyApp TyConList [hdTy]
  return (ty, PatExpListCons (OfTy p ty) eHd' eTl')

tcPatExp (PatExpId p id) = do
  ty <- freshMeta
  bindVar id ty
  return (ty, PatExpId (OfTy p ty) id)

tcPatExp (PatExpWildcard p) = do
  ty <- freshMeta
  return (ty, PatExpWildcard (OfTy p ty))


addBindingsForPat :: UniqAst PatExp -> Ty -> Checked ()
addBindingsForPat (PatExpTuple _ patEs) (TyApp TyConTuple tyArgs) =
  let componentEsTys = zip patEs tyArgs
  in mapM_ (uncurry addBindingsForPat) componentEsTys

addBindingsForPat (PatExpAdt _ _ es) (TyApp (TyConUnique _ _) argTys) =
  mapM_ (uncurry addBindingsForPat) $ zip es argTys

addBindingsForPat (PatExpList _ elemEs) (TyApp TyConList [tyArg]) =
  let addBindingsForPatWithTy = flip addBindingsForPat tyArg
  in mapM_ addBindingsForPatWithTy elemEs

addBindingsForPat (PatExpList _ elemEs) (TyPoly [tyParamId] (TyApp TyConList [tyArg])) =
  let elemTy = TyPoly [tyParamId] tyArg
      addBindingsForPatWithTy = flip addBindingsForPat elemTy
  in mapM_ addBindingsForPatWithTy elemEs

addBindingsForPat (PatExpList _ []) (TyMeta _) = return ()

addBindingsForPat (PatExpListCons _ hdE tlE) ty@(TyApp TyConList [tyArg]) = do
  addBindingsForPat hdE tyArg
  addBindingsForPat tlE ty

addBindingsForPat (PatExpId _ id) ty = bindVar id ty
addBindingsForPat (PatExpWildcard _) _ = return ()
addBindingsForPat (PatExpNumLiteral _ _) _ = return ()
addBindingsForPat (PatExpBoolLiteral _ _) _ = return ()
addBindingsForPat (PatExpStringLiteral _ _) _ = return ()
addBindingsForPat (PatExpCharLiteral _ _) _ = return ()

addBindingsForPat patE ty =
  throwError $ ErrPatMatchBindingFail patE ty


tc :: UniqAst Exp -> Checked (Ty, TypedAst Exp)
tc (ExpUnit p) = return (mtApp TyConUnit, ExpUnit (OfTy p (mtApp TyConUnit)))
tc (ExpFail p msg) = do
  ty <- freshMeta
  return (ty, ExpFail (OfTy p ty) msg)

tc (ExpRef p id) = do
  -- traceM $ printf "tc ExpRef %s" $ show id
  ty <- lookupVar id `reportErrorAt` p
  ty' <- instantiate ty
  return (ty', ExpRef (OfTy p ty') id)

tc (ExpString p s) = return (tyStr, ExpString (OfTy p tyStr) s)
tc (ExpChar p s) = return (tyChar, ExpChar (OfTy p tyChar) s)
tc (ExpBool p b) = return (tyBool, ExpBool (OfTy p tyBool) b)
tc (ExpNum p n) = return (tyInt, ExpNum (OfTy p tyInt) n)

tc (ExpAdd p a b) = tcArith ExpAdd p a b
tc (ExpSub p a b) = tcArith ExpSub p a b
tc (ExpDiv p a b) = tcArith ExpDiv p a b
tc (ExpMul p a b) = tcArith ExpMul p a b

tc (ExpCons p headE listE) = do
  (tyListE, listE') <- tc listE
  (tyHeadE, headE') <- tc headE
  tyListE' <- instantiate tyListE
  listTy <- case tyListE' of
              TyApp TyConList _ ->
                unify tyListE' (TyApp TyConList [tyHeadE]) >>= subst
              _ -> -- Failure case, we unify expecting a (ListOf(<headTy>)) to fail
                unify (TyApp TyConList [tyHeadE]) tyListE'
  return (listTy, ExpCons (OfTy p listTy) headE' listE')

tc (ExpMemberAccess p e id) = do
  -- traceM $ printf "tc ExpMemberAccess %s %s" (show e) (show id)
  (eTy, e') <- tc e
  case eTy of
    TyApp (TyConModule _ mod) [] ->
      do ty <- lookupVarIn (vars mod) id `reportErrorAt` p
         ty' <- instantiate ty
         return (ty', ExpMemberAccess (OfTy p ty) e' id)
    _ ->
      tc $ ExpApp p (ExpRef p id) [e]

tc (ExpApp p ratorE randEs) = do
  (fty, ratorE') <- tc ratorE
  (randTys, randEs') <- mapAndUnzipM tc randEs
  retTyMeta@(TyMeta retTyMetaId) <- freshMeta
  (TyApp TyConArrow arrowTys) <-
    withFailPos' p $ unify fty $ TyApp TyConArrow $ randTys ++ [retTyMeta]
  let ty = case reverse arrowTys of
              [] -> tyUnit
              retTy:_ -> retTy
      arity = length arrowTys - 1
      argLen = length randEs
  if arity /= argLen
  then throwError (ErrWrongArity ratorE' arity argLen) `reportErrorAt` p
  else do ty' <- subst ty
          return (ty', ExpApp (OfTy p ty) ratorE' randEs')

-- module { m1 ... mn } --> App(Module, [tc(m1), ..., tc(mn)]
-- module <t1, ..., tn> { ... } --> Poly([t1, ..., tn], App(Module ...))
tc (ExpModule p paramIds es) = do
  oldEnv <- pushNewModuleContext
  (_, es') <- mapAndUnzipM tc es
  curMod <- gets curModule
  restoreContext oldEnv
  let tyApp = TyApp (TyConModule paramIds curMod) $ map TyVar paramIds
      tyApp' = case paramIds of
                [] -> tyApp
                _ -> TyPoly paramIds tyApp
  return (tyApp', ExpModule (OfTy p tyApp') paramIds es')

tc (ExpAssign p patE (ExpFun funP paramPatEs bodyEs)) =
    case patE of
      PatExpId patP id -> do
        paramMetas <- mapM (const freshMeta) paramPatEs
        bodyTyMeta <- freshMeta
        let paramsAndTys = zip paramIds paramMetas
            fty = TyApp TyConArrow $ paramMetas ++ [bodyTyMeta]
        oldVarEnv <- markVarEnv
        mapM_ (uncurry bindVar) paramsAndTys
        (bodyTy, bodyEs') <- tcEs bodyEs
        unify bodyTyMeta bodyTy
        restoreVarEnv oldVarEnv
        fty' <- generalize fty
        bindVar id fty'
        patEMeta <- freshMeta
        let paramPatEs' = map (\(paramId, paramTy) -> PatExpId (OfTy p paramTy) paramId) paramsAndTys
        return (tyUnit, ExpAssign (OfTy p tyUnit)
                                  (PatExpId (OfTy patP patEMeta) id)
                                  (ExpFun (OfTy funP fty') paramPatEs' bodyEs'))
      _ ->
        throwError ErrInvalidFunPattern
  where
    paramIds = map (\(PatExpId _ id) -> id) paramPatEs

tc (ExpAssign p patE rhe) = do
  oldVarEnv <- markVarEnv
  (rheTy, rhe') <- tc rhe
  (patTy, patE') <- tcPatExp patE
  unify patTy rheTy `reportErrorAt` p
  rheTy' <- generalize rheTy
  addBindingsForPat patE rheTy'
  return (tyUnit, ExpAssign (OfTy p tyUnit) patE' rhe')

tc (ExpTuple p es) = do
  eMetas <- mapM (const freshMeta) es
  (tys, es') <- mapAndUnzipM tc es
  ty <- unify (TyApp TyConTuple tys) (TyApp TyConTuple eMetas) `reportErrorAt` p
  return (ty, ExpTuple (OfTy p ty) es')

tc (ExpSwitch p e clauses) = do
  (tyE, e') <- tc e
  (cTys, clauses') <-
    mapAndUnzipM (\(CaseClause cp patE ces) ->
                      do oldVarEnv <- markVarEnv
                         (pty, patE') <- tcPatExp patE
                         pty' <- unify tyE pty `reportErrorAt` nodeData patE
                         (retTy, ces') <- tcEs ces
                         restoreVarEnv oldVarEnv
                         return (retTy, CaseClause (OfTy cp retTy) patE' ces'))
                  clauses
  ty <- unifyAll cTys `reportErrorAt` p >>= instantiate
  return (ty, ExpSwitch (OfTy p ty) e' clauses')

tc (ExpList p es) = do
  (tys, es') <- mapAndUnzipM tc es
  elemTy <- unifyAll tys `reportErrorAt` p
  let ty = TyApp TyConList [elemTy]
  return (ty, ExpList (OfTy p ty) es')

tc (ExpFun p argPatEs bodyEs) = do
  paramMetas <- mapM (const freshMeta) argPatEs
  bodyTyMeta <- freshMeta
  let fty = TyApp TyConArrow $ paramMetas ++ [bodyTyMeta]
  oldVarEnv <- markVarEnv
  (_, argPatEs') <- mapAndUnzipM tcPatExp argPatEs
  (bodyTy, bodyEs') <- tcEs bodyEs
  unify bodyTyMeta bodyTy `reportErrorAt` p
  restoreVarEnv oldVarEnv
  return (fty, ExpFun (OfTy p fty) argPatEs' bodyEs')

tc (ExpMakeAdt p synTy i es) = throwError $ ErrNotImplemented "tc for MakeAdt"

tc (ExpStruct p strSynTy@(SynTyRef pSty qid _) fieldInitEs) = do
  ty <- tcTy strSynTy
  sorted <- sortByM (\a@(aId, _) b@(bId, _) -> do
                        aInd <- lookupFieldIndex qid aId
                        bInd <- lookupFieldIndex qid bId
                        return $ compare aInd bInd)
                    fieldInitEs
  let initEs = (snd . unzip) sorted
  (qid', ctorTy) <- tcQualId qid `reportErrorAt` nodeData qid
  let eMemberAccess = qualIdToMemberAcc qid'
  (_, initEs') <- tcEs initEs
  return (ty, ExpApp (OfTy p ty) eMemberAccess initEs')

tc (ExpTypeDec p tyDec) =
  let id = getTypeDecId tyDec
  in do
    (tycon, es) <- tcTyDec tyDec
    exportTy id tycon
    return (tyUnit, ExpBegin (OfTy p tyUnit) es)

-- We must bind the name before typechecking
-- the right-hand side (otherwise recursive
-- applications will fail)
-- We do this by binding the name in the
-- var environment to the type:
--
-- App(Arrow, [meta1, ..., metaN])
--
-- Where meta1 ... meta(N-1) are (fresh) metavariables
-- for parameters, and metaN is a fresh metavariable
-- representing the return type.
-- We also prohibit pattern-match bindings
-- for functions here (require simple identifier patterns)
tc (ExpFunDef (FunDefFun p id paramPatEs bodyEs)) = do
    paramMetas <- mapM (const freshMeta) paramIds
    bodyTyMeta <- freshMeta
    let paramsAndTys = zip paramIds paramMetas
        fty = TyApp TyConArrow $ paramMetas ++ [bodyTyMeta]
    oldVarEnv <- markVarEnv
    mapM_ (uncurry bindVar) paramsAndTys
    bindVar id fty
    (bodyTy, bodyEs') <- tcEs bodyEs
    unify bodyTyMeta bodyTy
    restoreVarEnv oldVarEnv
    fty' <- generalize fty
    bindVar id fty'
    let paramPatEs' = map (\(paramId, paramTy) -> PatExpId (OfTy p paramTy) paramId) paramsAndTys
    return (tyUnit, ExpFunDef (FunDefFun (OfTy p fty') id paramPatEs' bodyEs'))
  where
    paramIds = map (\(PatExpId _ id) -> id) paramPatEs

tc (ExpFunDef (FunDefInstFun p instPatE id paramPatEs bodyEs)) =
  let (PatExpId instPatP instId) = instPatE
      innerFun = ExpFun p paramPatEs bodyEs
      outerFunDef = FunDefFun p id [instPatE] [innerFun]
    in tc $ ExpFunDef outerFunDef

tc (ExpWithAnn (TyAnn _ id tyParamIds synTy) e) = do
  oldMetaEnv <- markMetaEnv
  mapM_ (\tyParamId -> exportTy tyParamId $ TyConTyVar tyParamId) tyParamIds
  givenTy <- tcTy synTy
  let givenTy' = case tyParamIds of
                  [] -> givenTy
                  _  -> TyPoly tyParamIds givenTy
  (_, e') <- tc e
  inferredTy <- lookupVar id `reportErrorAt` nodeData e
  givenTy'' <- instantiate givenTy'
  inferredTy' <- instantiate inferredTy
  ty <- unify givenTy'' inferredTy' `reportErrorAt` nodeData e

  restoreMetaEnv oldMetaEnv
  generalize ty >>= bindVar id
  return (ty, e')

tc (ExpIfElse p testE thenEs elseEs) = do
  oldVarEnv <- markVarEnv
  (testTy, testE') <- tc testE
  unify tyBool testTy
  restoreVarEnv oldVarEnv
  (thenTy, thenEs') <- tcEs thenEs
  restoreVarEnv oldVarEnv
  (elseTy, elseEs') <- tcEs elseEs
  ty <- unify thenTy elseTy
  restoreVarEnv oldVarEnv
  return (ty, ExpIfElse (OfTy p ty) testE' thenEs' elseEs')

tc e = throwError $ ErrInterpFailure $ printf "In function tc: %s" $ show e


tcEs :: [UniqAst Exp] -> Checked (Ty, [TypedAst Exp])
tcEs [] = return (mtApp TyConUnit, [])
tcEs es = do
  (tys, es') <- mapAndUnzipM tc es
  return (last tys, es')


tcCompUnit :: UniqAst CompUnit -> Checked (Ty, TypedAst CompUnit)
tcCompUnit (CompUnit p es) = do
  (ty, es') <- tcEs es
  ty' <- generalize ty
  return (ty', CompUnit (OfTy p ty') es')


typeCheck :: UniqAst CompUnit -> AlphaEnv -> Either Err (TypedAst CompUnit, AlphaEnv)
typeCheck cu aEnv = do
  (tyResult, tcEnv) <- return $ runState (runExceptT (tcCompUnit cu)) $ mtTCEnv aEnv
  (ty, cu') <- tyResult
  return (cu', alphaEnv tcEnv)