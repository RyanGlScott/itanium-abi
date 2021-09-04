module ABI.Itanium.Pretty (
  cxxNameToString,
  cxxNameToText
  ) where

import Control.Monad ( foldM, void )
import Control.Monad.Trans.State.Strict
import Data.Char ( digitToInt )
import Data.List ( foldl', intersperse )
import Data.HashMap.Strict ( HashMap )
import qualified Data.HashMap.Strict as HM
import Data.Maybe ( fromMaybe )
import Data.Monoid
import Data.Text.Lazy ( Text, unpack )
import Data.Text.Lazy.Builder

import ABI.Itanium.Types

-- | The Pretty type maintains the substitution table used for
-- emitting a demangled names.  For compression, demangling allows the
-- use of "substitutions" to refer to previously emitted portions of
-- the name.  Most portions of the name that are emitted are recorded
-- (with compositional buildup: @foo::bar@ will record both @foo@ and
-- @foo::bar@).  The only exceptions to recording are function names
-- and builtin types.  As a name is demangled, each portion will be
-- added to this table for use in subsequent substitutions.

type Pretty = State (HashMap Int Builder)

-- | Records a substitution component in the current table, skipping
-- any duplications.
--
-- For convenience, it returns the same item it recorded to allow this
-- to be the last statement for a Pretty Builder operation that should
-- record and return the generated output.
recordSubstitution :: Builder -> Pretty Builder
recordSubstitution b = do
  s <- get
  case b `elem` HM.elems s of
    False -> do
      let n = HM.size s
      put $! HM.insert n b s
      return b
    True -> return b

-- | This is a convenience wrapper for 'recordSubstitution' that will
-- return a void value; this can be used where the results of the
-- recording are not needed and the compiler would warn about an
-- unused return value.
recordSubstitution' :: Builder -> Pretty ()
recordSubstitution' = void . recordSubstitution

-- | Function names are not recorded, but their prefixes are.  For example:
--
--    Input                          | Records
--    -------------------------------|--------------------------------
--    @foo(int)@                     | (nothing)
--                                   |
--    @bar::foo(int)@                | @bar@
--                                   |
--    @bar::cow<moo>::boo::foo(int)@ | @bar@ @bar::cow@ @bar::cow<moo>@
--                                   | @bar::cow<moo>::boo@
--
-- To support this, the various parts of the function call are
-- recorded as normal (using recursive, shared pretty printing) and
-- then this function is called to drop the last element recorded,
-- which is the actual function name.
dropLastSubstitution :: Pretty ()
dropLastSubstitution = modify $ \s -> HM.delete ((HM.size s) - 1) s

-- | Lookup a recorded substitution and return it.  A lookup failure
-- means either a malformed mangled name (unlikely) or a logic error
-- below that did not properly record a substitution component.
getSubstitution :: Maybe String -> Pretty Builder
getSubstitution s = do
  st <- get
  case s of
    Nothing -> return $! lookupError 0 st
    -- This case always adds 1 from the number because the
    -- Nothing case is index zero
    Just ix ->
      let n = numberValue 36 ix
      in return $! lookupError (n+1) st
  where
    errMsg = error ("No substitution found for " ++ show s)
    lookupError k m = fromMaybe errMsg (HM.lookup k m)

cxxNameToText :: DecodedName -> Text
cxxNameToText n = toLazyText $ evalState (dispatchTopLevel n) mempty

cxxNameToString :: DecodedName -> String
cxxNameToString = unpack . cxxNameToText

dispatchTopLevel :: DecodedName -> Pretty Builder
dispatchTopLevel n =
  case n of
    Function (NestedName qs@(_:_) pfxs uname) argTypes -> do
      pn <- showPrefixedName pfxs uname
      dropLastSubstitution
      argBuilders <- case argTypes of
        [VoidType] -> return mempty
        _ -> mapM showType argTypes
      quals <- showQualifiers pn qs
      return $! mconcat [ pn
                        , singleton '('
                        , mconcat $ intersperse (fromString ", ") argBuilders
                        , fromString ") "
                        ] `mappend` quals
    Function fname argTypes -> do
      nameBuilder <- showName fname
      dropLastSubstitution
      argBuilders <- case argTypes of
        [VoidType] -> return mempty
        _ -> mapM showType argTypes
      return $! mconcat [ nameBuilder
                        , singleton '('
                        , mconcat $ intersperse (fromString ", ") argBuilders
                        , singleton ')'
                        ]
    ConstStructData varName -> showUnqualifiedName varName
    Data varName -> showName varName
    VirtualTable t -> do
      tb <- showType t
      return $! mconcat [ fromString "vtable for ", tb ]
    VTTStructure t -> do
      tb <- showType t
      return $! mconcat [ fromString "<vttstruct for ", tb, singleton '>' ]
    TypeInfo t -> do
      tb <- showType t
      return $! mconcat [ fromString "typeinfo for ", tb ]
    TypeInfoName t -> do
      tb <- showType t
      return $! mconcat [ fromString "typeinfo name for ", tb ]
    GuardVariable vname -> do
      vn <- showName vname
      return $! mconcat [ fromString "guard variable for ", vn ]
    OverrideThunk _ target -> do
      tn <- dispatchTopLevel target
      return $! mconcat [ fromString "non-virtual thunk to ", tn ]
    OverrideThunkCovariant _ _ target -> do
      tn <- dispatchTopLevel target
      return $! mconcat [ fromString "virtual thunk to ", tn ]

showName :: Name -> Pretty Builder
showName n =
  case n of
    NestedName qs pfxs uname -> do
      pn <- showPrefixedName pfxs uname
      recordSubstitution' pn
      case null qs of
        False -> mappend (mconcat [ pn, singleton ' ' ]) <$> showQualifiers pn qs
        True -> return $! pn
    UnscopedName uname -> showUName uname
    NestedTemplateName [] pfxs targs ->
      showPrefixedTArgs pfxs targs >>= recordSubstitution
    NestedTemplateName qs pfxs targs -> do
      pn <- showPrefixedTArgs pfxs targs
      recordSubstitution' pn
      quals <- showQualifiers pn qs
      return $! mconcat [ pn, singleton ' ' ] `mappend` quals
    UnscopedTemplateName uname targs -> do
      un <- showUName uname
      recordSubstitution' un
      tns <- showTArgs targs
      recordSubstitution $! mconcat [ un, singleton '<'
                                    , tns
                                    , singleton '>'
                                    ]
    UnscopedTemplateSubstitution s targs -> do
      ss <- showSubstitution s
      tns <- showTArgs targs
      return $! mconcat [ ss, singleton '<', tns, singleton '>' ]

showUName :: UName -> Pretty Builder
showUName u =
  case u of
    UName uname -> showUnqualifiedName uname
    UStdName uname -> do
      un <- showUnqualifiedName uname
      return (fromString "std::" `mappend` un)

showTArgs :: [TemplateArg] -> Pretty Builder
showTArgs targs = do
  tns <- mapM showTArg targs
  return $! mconcat $! intersperse (fromString ", ") tns

showPrefixedTArgs :: [Prefix] -> [TemplateArg] -> Pretty Builder
showPrefixedTArgs = go mempty
  where
    go acc pfxs targs =
      case pfxs of
        [] -> do
          tns <- mapM showTArg targs
          return $! mconcat [ acc, singleton '<'
                            , mconcat $ intersperse (fromString ", ") tns
                            , singleton '>' ]
        pfx : rest -> do
          nextAcc <- showPrefix acc pfx
          go nextAcc rest targs

showTArg :: TemplateArg -> Pretty Builder
showTArg ta =
  case ta of
    TypeTemplateArg t -> showType t

-- pass the current prefix builder down so that it can be added to and
-- stored for substitutions
showPrefixedName :: [Prefix] -> UnqualifiedName -> Pretty Builder
showPrefixedName = go mempty
  where
    go acc pfxs uname =
      case (pfxs, uname) of
        ([], SourceName n) -> do
          recordSubstitution $! mconcat [ acc, fromString "::", fromString n ]
        ([], OperatorName op) -> do
          ob <- showOperator op
          recordSubstitution' ob
          case acc == mempty of
            False -> return $! mconcat [ acc, fromString "::operator", ob ]
            True -> return $! mconcat [ fromString "operator", ob ]
        -- We need to handle constructors and destructors specially
        -- because we won't have enough information to build the right
        -- name if we do a fully depth-first traversal in isolation
        -- without context.  We recognize them here and short circuit
        -- some of the traversal to make things easier.
        ([UnqualifiedPrefix (SourceName className)], CtorDtorName cd) -> do
          let curPfx =
                case acc == mempty of
                  False -> acc `mappend` fromString "::"
                  True -> mempty
              inFix = case isDestructor cd of
                False -> fromString "::"
                True -> fromString "::~"
              sub = curPfx `mappend` fromString className
          recordSubstitution' sub
          return $! mconcat [ curPfx, fromString className, inFix, fromString className ]
        ([UnqualifiedPrefix (SourceName className), tmplPfx@(TemplateArgsPrefix{})], CtorDtorName cd) -> do
          let prevPfx here = case acc == mempty of
                               True -> here
                               False -> mconcat [ acc, fromString "::", here ]
          nextAcc <- showPrefix (prevPfx $ fromString className) tmplPfx
          let inFix = case isDestructor cd of
                False -> fromString "::"
                True -> fromString "::~"
          return $! mconcat [ nextAcc, inFix, fromString className ]
        (outerPfx : innerPfxs, _) -> do
          nextAcc <- showPrefix acc outerPfx
          go nextAcc innerPfxs uname
        ([], CtorDtorName _) -> error "Illegal fallthrough in constructor/destructor case"

isDestructor :: CtorDtor -> Bool
isDestructor cd =
  case cd of
    D0 -> True
    D1 -> True
    D2 -> True
    _ -> False

showQualifiers :: Builder -> [CVQualifier] -> Pretty Builder
showQualifiers qualifies qs =
  case null qs of
    True -> return mempty
    False -> snd <$> foldM showQualifier (qualifies,mempty) qs

showQualifier :: (Builder, Builder) -> CVQualifier -> Pretty (Builder, Builder)
showQualifier (accum,res) q = do
  -- accum is the accumulated name with the base name, used for
  -- recording subtitutions.  res is the accumulated name but not
  -- including the base name which is previously emitted.  res is
  -- ultimately returned.
  let qual = case q of
              Restrict -> fromString "restrict"
              Volatile -> fromString "volatile"
              Const -> fromString "const"
      acc' = mconcat [ accum, singleton ' ', qual ]
      res' = case res == mempty of
               True -> qual
               False -> mconcat [ res, singleton ' ', qual ]
  recordSubstitution' acc'
  return $! (acc', res')


-- | These are outer namespace/class name qualifiers, so convert them
-- to strings followed by ::
showPrefix :: Builder -> Prefix -> Pretty Builder
showPrefix prior pfx =
  let addPrior doRecord toThis = do
        let ret = case prior == mempty of
                    False -> mconcat [ prior, fromString "::", toThis ]
                    True -> toThis
        if doRecord then recordSubstitution ret else return ret
  in case pfx of
       DataMemberPrefix s -> addPrior True $ fromString s
       UnqualifiedPrefix uname -> addPrior True =<< showUnqualifiedName uname
       SubstitutionPrefix s -> addPrior False =<< showSubstitution s
       TemplateArgsPrefix args ->
         case prior == mempty of
           True -> showPrefixedTArgs [] args >>= recordSubstitution
           False -> do recordSubstitution' prior
                       targs <- showPrefixedTArgs [] args
                       let this = mconcat [ prior, targs ]
                       recordSubstitution this

showUnqualifiedName :: UnqualifiedName -> Pretty Builder
showUnqualifiedName uname =
  case uname of
    OperatorName op -> do
      ob <- showOperator op
      return (fromString "operator" `mappend` ob)
    CtorDtorName _ -> error "showUnqualifiedName shouldn't reach the ctor/dtor case"
    SourceName s -> return (fromString s)

showOperator :: Operator -> Pretty Builder
showOperator op =
  case op of
    OpNew -> return $! fromString " new"
    OpNewArray -> return $! fromString " new[]"
    OpDelete -> return $! fromString " delete"
    OpDeleteArray -> return $! fromString " delete[]"
    OpUPlus -> return $! singleton '+'
    OpUMinus -> return $! singleton '-'
    OpAddressOf -> return $! singleton '&'
    OpDeref -> return $! singleton '*'
    OpBitNot -> return $! singleton '~'
    OpPlus -> return $! singleton '+'
    OpMinus -> return $! singleton '-'
    OpMul -> return $! singleton '*'
    OpDiv -> return $! singleton '/'
    OpMod -> return $! singleton '%'
    OpBitAnd -> return $! singleton '&'
    OpBitOr -> return $! singleton '|'
    OpBitXor -> return $! singleton '^'
    OpAssign -> return $! singleton '='
    OpPlusAssign -> return $! fromString "+="
    OpMinusAssign -> return $! fromString "-="
    OpMulAssign -> return $! fromString "*="
    OpDivAssign -> return $! fromString "/="
    OpModAssign -> return $! fromString "%="
    OpAndAssign -> return $! fromString "&="
    OpOrAssign -> return $! fromString "|="
    OpXorAssign -> return $! fromString "^="
    OpShl -> return $! fromString "<<"
    OpShr -> return $! fromString ">>"
    OpShlAssign -> return $! fromString "<<="
    OpShrAssign -> return $! fromString ">>="
    OpEquals -> return $! fromString "=="
    OpNotEquals -> return $! fromString "!="
    OpLt -> return $! singleton '<'
    OpGt -> return $! singleton '>'
    OpLte -> return $! fromString "<="
    OpGte -> return $! fromString ">="
    OpNot -> return $! singleton '!'
    OpAnd -> return $! fromString "&&"
    OpOr -> return $! fromString "||"
    OpPlusPlus -> return $! fromString "++"
    OpMinusMinus -> return $! fromString "--"
    OpComma -> return $! singleton ','
    OpArrowStar -> return $! fromString "->*"
    OpArrow -> return $! fromString "->"
    OpCall -> return $! fromString "()"
    OpIndex -> return $! fromString "[]"
    OpQuestion -> return $! singleton '?'
    OpSizeofType -> return $! fromString " sizeof"
    OpSizeofExpr -> return $! fromString " sizeof"
    OpAlignofType -> return $! fromString " alignof"
    OpAlignofExpr -> return $! fromString " alignof"
    OpCast t -> do
      tb <- showType t
      return $! singleton ' ' `mappend` tb
    OpVendor n oper -> return $! fromString ("vendor" ++ show n ++ oper) -- ??

showType :: CXXType -> Pretty Builder
showType t =
  case t of
    QualifiedType qs t' -> do
      tb <- showType t'
      quals <- showQualifiers tb qs
      return $! mconcat [ tb, singleton ' ' ] `mappend` quals
    PointerToType (FunctionType ts) -> do
      -- Since we don't explicitly descend the FunctionType here, we
      -- need to create a stub entry in the substitution table for it
      -- (otherwise the pointer to the type will be off by one).  The
      -- stub will never be referenced because function types aren't
      -- first-class
      ts' <- mapM showType ts
      recordSubstitution' (mconcat ts')
      r <- showFunctionType ts
      recordSubstitution r
    PointerToType t' -> do
      tb <- showType t'
      let r = tb `mappend` singleton '*'
      recordSubstitution r
    ReferenceToType t' -> do
      tb <- showType t'
      let r = tb `mappend` singleton '&'
      recordSubstitution r
    RValueReferenceToType t' -> do
      tb <- showType t'
      let r = tb `mappend` fromString "&&"
      recordSubstitution r
    ComplexPairType t' -> do
      tb <- showType t'
      let r = tb `mappend` fromString " complex"
      return $! r
    ImaginaryType t' -> do
      tb <- showType t'
      let r = tb `mappend` fromString " imaginary"
      return $! r
    ParameterPack _ -> undefined
    VendorTypeQualifier q t' -> do
      tb <- showType t'
      let r = mconcat [ fromString q, singleton ' ', tb ]
      return $! r
    VoidType -> return $! fromString "void"
    Wchar_tType -> return $! fromString "wchar_t"
    BoolType -> return $! fromString "bool"
    CharType -> return $! fromString "char"
    SignedCharType -> return $! fromString "signed char"
    UnsignedCharType -> return $! fromString "unsigned char"
    ShortType -> return $! fromString "short"
    UnsignedShortType -> return $! fromString "unsigned short"
    IntType -> return $! fromString "int"
    UnsignedIntType -> return $! fromString "unsigned int"
    LongType -> return $! fromString "long"
    UnsignedLongType -> return $! fromString "unsigned long"
    LongLongType -> return $! fromString "long long"
    UnsignedLongLongType -> return $! fromString "unsigned long long"
    Int128Type -> return $! fromString "__int128"
    UnsignedInt128Type -> return $! fromString "unsigned __int128"
    FloatType -> return $! fromString "float"
    DoubleType -> return $! fromString "double"
    LongDoubleType -> return $! fromString "long double"
    Float128Type -> return $! fromString "__float128"
    EllipsisType -> return $! fromString "..."
    Char32Type -> return $! fromString "char32_t"
    Char16Type -> return $! fromString "char16_t"
    AutoType -> return $! fromString "auto"
    NullPtrType -> return $! fromString "std::nullptr_t"
    VendorBuiltinType s -> return $! fromString s
    FunctionType _ -> error "Only pointers to function types are supported"
    ExternCFunctionType ts -> do
      tb <- showFunctionType ts
      let r = fromString "extern \"C\" " `mappend` tb
      return $! r
    ArrayTypeN (Just n) t' -> do
      tb <- showType t'
      let r = mconcat [ tb, singleton '[', fromString (show n), singleton ']' ]
      return $! r
    ArrayTypeN Nothing t' -> do
      tb <- showType t'
      let r = tb `mappend` fromString "[]"
      return $! r
    ClassEnumType n -> do
      r <- showName n
      recordSubstitution r
    PtrToMemberType c m -> do
      r <- showPtrToMember c m
      return $! r
    SubstitutionType s -> showSubstitution s

