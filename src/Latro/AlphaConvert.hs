{-# LANGUAGE FlexibleContexts, NamedFieldPuns #-}

module AlphaConvert where

import Common
import Control.Applicative
import Control.Monad.Except
import Control.Monad.State
import Data.List (all, find, nub)
import qualified Data.Map as Map (insert, lookup, union)
import Errors
import Prelude hiding (lookup)
import Semant
import Text.Printf (printf)


reportErrorAt a = reportPosOnFail a "AlphaConvert"


data Frame = Frame
  { index :: Int
  , varIdEnv  :: RawIdEnv AlphaEntry
  , typeIdEnv :: RawIdEnv AlphaEntry
  }
  deriving (Eq, Show)


mtFrame :: Int -> Frame
mtFrame ind = Frame { index = ind
                    , varIdEnv = mtRawIdEnv
                    , typeIdEnv = mtRawIdEnv
                    }


data AlphaEntry =
    UniqIdEntry UniqId
  | FrameEntry UniqId Frame
  deriving (Eq, Show)


data AlphaEnv = AlphaEnv
  { counter :: Int
  , stack   :: [Frame]
  }
  deriving (Eq)


mtAlphaEnv :: AlphaEnv
mtAlphaEnv =
    AlphaEnv { counter = i
             , stack   = [mtFrame i]
             }
  where i = 1


type AlphaConverted a = ExceptT Err (State AlphaEnv) a


pushFrame :: AlphaConverted ()
pushFrame = do
  index <- nextIdIndexM
  modify (\aEnv -> aEnv { stack = mtFrame index : stack aEnv })


popFrame :: AlphaConverted Frame
popFrame = do
  (frame : frames) <- gets stack
  modify (\aEnv -> aEnv { stack = frames })
  return frame


inNewFrame :: AlphaConverted a -> AlphaConverted a
inNewFrame thunk = do
  pushFrame
  v <- thunk
  popFrame
  return v


modifyFrame :: (Frame -> Frame) -> AlphaConverted ()
modifyFrame fModify = do
  (frame : frames) <- gets stack
  modify (\aEnv -> aEnv { stack = fModify frame : frames })


bindInCurrentFrame :: RawId -> AlphaEntry -> AlphaConverted ()
bindInCurrentFrame rawId entry = do
  (frame : frames) <- gets stack
  let updatedVars = Map.insert rawId entry $ varIdEnv frame
  modify (\aEnv -> aEnv { stack = (frame { varIdEnv = updatedVars }) : frames })


freshVarId id aEnv@(AlphaEnv { counter, stack }) =
    (uniqId, aEnv { counter = counter', stack = frame' : frames })
  where
    counter' = counter + 1
    uniqId = UniqId counter id
    (frame : frames) = stack
    frame' = frame { varIdEnv = Map.insert id (UniqIdEntry uniqId) $ varIdEnv frame }


freshTypeId :: RawId -> AlphaEnv -> (UniqId, AlphaEnv)
freshTypeId id aEnv@(AlphaEnv { counter, stack }) =
    (uniqId, aEnv { counter = counter', stack = frame' : frames })
  where
    counter' = counter + 1
    uniqId = UniqId counter id
    (frame : frames) = stack
    frame' = frame { typeIdEnv = Map.insert id (UniqIdEntry uniqId) $ typeIdEnv frame }


freshM :: RawId -> (RawId -> AlphaEnv -> (UniqId, AlphaEnv)) -> AlphaConverted UniqId
freshM id fMake = do
  alphaEnv <- get
  let (uniqId, alphaEnv') = fMake id alphaEnv
  lift $ put alphaEnv'
  return uniqId


freshVarIdM :: RawId -> AlphaConverted UniqId
freshVarIdM id = freshM id freshVarId


freshVarIdIfNotBoundM :: RawId -> AlphaConverted UniqId
freshVarIdIfNotBoundM id = do
  curFrame <- gets $ head . stack
  if isBoundIn id [curFrame] varIdEnv
    then throwError $ ErrIdAlreadyBound id
    else freshVarIdM id


freshTypeIdM :: RawId -> AlphaConverted UniqId
freshTypeIdM id = freshM id freshTypeId


nextIdIndex :: AlphaEnv -> Int
nextIdIndex AlphaEnv{ counter } = counter


nextIdIndexM :: AlphaConverted Int
nextIdIndexM = do
  aEnv <- get
  let next = nextIdIndex aEnv
  put $ aEnv { counter = next }
  return next


isBoundIn :: RawId -> [Frame] -> (Frame -> RawIdEnv AlphaEntry) -> Bool
isBoundIn id [] _ = False
isBoundIn id (frame : frames) getEnv =
  case Map.lookup id (getEnv frame) of
    Just anEntry -> True
    _ -> isBoundIn id frames getEnv


lookupEntryIn :: RawId -> [Frame] -> (Frame -> RawIdEnv AlphaEntry) -> AlphaConverted AlphaEntry
lookupEntryIn id [] _ = throwError $ ErrUnboundRawIdentifier id
lookupEntryIn id (frame : frames) getEnv =
  case Map.lookup id (getEnv frame) of
    Just anEntry -> return anEntry
    _ -> lookupEntryIn id frames getEnv


lookupVarIn :: RawId -> [Frame] -> AlphaConverted UniqId
lookupVarIn id frames = do
  entry <- lookupEntryIn id frames varIdEnv
  case entry of
    UniqIdEntry uid -> return uid
    FrameEntry uid _ -> return uid


lookupEntry :: RawId -> (Frame -> RawIdEnv AlphaEntry) -> AlphaConverted AlphaEntry
lookupEntry id fGetEnv = do
  aEnv <- get
  lookupEntryIn id (stack aEnv) fGetEnv


lookupVarEntry :: RawId -> AlphaConverted AlphaEntry
lookupVarEntry id = lookupEntry id varIdEnv


lookupTypeEntry :: RawId -> AlphaConverted AlphaEntry
lookupTypeEntry id = lookupEntry id typeIdEnv


lookupVarId :: RawId -> AlphaConverted UniqId
lookupVarId id = do
  entry <- lookupVarEntry id
  return $ case entry of
    UniqIdEntry uid -> uid
    FrameEntry uid _ -> uid


lookupTypeId :: RawId -> AlphaConverted UniqId
lookupTypeId id = do
  (UniqIdEntry uid) <- lookupTypeEntry id
  return uid


convertBin  :: (SourcePos -> UniqAst Exp -> UniqAst Exp -> UniqAst Exp)
            -> SourcePos
            -> RawAst Exp
            -> RawAst Exp
            -> AlphaConverted (UniqAst Exp)
convertBin c p a b = do
  a' <- convert a
  b' <- convert b
  return $ c p a' b'


lookupVarQualId :: RawAst QualifiedId -> AlphaConverted AlphaEntry
lookupVarQualId (Id p id) = lookupVarEntry id
lookupVarQualId (Path p qid id) = do
  entry <- lookupVarQualId qid
  case entry of
    UniqIdEntry _ -> throwError (ErrInvalidRawModulePath qid) `reportErrorAt` p
    FrameEntry _ frame -> lookupEntryIn id [frame] varIdEnv


lookupTypeQualId :: RawAst QualifiedId -> AlphaConverted AlphaEntry
lookupTypeQualId (Id p id) = lookupTypeEntry id
lookupTypeQualId (Path p qid id) = do
  table <- lookupVarQualId qid
  case table of
    UniqIdEntry _ -> throwError (ErrInvalidRawModulePath qid) `reportErrorAt` p
    FrameEntry _ frame -> lookupEntryIn id [frame] typeIdEnv


-- |Find the environment for the module at the base path of the given
-- qualified ID.  If it's not a path, just return the current
-- frame.
baseFrame :: RawAst QualifiedId -> AlphaConverted Frame
baseFrame (Id{}) = gets $ head . stack
baseFrame (Path _ qid _) = do
  (FrameEntry _ frame) <- lookupVarQualId qid
  return frame


convertVarQualId :: RawAst QualifiedId -> AlphaConverted (UniqAst QualifiedId)
convertVarQualId qid = do
    (UniqIdEntry uid) <- lookupVarQualId qid
    return $ Id p uid
  where p = nodeData qid


convertTypeQualId :: RawAst QualifiedId -> AlphaConverted (UniqAst QualifiedId)
convertTypeQualId qid = do
    (UniqIdEntry uid) <- lookupTypeQualId qid
    return $ Id p uid
  where p = nodeData qid


convertTyAnn :: RawAst TyAnn -> AlphaConverted (UniqAst TyAnn)
convertTyAnn (TyAnn p id tyParamIds ty) = do
  id' <- freshVarIdM id
  tyParamIds' <- mapM freshTypeIdM tyParamIds
  ty' <- convertTy ty
  return $ TyAnn p id' tyParamIds' ty'


convertTy :: RawAst SynTy -> AlphaConverted (UniqAst SynTy)
convertTy (SynTyInt p) = return $ SynTyInt p
convertTy (SynTyBool p) = return $ SynTyBool p
convertTy (SynTyChar p) = return $ SynTyChar p
convertTy (SynTyUnit p) = return $ SynTyUnit p
convertTy (SynTyArrow p paramTys retTy) = do
  paramTys' <- mapM convertTy paramTys `reportErrorAt` p
  retTy' <- convertTy retTy
  return $ SynTyArrow p paramTys' retTy'

convertTy (SynTyModule p paramTys maybeImplTy) = do
  paramTys' <- mapM convertTy paramTys
  case maybeImplTy of
    Just ty -> do
      implTy' <- convertTy ty
      return $ SynTyModule p paramTys' $ Just implTy'
    _ ->
      return $ SynTyModule p paramTys' Nothing

convertTy (SynTyInterface p paramIds) = do
  paramIds' <- mapM freshTypeIdM paramIds
  return $ SynTyInterface p paramIds'

convertTy (SynTyDefault p qid tyArgs) = do
  qid' <- convertTypeQualId qid
  tyArgs' <- mapM convertTy tyArgs
  return $ SynTyDefault p qid' tyArgs'

convertTy (SynTyStruct p fields) = do
  fields' <- mapM (\(id, ty) -> do { ty' <- convertTy ty; return (UserId id, ty') }) fields
  return $ SynTyStruct p fields'

convertTy (SynTyTuple p tys) = do
  tys' <- mapM convertTy tys
  return $ SynTyTuple p tys'

convertTy (SynTyList p ty) = do
  ty' <- convertTy ty
  return $ SynTyList p ty'

convertTy (SynTyRef p qid tyArgs) = do
  tyArgs' <- mapM convertTy tyArgs
  qid' <- convertTypeQualId qid `reportErrorAt` p
  return $ SynTyRef p qid' tyArgs'


convertAdtAlternative :: Int -> RawAst AdtAlternative -> AlphaConverted (UniqAst AdtAlternative)
convertAdtAlternative index (AdtAlternative p id _ tys) = do
  id' <- freshVarIdM id
  tys' <- mapM convertTy tys
  return $ AdtAlternative p id' index tys'


convertPatExp :: RawAst PatExp -> AlphaConverted (UniqAst PatExp)
convertPatExp (PatExpWildcard p) = return $ PatExpWildcard p
convertPatExp (PatExpNumLiteral p s) = return $ PatExpNumLiteral p s
convertPatExp (PatExpBoolLiteral p b) = return $ PatExpBoolLiteral p b
convertPatExp (PatExpStringLiteral p s) = return $ PatExpStringLiteral p s
convertPatExp (PatExpCharLiteral p s) = return $ PatExpCharLiteral p s
convertPatExp (PatExpTuple p es) = do
  es' <- mapM convertPatExp es
  return $ PatExpTuple p es'

convertPatExp (PatExpId p id) = do
  id' <- freshVarIdIfNotBoundM id `reportErrorAt` p
  return $ PatExpId p id'

convertPatExp (PatExpAdt p qid es) = do
  qid' <- convertVarQualId qid `reportErrorAt` nodeData qid
  es' <- mapM convertPatExp es
  return $ PatExpAdt p qid' es'

convertPatExp (PatExpList p es) = do
  es' <- mapM convertPatExp es
  return $ PatExpList p es'

convertPatExp (PatExpListCons p eHd eTl) = do
  eHd' <- convertPatExp eHd
  eTl' <- convertPatExp eTl
  return $ PatExpListCons p eHd' eTl'


convertFunDef :: RawAst FunDef -> AlphaConverted (UniqAst FunDef)
convertFunDef (FunDefFun p id argPatEs bodyEs) = do
  argPatEs' <- mapM convertPatExp argPatEs
  id' <- lookupVarId id
  bodyEs' <- mapM convert bodyEs
  return $ FunDefFun p id' argPatEs' bodyEs'

convertFunDef (FunDefInstFun p instPatE id argPatEs bodyEs) = do
  instPatE' <- convertPatExp instPatE
  argPatEs' <- mapM convertPatExp argPatEs
  id' <- freshVarIdM id
  bodyEs' <- mapM convert bodyEs
  return $ FunDefInstFun p instPatE' id' argPatEs' bodyEs'


convertCaseClause :: RawAst CaseClause -> AlphaConverted (UniqAst CaseClause)
convertCaseClause (CaseClause p patE es) = do
  pushFrame
  patE' <- convertPatExp patE
  es' <- mapM convert es
  popFrame
  return $ CaseClause p patE' es'


funDefToCaseClause :: RawAst FunDef -> AlphaConverted (UniqAst CaseClause)
funDefToCaseClause (FunDefFun p _ argPatEs bodyEs) = do
  let tupPat = PatExpTuple p argPatEs
  pushFrame
  tupPat' <- convertPatExp tupPat
  bodyEs' <- mapM convert bodyEs
  popFrame
  return $ CaseClause p tupPat' bodyEs'

funDefToCaseClause (FunDefInstFun p instPatE _ argPatEs bodyEs) = do
  let tupPat = PatExpTuple p $ instPatE : argPatEs
  pushFrame
  tupPat' <- convertPatExp tupPat
  bodyEs' <- mapM convert bodyEs
  popFrame
  return $ CaseClause p tupPat' bodyEs'


-- The rule is as follows (with this particular
-- example for a 3-arity function):
-- F1 (P11, P12, P13) --> BODY1
-- F2 (P21, P22, P23) --> BODY2
--
-- ==>
--
-- F(ID1, ID2, ID3) {
--   switch ((ID1, ID2, ID3)) {
--     case (P11, P12, P13) -> BODY1'
--     case (P21, P22, P23) -> BODY2'
--   }
-- }
--
-- where:
--    * ID1, ID2, ID3 are all (fresh) unique identifiers
--      not already occurring in the environment.
--    * BODY1' = alphaConvert BODY1 (alphaEnv + ID1, ID2, ID3)
--    * BODY2' = alphaConvert BODY2 (alphaEnv + ID1, ID2, ID3)
funDefArity :: RawAst FunDef -> Int
funDefArity (FunDefFun _ _ patEs _) = length patEs
funDefArity (FunDefInstFun _ _ _ patEs _) = length patEs


desugarFunDefs :: UniqId -> [RawAst FunDef] -> AlphaConverted (UniqAst FunDef, [UniqId])
desugarFunDefs fid funDefs =
  let arities = nub $ map funDefArity funDefs
      headFunDef = head funDefs
      startP = nodeData headFunDef
  in
    case arities of
      [len] -> do
        paramIds <- replicateM len ((\_ -> freshVarIdM "arg") ())
        cases <- mapM funDefToCaseClause funDefs
        let paramRefs = map (ExpRef startP) paramIds
            paramPats = map (PatExpId startP) paramIds
        case headFunDef of
          FunDefFun _ _ argPatEs bodyEs ->
            let argsTup = ExpTuple startP paramRefs
            in
              return (FunDefFun startP fid paramPats [ExpSwitch startP argsTup cases], paramIds)
          FunDefInstFun _ instPatE _ argPatEs bodyEs ->
            do instId <- freshVarIdM "this"
               let instRef = ExpRef startP instId
                   argsTup = ExpTuple startP (instRef : paramRefs)
               return (FunDefInstFun startP (PatExpId startP instId) fid paramPats [ExpSwitch startP argsTup cases], paramIds)
      _ ->
        throwError $ ErrFunDefArityMismatch fid


-- cond {
--   test1 -> es1
--   test2 -> es2
--   _ -> es3
-- }
--
-- ==>
--
-- if (test1) {
--   es1
-- } else (
--   if (test2) {
--     es2
--   } else (
--     if (True) {
--       es3
--     } else {
--       fail("Inexhaustive cond")
--     }))
desugarCondClause :: RawAst CondCaseClause -> (RawAst Exp, [RawAst Exp])
desugarCondClause (CondCaseClause _ testE bodyEs) = (testE, bodyEs)
desugarCondClause (CondCaseClauseWildcard p bodyEs) = (ExpBool p True, bodyEs)


desugarCondClauses :: SourcePos -> [RawAst CondCaseClause] -> RawAst Exp
desugarCondClauses p (clause:clauses) =
  let (testE, bodyEs) = desugarCondClause clause
      elseEs = case clauses of
                 [] -> [ExpFail p "Inexhaustive cond expression"]
                 _ -> [desugarCondClauses p clauses]
  in
    ExpIfElse (nodeData testE) testE bodyEs elseEs


desugarCond :: RawAst Exp -> RawAst Exp
desugarCond (ExpCond p clauses) = desugarCondClauses p clauses


convert :: RawAst Exp -> AlphaConverted (UniqAst Exp)
convert (ExpAdd p a b) = convertBin ExpAdd p a b
convert (ExpSub p a b) = convertBin ExpSub p a b
convert (ExpDiv p a b) = convertBin ExpDiv p a b
convert (ExpMul p a b) = convertBin ExpMul p a b
convert (ExpCons p a b) = convertBin ExpCons p a b
convert (ExpCustomInfix p lhe id rhe) = do
  lhe' <- convert lhe
  rhe' <- convert rhe
  id' <- lookupVarId id
  return $ ExpCustomInfix p lhe' id' rhe'

convert (ExpMemberAccess p e id) = do
  e' <- convert e
  return $ ExpMemberAccess p e' (UserId id)

convert (ExpApp p ratorE randEs) = do
  ratorE' <- convert ratorE
  randEs' <- mapM convert randEs
  return $ ExpApp p ratorE' randEs'

convert (ExpImport p qid) = do
  (FrameEntry moduleId Frame{ varIdEnv = modVarIdEnv, typeIdEnv = modTypeIdEnv }) <- lookupVarQualId qid
  modifyFrame (\(curFrame@Frame{ varIdEnv, typeIdEnv }) ->
                  curFrame { varIdEnv = Map.union varIdEnv modVarIdEnv
                           , typeIdEnv = Map.union typeIdEnv modTypeIdEnv })
  return $ ExpUnit p

convert (ExpFunDef (FunDefFun p id argPatEs bodyEs)) = do
  id' <- freshVarIdM id
  pushFrame
  argPatEs' <- mapM convertPatExp argPatEs
  bodyEs' <- mapM convert bodyEs
  popFrame
  return $ ExpFunDef $ FunDefFun p id' argPatEs' bodyEs'

convert (ExpFunDef (FunDefInstFun p instPatE id argPatEs bodyEs)) = do
  id' <- freshVarIdM id
  instPatE' <- convertPatExp instPatE
  argPatEs' <- mapM convertPatExp argPatEs
  bodyEs' <- mapM convert bodyEs
  return $ ExpFunDef $ FunDefInstFun p instPatE' id' argPatEs' bodyEs'

convert (ExpFunDefClauses p id funDefs) = do
  id' <- freshVarIdM id
  pushFrame
  funDef <- fst <$> desugarFunDefs id' funDefs
  popFrame
  return $ ExpFunDef funDef

convert (ExpAssign p (PatExpId pp rawId) (ExpModule mp paramIds bodyEs)) = do
  pushFrame
  bodyEs' <- mapM convert bodyEs
  id' <- freshM rawId freshVarId
  moduleFrame <- popFrame
  bindInCurrentFrame rawId $ FrameEntry id' moduleFrame
  return $ ExpBegin p bodyEs'

convert (ExpAssign p patExp e) = do
  e' <- convert e
  patExp' <- convertPatExp patExp
  return $ ExpAssign p patExp' e'

convert (ExpTypeDec p (TypeDecTy pInner id tyParamIds (SynTyStruct stp fields))) = do
  id' <- freshTypeIdM id
  tyParamIds' <- mapM freshTypeIdM tyParamIds
  fields' <- mapM (\(id, ty) -> do id' <- freshM id freshVarId
                                   ty' <- convertTy ty
                                   return (id', ty'))
                  fields
  return $ ExpTypeDec p $ TypeDecTy pInner id' tyParamIds' $ SynTyStruct p fields'

convert (ExpTypeDec p (TypeDecTy pInner id tyParamIds ty)) = do
  id' <- freshTypeIdM id
  tyParamIds' <- mapM freshTypeIdM tyParamIds
  ty' <- convertTy ty
  return $ ExpTypeDec p $ TypeDecTy pInner id' tyParamIds' ty'

convert (ExpTypeDec p (TypeDecAdt pInner id tyParamIds alts)) = do
  id' <- freshTypeIdM id
  tyParamIds' <- mapM freshTypeIdM tyParamIds
  alts' <- mapMi convertAdtAlternative alts
  return $ ExpTypeDec p $ TypeDecAdt pInner id' tyParamIds' alts'

convert (ExpTyAnn (TyAnn _ id _ _)) =
  throwError $ ErrInterpFailure $ "ExpTyAnn " ++ show id ++ " not removed before alpha-conversion!"

convert (ExpWithAnn (TyAnn p aid tyParamIds synTy) e) = do
  aid' <- freshVarIdM aid
  tyParamIds' <- mapM freshTypeIdM tyParamIds
  synTy' <- convertTy synTy
  let tyAnn = TyAnn p aid' tyParamIds' synTy'
  case e of
    ExpFunDef (FunDefFun fp fid argPatEs bodyEs) ->
      do pushFrame
         argPatEs' <- mapM convertPatExp argPatEs
         bodyEs' <- mapM convert bodyEs
         popFrame
         let e' = ExpFunDef (FunDefFun fp aid' argPatEs' bodyEs')
         return $ ExpWithAnn tyAnn e'
    ExpFunDefClauses p id funDefs ->
      do pushFrame
         funDef <- fst <$> desugarFunDefs aid' funDefs
         popFrame
         return $ ExpWithAnn tyAnn $ ExpFunDef funDef
    ExpAssign ep (PatExpId pp pid) e ->
      do e' <- convert e
         return $ ExpWithAnn tyAnn $ ExpAssign ep (PatExpId pp aid') e'
    _ -> throwError $ ErrInterpFailure $ "in convert ExpWithAnn: " ++ show e

convert (ExpInterfaceDec p id tyParamIds memberTyAnns) = do
  id' <- freshTypeIdM id
  tyParamIds' <- mapM freshTypeIdM tyParamIds
  memberTyAnns' <- mapM convertTyAnn memberTyAnns
  return $ ExpInterfaceDec p id' tyParamIds' memberTyAnns'

convert (ExpModule p paramIds bodyEs) = do
  paramIds' <- mapM freshVarIdM paramIds
  bodyEs' <- mapM convert bodyEs
  return $ ExpModule p paramIds' bodyEs'

convert (ExpStruct p qid fields) = do
  definitionFrame <- baseFrame qid
  qid' <- convertTypeQualId qid `reportErrorAt` nodeData qid
  fields' <- mapM (\(fieldId, fieldE) ->
                      do fieldE' <- convert fieldE
                         fieldId' <- lookupVarIn fieldId [definitionFrame]
                         return (fieldId', fieldE'))
                  fields
  return $ ExpStruct p qid' fields'


convert (ExpIfElse p condE thenEs elseEs) = do
  condE' <- convert condE
  thenEs' <- inNewFrame $ mapM convert thenEs
  elseEs' <- inNewFrame $ mapM convert elseEs
  return $ ExpIfElse p condE' thenEs' elseEs'

convert (ExpSwitch p e clauses) = do
  e' <- convert e
  clauses' <- mapM convertCaseClause clauses
  return $ ExpSwitch p e' clauses'

convert e@(ExpCond _ clauses) = convert $ desugarCond e

convert (ExpTuple p es) = do
  es' <- mapM convert es
  return $ ExpTuple p es'

convert (ExpList p es) = do
  es' <- mapM convert es
  return $ ExpList p es'

convert (ExpFun p argPatEs bodyEs) = do
  pushFrame
  argPatEs' <- mapM convertPatExp argPatEs
  bodyEs' <- mapM convert bodyEs
  popFrame
  return $ ExpFun p argPatEs' bodyEs'

convert (ExpPrecAssign p id level) = do
  id' <- lookupVarId id
  return $ ExpPrecAssign p id' level

convert (ExpNum p s) = return $ ExpNum p s
convert (ExpBool p b) = return $ ExpBool p b
convert (ExpString p s) = return $ ExpString p s
convert (ExpChar p s) = return $ ExpChar p s
convert (ExpUnit p) = return $ ExpUnit p
convert (ExpFail p msg) = return $ ExpFail p msg

convert (ExpQualifiedRef p (Id _ id)) = convert (ExpRef p id)
convert (ExpQualifiedRef p (Path pp qid id)) = do
  entry <- lookupVarQualId qid `reportErrorAt` pp
  case entry of
    UniqIdEntry uid -> return $ ExpMemberAccess p (ExpRef pp uid) $ UserId id
    FrameEntry _ frame -> do
      memberUid <- lookupVarIn id [frame] `reportErrorAt` pp
      return $ ExpRef p memberUid

convert (ExpRef p id) = do
  id' <- lookupVarId id `reportErrorAt` p
  return $ ExpRef p id'


collectFunDefs :: RawId -> [RawAst Exp] -> ([RawAst FunDef], [RawAst Exp])
collectFunDefs _ [] = ([], [])
collectFunDefs id (eFunDef@(ExpFunDef funDef@(FunDefFun _ fid _ _)) : es)
  | id == fid =
    let (funDefs, es') = collectFunDefs id es
    in (funDef : funDefs, es')
  | otherwise = ([], eFunDef : es)

collectFunDefs _ es = ([], es)


collectInstFunDefs :: RawId -> [RawAst Exp] -> ([RawAst FunDef], [RawAst Exp])
collectInstFunDefs _ [] = ([], [])
collectInstFunDefs id (eFunDef@(ExpFunDef funDef@(FunDefInstFun _ _ fid _ _)) : es)
  | id == fid =
    let (funDefs, es') = collectInstFunDefs id es
    in (funDef : funDefs, es')
  | otherwise = ([], eFunDef : es)

collectInstFunDefs _ es = ([], es)


collapseBindingExp :: RawId -> [RawAst Exp] -> Either Err (RawAst Exp, [RawAst Exp])
collapseBindingExp id (e@(ExpAssign _ (PatExpId _ pid) _) : es)
  | id == pid = return (e, es)
  | otherwise = throwError $ ErrNoBindingAfterTyAnn id

collapseBindingExp id _ = throwError $ ErrNoBindingAfterTyAnn id


collapseEs :: [RawAst Exp] -> Either Err [RawAst Exp]
collapseEs [] = return []
collapseEs (ExpTyAnn tyAnn@(TyAnn ap aid _ synTy) : es) =
  case synTy of
    SynTyArrow {} ->
      let (funDefs, es') = collectFunDefs aid es
          eFunDef = ExpFunDefClauses ap aid funDefs
      in if null funDefs
           then throwError $ ErrNoBindingAfterTyAnn aid
           else do es'' <- collapseEs es'
                   return (ExpWithAnn tyAnn eFunDef : es'')
    _ ->
      do (e, es') <- collapseBindingExp aid es
         es'' <- collapseEs es'
         return (ExpWithAnn tyAnn e : es'')

collapseEs (ExpFunDef (FunDefFun p fid argPatEs bodyEs) : es) = do
  bodyEs' <- collapseEs bodyEs
  let (funDefs, es') = collectFunDefs fid es
      funDef = FunDefFun p fid argPatEs bodyEs'
      eFunDef = ExpFunDefClauses p fid (funDef : funDefs)
  es'' <- collapseEs es'
  return (eFunDef : es'')

collapseEs (ExpFunDef (FunDefInstFun p instPatE fid argPatEs bodyEs) : es) = do
  bodyEs' <- collapseEs bodyEs
  let (funDefs, es') = collectInstFunDefs fid es
      funDef = FunDefInstFun p instPatE fid argPatEs bodyEs'
      eFunDef = ExpFunDefClauses p fid (funDef : funDefs)
  es'' <- collapseEs es'
  return (eFunDef : es'')

collapseEs (e : es) = do
  e' <- collapse e
  es' <- collapseEs es
  return (e' : es')


collapse :: RawAst Exp -> Either Err (RawAst Exp)
collapse (ExpAssign p patE e) = do
  e' <- collapse e
  return $ ExpAssign p patE e'

collapse (ExpFunDef (FunDefFun p id argPatEs bodyEs)) = do
  bodyEs' <- collapseEs bodyEs
  return $ ExpFunDef $ FunDefFun p id argPatEs bodyEs'

collapse (ExpModule p paramIds bodyEs) = do
  bodyEs' <- collapseEs bodyEs
  return $ ExpModule p paramIds bodyEs'

collapse e = return e


alphaConvert :: RawAst CompUnit -> Either Err (UniqAst CompUnit, AlphaEnv)
alphaConvert (CompUnit pos exps) = do
  collapsedEs <- collapseEs exps
  let (eithExps, alphaEnv) = runState (runExceptT $ mapM convert collapsedEs) mtAlphaEnv
  exps' <- eithExps
  return (CompUnit pos exps', alphaEnv)
