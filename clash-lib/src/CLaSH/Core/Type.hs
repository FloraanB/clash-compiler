{-|
  Copyright   :  (C) 2012-2016, University of Twente
  License     :  BSD2 (see the file LICENSE)
  Maintainer  :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Types in CoreHW
-}

{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ViewPatterns          #-}

{-# OPTIONS_GHC -fno-specialise #-}

module CLaSH.Core.Type
  ( Type (..)
  , TypeView (..)
  , ConstTy (..)
  , LitTy (..)
  , Kind
  , KindOrType
  , KiName
  , TyName
  , TyVar
  , tyView
  , coreView
  , transparentTy
  , typeKind
  , mkTyConTy
  , mkFunTy
  , mkTyConApp
  , splitFunTy
  , splitFunTys
  , splitFunForallTy
  , splitCoreFunForallTy
  , splitTyConAppM
  , isPolyFunTy
  , isPolyFunCoreTy
  , isPolyTy
  , isFunTy
  , applyFunTy
  , applyTy
  , findFunSubst
  , undefinedTy
  )
where

-- External import
import           Control.DeepSeq                         as DS
import           Control.Monad                           (zipWithM)
import           Data.HashMap.Strict                     (HashMap)
import qualified Data.HashMap.Strict                     as HashMap
import           Data.Maybe                              (isJust)
import           GHC.Generics                            (Generic(..))
import           Unbound.Generics.LocallyNameless        (Alpha(..),Bind,Fresh,
                                                          Subst(..),SubstName(..),
                                                          acompare,aeq,bind,embed,
                                                          gacompare,gaeq,gfvAny,
                                                          runFreshM,unbind)
import           Unbound.Generics.LocallyNameless.Name   (Name,name2String,
                                                          string2Name)
import           Unbound.Generics.LocallyNameless.Extra  ()
import           Unbound.Generics.LocallyNameless.Unsafe (unsafeUnbind)

-- Local imports
import           CLaSH.Core.Subst
import {-# SOURCE #-} CLaSH.Core.Term
import           CLaSH.Core.TyCon
import           CLaSH.Core.TysPrim
import           CLaSH.Core.Var
import           CLaSH.Util

-- | Types in CoreHW: function and polymorphic types
data Type
  = VarTy    !Kind !TyName      -- ^ Type variable
  | ConstTy  !ConstTy           -- ^ Type constant
  | ForAllTy !(Bind TyVar Type) -- ^ Polymorphic Type
  | AppTy    !Type !Type        -- ^ Type Application
  | LitTy    !LitTy             -- ^ Type literal
  deriving (Show,Generic,NFData)

-- | An easier view on types
data TypeView
  = FunTy    !Type  !Type      -- ^ Function type
  | TyConApp !TyConName [Type] -- ^ Applied TyCon
  | OtherType !Type            -- ^ Neither of the above
  deriving Show

-- | Type Constants
data ConstTy
  = TyCon !TyConName -- ^ TyCon type
  | Arrow            -- ^ Function type
  deriving (Show,Generic,NFData,Alpha)

-- | Literal Types
data LitTy
  = NumTy !Integer
  | SymTy !String
  deriving (Show,Generic,NFData,Alpha)

-- | The level above types
type Kind       = Type
-- | Either a Kind or a Type
type KindOrType = Type

-- | Reference to a Type
type TyName     = Name Type
-- | Reference to a Kind
type KiName     = Name Kind

instance Alpha Type where
  fvAny' c nfn (VarTy t n) = fmap (VarTy t) $ fvAny' c nfn n
  fvAny' c nfn t           = fmap to . gfvAny c nfn $ from t

  aeq' c (VarTy _ n) (VarTy _ m) = aeq' c n m
  aeq' c t1          t2          = gaeq c (from t1) (from t2)

  acompare' c (VarTy _ n) (VarTy _ m) = acompare' c n m
  acompare' c t1          t2          = gacompare c (from t1) (from t2)

instance Subst a LitTy where
  subst _ _ lt = lt
  substs _ lt  = lt

instance Subst a ConstTy where
  subst _ _ ct = ct
  substs _ ct  = ct

instance Subst Term Type
instance Subst Type Type where
  isvar (VarTy _ v) = Just (SubstName v)
  isvar _           = Nothing

instance Eq Type where
  (==) = aeq

instance Ord Type where
  compare = acompare

-- | An easier view on types
tyView :: Type -> TypeView
tyView ty@(AppTy _ _) = case splitTyAppM ty of
  Just (ConstTy Arrow, [ty1,ty2]) -> FunTy ty1 ty2
  Just (ConstTy (TyCon tc), args) -> TyConApp tc args
  _ -> OtherType ty
tyView (ConstTy (TyCon tc)) = TyConApp tc []
tyView t = OtherType t

-- | A transformation that renders 'Signal' types transparent
transparentTy :: Type -> Type
transparentTy ty@(AppTy (AppTy (ConstTy (TyCon tc)) _) elTy)
  = case name2String tc of
      "CLaSH.Signal.Internal.Signal'" -> transparentTy elTy
      _ -> ty
transparentTy (AppTy ty1 ty2) = AppTy (transparentTy ty1) (transparentTy ty2)
transparentTy (ForAllTy b)    = ForAllTy (uncurry bind $ second transparentTy $ unsafeUnbind b)
transparentTy ty              = ty

-- | A view on types in which 'Signal' types and newtypes are transparent, and
-- type functions are evaluated when possible.
coreView :: HashMap TyConName TyCon -> Type -> TypeView
coreView tcMap ty =
  let tView = tyView ty
  in case tView of
       TyConApp tc args -> case name2String tc of
         "CLaSH.Signal.Internal.Signal'" -> coreView tcMap (args !! 1)
         _ -> case (tcMap HashMap.! tc) of
                AlgTyCon {algTcRhs = (NewTyCon _ nt)}
                  -> coreView tcMap (newTyConInstRhs nt args)
                FunTyCon {tyConSubst = tcSubst} -> case findFunSubst tcSubst args of
                  Just ty' -> coreView tcMap ty'
                  _ -> tView
                _ -> tView
       _ -> tView

-- | Instantiate and Apply the RHS/Original of a NewType with the given
-- list of argument types
newTyConInstRhs :: ([TyName],Type) -> [Type] -> Type
newTyConInstRhs (tvs,ty) tys = foldl AppTy (substTys (zip tvs tys1) ty) tys2
  where
    (tys1, tys2) = splitAtList tvs tys

-- | Make a function type of an argument and result type
mkFunTy :: Type -> Type -> Type
mkFunTy t1 = AppTy (AppTy (ConstTy Arrow) t1)

-- | Make a TyCon Application out of a TyCon and a list of argument types
mkTyConApp :: TyConName -> [Type] -> Type
mkTyConApp tc = foldl AppTy (ConstTy $ TyCon tc)

-- | Make a Type out of a TyCon
mkTyConTy :: TyConName -> Type
mkTyConTy ty = ConstTy $ TyCon ty

-- | Split a TyCon Application in a TyCon and its arguments
splitTyConAppM :: Type
               -> Maybe (TyConName,[Type])
splitTyConAppM (tyView -> TyConApp tc args) = Just (tc,args)
splitTyConAppM _                            = Nothing

-- | Is a type a Superkind?
isSuperKind :: HashMap TyConName TyCon -> Type -> Bool
isSuperKind tcMap (ConstTy (TyCon ((tcMap HashMap.!) -> SuperKindTyCon {}))) = True
isSuperKind _ _ = False

-- | Determine the kind of a type
typeKind :: HashMap TyConName TyCon -> Type -> Kind
typeKind _ (VarTy k _)          = k
typeKind m (ForAllTy b)         = let (_,ty) = runFreshM $ unbind b
                                  in typeKind m ty
typeKind _ (LitTy (NumTy _))    = typeNatKind
typeKind _ (LitTy (SymTy _))    = typeSymbolKind
typeKind m (tyView -> FunTy _arg res)
  | isSuperKind m k = k
  | otherwise       = liftedTypeKind
  where k = typeKind m res

typeKind m (tyView -> TyConApp tc args) = foldl kindFunResult (tyConKind (m HashMap.! tc)) args

typeKind m (AppTy fun arg)      = kindFunResult (typeKind m fun) arg
typeKind _ (ConstTy ct)         = error $ $(curLoc) ++ "typeKind: naked ConstTy: " ++ show ct

kindFunResult :: Kind -> KindOrType -> Kind
kindFunResult (tyView -> FunTy _ res) _ = res

kindFunResult (ForAllTy b) arg =
  let (kv,ki) = runFreshM . unbind $ b
  in  substKindWith (zip [varName kv] [arg]) ki

kindFunResult k tys =
  error $ $(curLoc) ++ "kindFunResult: " ++ show (k,tys)

-- | Is a type polymorphic?
isPolyTy :: Type -> Bool
isPolyTy (ForAllTy _)            = True
isPolyTy (tyView -> FunTy _ res) = isPolyTy res
isPolyTy _                       = False

-- | Split a function type in an argument and result type
splitFunTy :: HashMap TyConName TyCon
           -> Type
           -> Maybe (Type, Type)
splitFunTy m (coreView m -> FunTy arg res) = Just (arg,res)
splitFunTy _ _                             = Nothing

splitFunTys :: HashMap TyConName TyCon
            -> Type
            -> ([Type],Type)
splitFunTys m (coreView m -> FunTy arg res) = (arg:args,res')
  where
    (args,res') = splitFunTys m res
splitFunTys _ ty = ([],ty)

-- | Split a poly-function type in a: list of type-binders and argument types,
-- and the result type
splitFunForallTy :: Type
                 -> ([Either TyVar Type],Type)
splitFunForallTy = go []
  where
    go args (ForAllTy b) = let (tv,ty) = runFreshM $ unbind b
                           in  go (Left tv:args) ty
    go args (tyView -> FunTy arg res) = go (Right arg:args) res
    go args ty                        = (reverse args,ty)

-- | Split a poly-function type in a: list of type-binders and argument types,
-- and the result type. Looks through 'Signal' and type functions.
splitCoreFunForallTy :: HashMap TyConName TyCon
                     -> Type
                     -> ([Either TyVar Type], Type)
splitCoreFunForallTy tcm = go []
  where
    go args (ForAllTy b) = let (tv, ty) = runFreshM $ unbind b
                           in  go (Left tv:args) ty
    go args (coreView tcm -> FunTy arg res) = go (Right arg:args) res
    go args ty = (reverse args, ty)

-- | Is a type a polymorphic or function type?
isPolyFunTy :: Type
            -> Bool
isPolyFunTy = not . null . fst . splitFunForallTy

-- | Is a type a polymorphic or function type under 'coreView'?
isPolyFunCoreTy :: HashMap TyConName TyCon
                -> Type
                -> Bool
isPolyFunCoreTy m ty = case coreView m ty of
                         (FunTy _ _) -> True
                         (OtherType (ForAllTy _)) -> True
                         _ -> False

-- | Is a type a function type?
isFunTy :: HashMap TyConName TyCon
        -> Type
        -> Bool
isFunTy m = isJust . splitFunTy m

-- | Apply a function type to an argument type and get the result type
applyFunTy :: HashMap TyConName TyCon
           -> Type
           -> Type
           -> Type
applyFunTy m (coreView m -> FunTy _ resTy) _ = resTy
applyFunTy _ _ _ = error $ $(curLoc) ++ "Report as bug: not a FunTy"

-- | Substitute the type variable of a type ('ForAllTy') with another type
applyTy :: Fresh m
        => HashMap TyConName TyCon
        -> Type
        -> KindOrType
        -> m Type
applyTy tcm (coreView tcm -> OtherType (ForAllTy b)) arg = do
  (tv,ty) <- unbind b
  return (substTy (varName tv) arg ty)
applyTy _ ty arg = error ($(curLoc) ++ "applyTy: not a forall type:\n" ++ show ty ++ "\nArg:\n" ++ show arg)

-- | Split a type application in the applied type and the argument types
splitTyAppM :: Type
            -> Maybe (Type, [Type])
splitTyAppM = fmap (second reverse) . go []
  where
    go args (AppTy ty1 ty2) =
      case go args ty1 of
        Nothing             -> Just (ty1,ty2:args)
        Just (ty1',ty1args) -> Just (ty1',ty2:ty1args )
    go _ _ = Nothing

-- Type function substitutions

-- Given a set of type functions, and list of argument types, get the first
-- type function that matches, and return its substituted RHS type.
findFunSubst :: [([Type],Type)] -> [Type] -> Maybe Type
findFunSubst [] _ = Nothing
findFunSubst (tcSubst:rest) args = case funSubsts tcSubst args of
  Just ty -> Just ty
  Nothing -> findFunSubst rest args

-- Given a ([LHS match type], RHS type) representing a type function, and
-- a set of applied types. Match LHS with args, and when successful, return
-- a substituted RHS
funSubsts :: ([Type],Type) -> [Type] -> Maybe Type
funSubsts (tcSubstLhs,tcSubstRhs) args = do
  tySubts <- concat <$> zipWithM funSubst tcSubstLhs args
  let tyRhs = substTys tySubts tcSubstRhs
  return tyRhs

-- Given a LHS matching type, and a RHS to-match type, check if LHS and RHS
-- are a match. If they do match, and the LHS is a variable, return a
-- substitution
funSubst :: Type -> Type -> Maybe [(TyName,Type)]
funSubst (VarTy _ nmF) ty = Just [(nmF,ty)]
funSubst tyL@(LitTy _) tyR = if tyL == tyR then Just [] else Nothing
funSubst (tyView -> TyConApp tc argTys) (tyView -> TyConApp tc' argTys')
  | tc == tc'
  = do
    tySubts <- zipWithM funSubst argTys argTys'
    return (concat tySubts)
funSubst _ _ = Nothing

-- | The type of GHC.Err.undefined :: forall a . a
undefinedTy :: Type
undefinedTy =
  let aNm = string2Name "a"
  in  ForAllTy (bind (TyVar aNm (embed liftedTypeKind)) (VarTy liftedTypeKind aNm))