showSubstitution :: Substitution -> Pretty Builder
showSubstitution s =
  case s of
    Substitution ss -> getSubstitution ss
    SubStdNamespace -> return $! fromString "std"
    SubStdAllocator -> return $! fromString "std::allocator"
    SubBasicString -> return $! fromString "std::basic_string"
    SubBasicStringArgs -> return $! fromString "std::basic_string<char, std::char_traits<char>, std::allocator<char> >"
    SubBasicIstream -> return $! fromString "std::basic_istream<char, std::char_traits<char> >"
    SubBasicOstream -> return $! fromString "std::basic_ostream<char, std::char_traits<char> >"
    SubBasicIostream -> return $! fromString "std::basic_iostream<char, std::char_traits<char> >"

showPtrToMember :: CXXType -> CXXType -> Pretty Builder
showPtrToMember (ClassEnumType n) (FunctionType (rt:argts)) = do
  rt' <- showType rt
  argts' <- mapM showType argts
  nb <- showName n
  return $! mconcat [ rt', fromString " (", nb , fromString "::*)("
                    , mconcat (intersperse (fromString ", ") argts')
                    , singleton ')'
                    ]
showPtrToMember _ _ = error "Expected a ClassEnumType and FunctionType pair for PtrToMemberType"

showFunctionType :: [CXXType] -> Pretty Builder
showFunctionType ts =
  case ts of
    [] -> error "Empty type list in function type"
    [rtype, VoidType] -> do
      rt' <- showType rtype
      return $! mconcat [ rt', fromString " (*)()" ]
    rtype:rest -> do
      tb <- showType rtype
      rbs <- mapM showType rest
      let arglist = mconcat $ intersperse (fromString ", ") rbs
      return $! mconcat [ tb, fromString " (*)(", arglist, singleton ')' ]

-- Helpers

-- Taken from parsec-numbers
numberValue :: Integral i => Int -> String -> i
numberValue base =
  foldl' (\ x -> ((fromIntegral base * x) +) . fromIntegral . digitToInt) 0
