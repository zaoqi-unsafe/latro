{-# LANGUAGE DeriveGeneric, TypeSynonymInstances #-}
module Latro.Semant where

import Data.List (intersperse)
import qualified Data.Map as Map
import Latro.Ast
import Text.PrettyPrint.GenericPretty
import Text.Printf (printf)



class ILNode a where
  ilNodeData :: a b -> b
data ILFieldInit a = ILFieldInit UniqId (IL a)
  deriving (Eq, Show)


data ILCase a = ILCase a (ILPat a) (IL a)
  deriving (Eq, Show)


data ILPat a =
    ILPatInt a Int
  | ILPatBool a Bool
  | ILPatStr a String
  | ILPatChar a String
  | ILPatTuple a [ILPat a]
  | ILPatAdt a UniqId [ILPat a]
  | ILPatList a [ILPat a]
  | ILPatCons a (ILPat a) (ILPat a)
  | ILPatId a UniqId
  | ILPatWildcard a
  deriving (Eq, Show)


instance ILNode ILPat where
  ilNodeData ilPat =
    case ilPat of
      ILPatInt d _ -> d
      ILPatBool d _ -> d
      ILPatStr d _ -> d
      ILPatChar d _ -> d
      ILPatTuple d _ -> d
      ILPatAdt d _ _ -> d
      ILPatList d _ -> d
      ILPatCons d _ _ -> d
      ILPatId d _ -> d
      ILPatWildcard d -> d


data Prim =
    PrimPrintln
  | PrimReadln
  | PrimCharEq
  | PrimCharToInt
  | PrimIntAdd
  | PrimIntSub
  | PrimIntDiv
  | PrimIntMul
  | PrimIntMod
  | PrimIntEq
  | PrimIntLt
  | PrimIntLeq
  | PrimIntGt
  | PrimIntGeq
  | PrimUnknown RawId
  deriving (Eq, Show)


data IL a =
    ILCons a (IL a) (IL a)
  | ILApp a (IL a) [IL a]
  | ILPrim a Prim
  | ILAssign a (ILPat a) (IL a)
  | ILProtoDec a UniqId UniqId [Constraint a UniqId] [TyAnn a UniqId]
  | ILProtoImp a (SynTy a UniqId) UniqId [Constraint a UniqId] [IL a]
  | ILWithAnn a (TyAnn a UniqId) (IL a)
  | ILFunDef a UniqId [UniqId] (IL a)
  | ILStruct a UniqId [ILFieldInit a]
  | ILMakeAdt a UniqId Int [IL a]
  | ILGetAdtField a (IL a) Int
  | ILTuple a [IL a]
  | ILSwitch a (IL a) [ILCase a]
  | ILList a [IL a]
  | ILFun a [UniqId] (IL a)
  | ILInt a Int
  | ILBool a Bool
  | ILStr a String
  | ILChar a String
  | ILUnit a
  | ILRef a UniqId
  | ILBegin a [IL a]
  | ILFail a String
  | ILMain a [UniqId] (IL a)
  deriving (Eq, Show)


instance ILNode IL where
  ilNodeData il =
    case il of
      ILCons d _ _ -> d
      ILApp d _ _ -> d
      ILPrim d _ -> d
      ILAssign d _ _ -> d
      ILProtoDec d _ _ _ _ -> d
      ILProtoImp d _ _ _ _ -> d
      ILWithAnn d _ _ -> d
      ILFunDef d _ _ _ -> d
      ILStruct d _ _ -> d
      ILMakeAdt d _ _ _ -> d
      ILGetAdtField d _ _ -> d
      ILTuple d _ -> d
      ILSwitch d _ _ -> d
      ILList d _ -> d
      ILFun d _ _ -> d
      ILInt d _ -> d
      ILBool d _ -> d
      ILStr d _ -> d
      ILChar d _ -> d
      ILUnit d -> d
      ILRef d _ -> d
      ILBegin d _ -> d
      ILFail d _ -> d
      ILMain d _ _ -> d


data ILCompUnit a = ILCompUnit a [TypeDec a UniqId] [IL a]
  deriving (Eq, Show)
type RawIdEnv a = Map.Map RawId a
type UniqIdEnv a = Map.Map UniqId a
type QualIdEnv v = Map.Map (UniqAst QualifiedId) v
type Env a = Map.Map UniqId a
type CloEnv a = Env a
type VEnv = Env Value
type TEnv = Env Ty


mtRawIdEnv :: RawIdEnv a
mtRawIdEnv = Map.empty

mtUniqIdEnv :: UniqIdEnv a
mtUniqIdEnv = Map.empty

mtEnv :: Env a
mtEnv = Map.empty


lookupUniqId :: UniqId -> RawIdEnv UniqId -> Maybe UniqId
lookupUniqId uid@UniqId{} _ = Just uid
lookupUniqId (UserId rawId) map = Map.lookup rawId map

data CheckedData = OfTy SourcePos Ty
  deriving (Eq, Show)


type TypedAst a = a CheckedData UniqId

type UntypedUniq a = a SourcePos UniqId
type Untyped a = a SourcePos
type Typed a = a CheckedData


data Exports = Exports
  { exportTypes :: TEnv
  , exportVars :: VEnv
  }
  deriving (Eq, Show)


-- A module value has two environments:
-- A closure environment, and an export
-- environment.  A name lookup on a module
-- can't search the closure environment, so we
-- separate them
data Module = Module (CloEnv Value) [UniqId] Exports
  deriving (Eq, Show)


data Closure = Closure UniqId Ty (CloEnv Value) [UniqId] (Typed IL)
  deriving (Eq, Show)


data Struct = Struct Ty [(UniqId, Value)]
  deriving (Eq, Show)


data Adt = Adt UniqId Int [Value]
  deriving (Eq, Show)


data Value =
    ValueInt Int
  | ValueBool Bool
  | ValueChar Char
  | ValueModule Module
  | ValueFun Closure
  | ValueStruct Struct
  | ValueAdt Adt
  | ValueTuple [Value]
  | ValueList [Value]
  | ValueUnit
  | ValuePrim Prim
  | ValueThunk (Typed IL)
  | Err String
  deriving (Eq)


instance Show Value where
  show v =
    case v of
      ValueInt i -> show i
      ValueBool b -> show b
      ValueChar c -> printf "'%c'" c
      ValueFun (Closure fid fty _ paramIds _) -> printf "fun %s : %s" (show fid) (show fty)
      ValueStruct struct -> "struct"
      ValueAdt (Adt uid i vs) ->
        printf "%s(%s)" (show uid) (concat . intersperse ", " $ map show vs)
      ValueTuple vs -> printf "%%(%s)" $ concat . intersperse ", " $ map show vs
      ValueList vs@((ValueChar c) : _) ->
        let str = map (\(ValueChar c) -> c) vs
        in show str
      ValueList vs -> printf "[%s]" $ concat . intersperse ", " $ map show vs
      ValueUnit -> "Unit"
      ValuePrim prim -> "prim"
      Err str -> "Error = " ++ str


type ProtocolId = UniqId
type MethodId = UniqId
type TyVarId = UniqId
type FieldName = UniqId
type CtorName = UniqId


data Protocol = Protocol ProtocolId TyVarId [MethodId]
  deriving (Eq, Show)


-- data Imp = Imp TyCon Protocol
--   deriving (Eq, Show)


data ImpDictValue a =
    ImpDictValueFun [UniqId] (IL a)
  | ImpDictValueSuperDict (ImpDictValue a)
  deriving (Eq, Show)


type ImpDict a = Map.Map UniqId (ImpDictValue a)


data TyConstraint = TyConstraint ProtocolId
  deriving (Eq, Generic, Ord)


instance Out TyConstraint
instance Show TyConstraint where
  show = pretty


data Ty =
    TyApp TyCon [Ty]
  | TyPoly [TyVarId] Ty
  | TyVar TyVarId
  | TyMeta TyVarId
  | TyRef (QualifiedId SourcePos UniqId) -- Only for recursive type definitions
  | TyScheme Ty [TyConstraint]
  | TyOverloaded [(UniqId, ProtocolId)] Ty
  deriving Generic


instance Eq Ty where
  (TyApp tyConA tyAs) == (TyApp tyConB tyBs) =
    tyConA == tyConB && tyAs == tyBs
  (TyPoly aVars tyA) == (TyPoly bVars tyB) =
    tyA == tyB
  (TyVar idA) == (TyVar idB) = idA == idB
  (TyMeta idA) == (TyMeta idB) = idA == idB
  (TyRef idA) == (TyRef idB) = idA == idB
  (TyScheme tyA _) == (TyScheme tyB _) = tyA == tyB
  _ == _ = False


instance Out Ty
instance Show Ty where
  show = pretty


-- instance Show Ty where
--   show (TyApp tyCon []) = show tyCon
--   show (TyApp TyConArrow tyArgs) = concat . intersperse " -> " $ map show tyArgs
--   show (TyApp tyCon tyArgs) = printf "%s{%s}" (show tyCon) (concat . intersperse ", " $ map show tyArgs)
--   show (TyPoly [] ty) = show ty
--   show (TyPoly tyParams ty) = printf "{%s} %s" (concat . intersperse ", " $ map show tyParams) (show ty)
--   show (TyVar id) = show id
--   show (TyMeta id) = show id
--   show (TyRef qid) = show qid


data ModuleBinding =
    ModuleBindingTyCon FieldName TyCon
  | ModuleBindingTy FieldName Ty
  deriving (Eq, Show)


data TyCon =
    TyConInt
  | TyConBool
  | TyConChar
  | TyConUnit
  | TyConList
  | TyConTuple
  | TyConArrow
  | TyConStruct [FieldName]
  | TyConAdt [CtorName]
  | TyConTyFun [TyVarId] Ty
  | TyConUnique UniqId TyCon
  | TyConTyVar TyVarId -- In the body of a tyfun/poly
  | TyConTyScheme TyCon [TyConstraint] -- In the body of a protocol dec
  deriving Generic


ordIndex :: TyCon -> Int
ordIndex tyCon =
  case tyCon of
    TyConInt -> 0
    TyConBool -> 1
    TyConChar -> 2
    TyConUnit -> 3
    TyConList -> 4
    TyConTuple -> 5
    TyConArrow -> 6
    TyConStruct _ -> 7
    TyConAdt _ -> 8
    TyConTyFun _ _ -> 9
    TyConUnique _ _ -> 10
    TyConTyVar _ -> 11
    TyConTyScheme tyCon _ -> ordIndex tyCon


instance Ord TyCon where
  TyConUnique idA _ <= TyConUnique idB _ = idA <= idB
  TyConTyVar idA <= TyConTyVar idB = idA <= idB
  a <= b = ordIndex a <= ordIndex b


instance Eq TyCon where
  TyConInt == TyConInt = True
  TyConBool == TyConBool = True
  TyConChar == TyConChar = True
  TyConUnit == TyConUnit = True
  TyConList == TyConList = True
  TyConTuple == TyConTuple = True
  TyConArrow == TyConArrow = True
  TyConUnique ida _ == TyConUnique idb _ = ida == idb
  TyConTyVar ida == TyConTyVar idb = ida == idb
  TyConTyScheme tyConA _ == TyConTyScheme tyConB _ = tyConA == tyConB
  _ == _ = False


instance Out TyCon
instance Show TyCon where
  show = pretty


-- instance Show TyCon where
--   show TyConInt = "Int"
--   show TyConBool = "Bool"
--   show TyConChar = "Char"
--   show TyConUnit = "Unit"
--   show TyConList = "[]"
--   show TyConTuple = "(,)"
--   show (TyConUnique id _) = show id
--   show (TyConTyFun [] ty) = show ty
