module Syntax where

import Data.List

type RawId = String

data QualifiedId id =
    Id id
  | Path (QualifiedId id) id
  deriving (Eq, Show)

data CompUnit id = CompUnit [Exp id]
  deriving (Eq, Show)

data PatExp id =
    PatExpNumLiteral String
  | PatExpBoolLiteral Bool
  | PatExpTuple [PatExp id]
  | PatExpAdt id [PatExp id]
  | PatExpList [PatExp id]
  | PatExpListCons (PatExp id) (PatExp id)
  | PatExpId id
  | PatExpAtom (Exp id)
  | PatExpWildcard
  deriving (Eq, Show)

data CaseClause id =
    CaseClause (PatExp id) [Exp id]
  deriving (Eq, Show)

data Exp id =
    ExpAdd (Exp id) (Exp id)
  | ExpSub (Exp id) (Exp id)
  | ExpDiv (Exp id) (Exp id)
  | ExpMul (Exp id) (Exp id)
  | ExpCons (Exp id) (Exp id)
  | ExpNot (Exp id)
  | ExpMemberAccess (Exp id) id
  | ExpApp (Exp id) [Exp id]
  | ExpImport (QualifiedId id)
  | ExpAssign (PatExp id) (Exp id)
  | ExpTypeDec (TypeDec id)
  | ExpFunDec (FunDec id)
  | ExpModule [Exp id]
  | ExpStruct (Exp id) [(id, Exp id)]
  | ExpIfElse (Exp id) [Exp id] [Exp id]
  | ExpMakeAdt (Ty id) Int [Exp id]
  | ExpTuple [Exp id]
  | ExpSwitch (Exp id) [CaseClause id]
  | ExpList [Exp id]
  | ExpFun [id] [Exp id]
  | ExpNum String
  | ExpBool Bool
  | ExpString String
  | ExpRef id
  | ExpUnit
  deriving (Eq, Show)

data TypeDec id =
    TypeDecTy id (Ty id)
  | TypeDecAdt id [AdtAlternative id]
  deriving (Eq, Show)

getTypeDecId :: TypeDec id -> id
getTypeDecId (TypeDecTy id _) = id
getTypeDecId (TypeDecAdt id _) = id

data AdtAlternative id =
    AdtAlternative id Int [Ty id]
  deriving (Eq, Show)

data Ty id =
    TyInt
  | TyBool
  | TyString
  | TyUnit
  | TyArrow [Ty id] (Ty id)
  | TyModule
  | TyInterface
  | TyStruct [(id, (Ty id))]
  | TyAdt id [AdtAlternative id]
  | TyTuple [Ty id]
  | TyList (Ty id)
  | TyRef (QualifiedId id)
  deriving (Eq, Show)

data FunDec id =
    FunDecFun id (Ty id) [FunDef id]
  | FunDecInstFun id (Ty id) (Ty id) [FunDef id]
  deriving (Eq, Show)

data FunDef id =
    FunDefFun id [PatExp id] [Exp id]
  | FunDefInstFun (PatExp id) id [PatExp id] [Exp id]
  deriving (Eq, Show)
