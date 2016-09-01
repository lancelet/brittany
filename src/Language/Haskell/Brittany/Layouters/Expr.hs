{-# LANGUAGE DataKinds #-}

module Language.Haskell.Brittany.Layouters.Expr
  ( layoutExpr
  , litBriDoc
  , overLitValBriDoc
  )
where



#include "prelude.inc"

import           Language.Haskell.Brittany.Types
import           Language.Haskell.Brittany.LayoutBasics

import           RdrName ( RdrName(..) )
import           GHC ( runGhc, GenLocated(L), moduleNameString, AnnKeywordId(..) )
import           SrcLoc ( SrcSpan )
import           HsSyn
import           Name
import qualified FastString
import           BasicTypes

import           Language.Haskell.Brittany.Layouters.Pattern
import           Language.Haskell.Brittany.Layouters.Decl
import           Language.Haskell.Brittany.Layouters.Stmt
import           Language.Haskell.Brittany.Layouters.Type



layoutExpr :: ToBriDoc HsExpr
layoutExpr lexpr@(L _ expr) = docWrapNode lexpr $ case expr of
  HsVar vname -> do
    docLit =<< lrdrNameToTextAnn vname
  HsUnboundVar var -> case var of
    OutOfScope oname _ -> docLit $ Text.pack $ occNameString oname
    TrueExprHole oname -> docLit $ Text.pack $ occNameString oname
  HsRecFld{} -> do
    -- TODO
    unknownNodeError "HsRecFld" lexpr
  HsOverLabel{} -> do
    -- TODO
    unknownNodeError "HsOverLabel{}" lexpr
  HsIPVar{} -> do
    -- TODO
    unknownNodeError "HsOverLabel{}" lexpr
  HsOverLit (OverLit olit _ _ _) -> do
    allocateNode $ overLitValBriDoc olit
  HsLit lit -> do
    allocateNode $ litBriDoc lit
  HsLam (MG (L _ [lmatch@(L _ (Match _ pats _ (GRHSs [lgrhs@(L _ (GRHS [] body))] (L _ EmptyLocalBinds))))]) _ _ _) -> do
    patDocs <- pats `forM` docSharedWrapper layoutPat
    bodyDoc <- docAddBaseY BrIndentRegular <$> docSharedWrapper layoutExpr body
    let funcPatternPartLine =
          docCols ColCasePattern
            $ (patDocs <&> (\p -> docSeq [docForceSingleline p, docSeparator]))
    docAlt
      [ -- single line
        docSeq
        [ docLit $ Text.pack "\\"
        , docWrapNode lmatch $ docForceSingleline funcPatternPartLine
        , appSep $ docLit $ Text.pack "->"
        , docWrapNode lgrhs $ docForceSingleline bodyDoc
        ]
        -- double line
      , docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
        (docSeq
          [ docLit $ Text.pack "\\"
          , docWrapNode lmatch $ appSep $ docForceSingleline funcPatternPartLine
          , docLit $ Text.pack "->"
          ])
        (docWrapNode lgrhs $ docForceSingleline bodyDoc)
        -- wrapped par spacing
      , docSetParSpacing
      $ docSeq
        [ docLit $ Text.pack "\\"
        , docWrapNode lmatch $ docForceSingleline funcPatternPartLine
        , appSep $ docLit $ Text.pack "->"
        , docWrapNode lgrhs $ docForceParSpacing bodyDoc
        ]
        -- conservative
      , docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
        (docSeq
          [ docLit $ Text.pack "\\"
          , docWrapNode lmatch $ appSep $ docForceSingleline funcPatternPartLine
          , docLit $ Text.pack "->"
          ])
        (docWrapNode lgrhs $ docNonBottomSpacing bodyDoc)
      ]
  HsLam{} ->
    unknownNodeError "HsLam too complex" lexpr
  HsLamCase _ (MG lmatches@(L _ matches) _ _ _) -> do
    binderDoc <- docLit $ Text.pack "->"
    funcPatDocs <- docWrapNode lmatches $ layoutPatternBind Nothing binderDoc `mapM` matches
    docSetParSpacing $ docAddBaseY BrIndentRegular $ docPar
      (docLit $ Text.pack "\\case")
      (docSetBaseAndIndent $ docNonBottomSpacing $ docLines $ return <$> funcPatDocs)
  HsApp exp1@(L _ HsApp{}) exp2 -> do
    let gather :: [LHsExpr RdrName] -> LHsExpr RdrName -> (LHsExpr RdrName, [LHsExpr RdrName])
        gather list = \case
          (L _ (HsApp l r)) -> gather (r:list) l
          x -> (x, list)
    let (headE, paramEs) = gather [exp2] exp1
    headDoc <- docSharedWrapper layoutExpr headE
    paramDocs <- docSharedWrapper layoutExpr `mapM` paramEs
    docAlt
      [ docCols ColApp
      $ appSep (docForceSingleline headDoc)
      : spacifyDocs (docForceSingleline <$> paramDocs)
      , docSeq
        [ appSep (docForceSingleline headDoc)
        , docSetBaseY
        $ docAddBaseY BrIndentRegular
        $ docLines
        $ paramDocs
        ]
      , docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
        (docForceSingleline headDoc)
        ( docNonBottomSpacing
        $ docLines paramDocs
        )
      , docAddBaseY BrIndentRegular
      $ docPar
        headDoc
        ( docNonBottomSpacing
        $ docLines paramDocs
        )
      ]
  HsApp exp1 exp2 -> do
    -- TODO: if expDoc1 is some literal, we may want to create a docCols here.
    expDoc1 <- docSharedWrapper layoutExpr exp1
    expDoc2 <- docSharedWrapper layoutExpr exp2
    docAlt
      [ docSeq [appSep $ docForceSingleline expDoc1, docForceSingleline expDoc2]
      , docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docSeq
        [ appSep $ docForceSingleline expDoc1
        , docForceParSpacing expDoc2
        ]
      , docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
        (docForceSingleline expDoc1)
        expDoc2
      , docAddBaseY BrIndentRegular
      $ docPar
        expDoc1
        expDoc2
      ]
  HsAppType{} -> do
    -- TODO
    unknownNodeError "HsAppType{}" lexpr
  HsAppTypeOut{} -> do
    -- TODO
    unknownNodeError "HsAppTypeOut{}" lexpr
  OpApp expLeft@(L _ OpApp{}) expOp _ expRight -> do
    let gather :: [(LHsExpr RdrName, LHsExpr RdrName)] -> LHsExpr RdrName -> (LHsExpr RdrName, [(LHsExpr RdrName, LHsExpr RdrName)])
        gather opExprList = \case
          (L _ (OpApp l1 op1 _ r1)) -> gather ((op1, r1): opExprList) l1
          final -> (final, opExprList)
        (leftOperand, appList) = gather [] expLeft
    leftOperandDoc <- docSharedWrapper layoutExpr leftOperand
    appListDocs <- appList `forM` \(x,y) -> [ (xD, yD)
                                            | xD <- docSharedWrapper layoutExpr x
                                            , yD <- docSharedWrapper layoutExpr y
                                            ]
    opLastDoc <- docSharedWrapper layoutExpr expOp
    expLastDoc <- docSharedWrapper layoutExpr expRight
    docAlt
      [ docSeq
        [ appSep $ docForceSingleline leftOperandDoc
        , docSeq
        $ (appListDocs <&> \(od, ed) -> docSeq
            [ appSep $ docForceSingleline od
            , appSep $ docForceSingleline ed
            ]
          )
        , appSep $ docForceSingleline opLastDoc
        , docForceParSpacing expLastDoc
        ]
      -- this case rather leads to some unfortunate layouting than to anything
      -- useful; disabling for now. (it interfers with cols stuff.)
      -- , docSetBaseY
      -- $ docPar
      --     leftOperandDoc
      --     ( docLines
      --     $ (appListDocs <&> \(od, ed) -> docCols ColOpPrefix [appSep od, docSetBaseY ed])
      --       ++ [docCols ColOpPrefix [appSep opLastDoc, docSetBaseY expLastDoc]]
      --     )
      , docAddBaseY BrIndentRegular
      $ docPar
          leftOperandDoc
          ( docLines
          $ (appListDocs <&> \(od, ed) -> docCols ColOpPrefix [appSep od, docSetBaseY ed])
            ++ [docCols ColOpPrefix [appSep opLastDoc, docSetBaseY expLastDoc]]
          )
      ]
  OpApp expLeft expOp _ expRight -> do
    expDocLeft  <- docSharedWrapper layoutExpr expLeft
    expDocOp    <- docSharedWrapper layoutExpr expOp
    expDocRight <- docSharedWrapper layoutExpr expRight
    docAlt
      $   [ -- one-line
            docSeq
            [ appSep $ docForceSingleline expDocLeft
            , appSep $ docForceSingleline expDocOp
            , docForceSingleline expDocRight
            ]
          -- , -- line + freely indented block for right expression
          --   docSeq
          --   [ appSep $ docForceSingleline expDocLeft
          --   , appSep $ docForceSingleline expDocOp
          --   , docSetBaseY $ docAddBaseY BrIndentRegular expDocRight
          --   ]
          , -- two-line
            docAddBaseY BrIndentRegular
          $ docPar
              expDocLeft
              ( docForceSingleline
              $ docCols ColOpPrefix [appSep $ expDocOp, docSetBaseY expDocRight]
              )
          , -- one-line + par
            docSeq
            [ appSep $ docForceSingleline expDocLeft
            , appSep $ docForceSingleline expDocOp
            , docForceParSpacing expDocRight
            ]
          , -- more lines
            docAddBaseY BrIndentRegular
          $ docPar
              expDocLeft
              (docCols ColOpPrefix [appSep $ expDocOp, docSetBaseY expDocRight])
          ]
  NegApp op _ -> do
    opDoc <- docSharedWrapper layoutExpr op
    docSeq $ [ docLit $ Text.pack "-"
             , opDoc
             ]
  HsPar innerExp -> do
    innerExpDoc <- docSharedWrapper layoutExpr innerExp
    docAlt
      [ docSeq
        [ docLit $ Text.pack "("
        , docForceSingleline innerExpDoc
        , docLit $ Text.pack ")"
        ]
      , docSetBaseY $ docLines
        [ docCols ColOpPrefix
          [ docParenLSep
          , docAddBaseY (BrIndentSpecial 2) innerExpDoc
          ]
        , docLit $ Text.pack ")"
        ]
      ]
  SectionL left op -> do -- TODO: add to testsuite
    leftDoc <- docSharedWrapper layoutExpr left
    opDoc   <- docSharedWrapper layoutExpr op
    docSeq [leftDoc, opDoc]
  SectionR op right -> do -- TODO: add to testsuite
    opDoc    <- docSharedWrapper layoutExpr op
    rightDoc <- docSharedWrapper layoutExpr right
    docSeq [opDoc, rightDoc]
  ExplicitTuple args boxity
    | Just argExprs <- args `forM` (\case (L _ (Present e)) -> Just e; _ -> Nothing) -> do
    argDocs <- docSharedWrapper layoutExpr `mapM` argExprs
    case boxity of
      Boxed -> docAlt
        [ docSeq
        $  [ docLit $ Text.pack "(" ]
        ++ List.intersperse (appSep $ docLit $ Text.pack ",") argDocs
        ++ [ docLit $ Text.pack ")"]
        -- TODO
        ]
      Unboxed -> docAlt
        [ docSeq
        $  [ docLit $ Text.pack "(#" ]
        ++ List.intersperse (appSep $ docLit $ Text.pack ",") argDocs
        ++ [ docLit $ Text.pack "#)"]
        -- TODO
        ]
  ExplicitTuple{} ->
    unknownNodeError "ExplicitTuple|.." lexpr 
  HsCase cExp (MG lmatches@(L _ matches) _ _ _) -> do
    cExpDoc <- docSharedWrapper layoutExpr cExp
    binderDoc <- docLit $ Text.pack "->"
    funcPatDocs <- docWrapNode lmatches $ layoutPatternBind Nothing binderDoc `mapM` matches
    docAlt
      [ docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
        ( docSeq
          [ appSep $ docLit $ Text.pack "case"
          , appSep $ docForceSingleline cExpDoc
          , docLit $ Text.pack "of"
          ])
        (docSetBaseAndIndent $ docNonBottomSpacing $ docLines $ return <$> funcPatDocs)
      , docPar
          ( docAddBaseY BrIndentRegular
          $ docPar (docLit $ Text.pack "case") cExpDoc
          )
          ( docAddBaseY BrIndentRegular
          $ docPar (docLit $ Text.pack "of")
            (docSetBaseAndIndent $ docNonBottomSpacing $ docLines $ return <$> funcPatDocs)
          )
      ]
  HsIf _ ifExpr thenExpr elseExpr -> do
    ifExprDoc   <- docSharedWrapper layoutExpr ifExpr
    thenExprDoc <- docSharedWrapper layoutExpr thenExpr
    elseExprDoc <- docSharedWrapper layoutExpr elseExpr
    hasComments <- hasAnyCommentsBelow lexpr
    docAltFilter
      [ (,) (not hasComments)
      $ docSeq
        [ appSep $ docLit $ Text.pack "if"
        , appSep $ docForceSingleline ifExprDoc
        , appSep $ docLit $ Text.pack "then"
        , appSep $ docForceSingleline thenExprDoc
        , appSep $ docLit $ Text.pack "else"
        , docForceSingleline elseExprDoc
        ]
      , (,) True
      $ docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
          ( docAddBaseY (BrIndentSpecial 3)
          $ docSeq
            [ docNodeAnnKW lexpr Nothing $ appSep $ docLit $ Text.pack "if"
            , docNodeAnnKW lexpr (Just AnnIf) $ docForceSingleline ifExprDoc
            ])
          (docLines
            [ docAddBaseY BrIndentRegular
            $ docNodeAnnKW lexpr (Just AnnThen)
            $ docAlt
              [ docSeq [appSep $ docLit $ Text.pack "then", docForceParSpacing thenExprDoc]
              , docAddBaseY BrIndentRegular
              $ docPar (docLit $ Text.pack "then") thenExprDoc
              ]
            , docAddBaseY BrIndentRegular
            $ docAlt
              [ docSeq [appSep $ docLit $ Text.pack "else", docForceParSpacing elseExprDoc]
              , docAddBaseY BrIndentRegular
              $ docPar (docLit $ Text.pack "else") elseExprDoc
              ]
            ])
      , (,) True
      $ docAddBaseY BrIndentRegular
      $ docPar
          ( docAddBaseY (BrIndentSpecial 3)
          $ docSeq
            [ docNodeAnnKW lexpr Nothing $ appSep $ docLit $ Text.pack "if"
            , docNodeAnnKW lexpr (Just AnnIf) $ ifExprDoc
            ])
          (docLines
            [ docAddBaseY BrIndentRegular
            $ docNodeAnnKW lexpr (Just AnnThen)
            $ docAlt
              [ docSeq [appSep $ docLit $ Text.pack "then", docForceParSpacing thenExprDoc]
              , docAddBaseY BrIndentRegular
              $ docPar (docLit $ Text.pack "then") thenExprDoc
              ]
            , docAddBaseY BrIndentRegular
            $ docAlt
              [ docSeq [appSep $ docLit $ Text.pack "else", docForceParSpacing elseExprDoc]
              , docAddBaseY BrIndentRegular
              $ docPar (docLit $ Text.pack "else") elseExprDoc
              ]
            ])
      , (,) True
      $ docLines
        [ docAddBaseY (BrIndentSpecial 3)
        $ docSeq
          [ docNodeAnnKW lexpr Nothing $ appSep $ docLit $ Text.pack "if"
          , docNodeAnnKW lexpr (Just AnnIf) $ ifExprDoc
          ]
        , docNodeAnnKW lexpr (Just AnnThen)
        $ docAddBaseY BrIndentRegular
        $ docPar (docLit $ Text.pack "then") thenExprDoc
        , docAddBaseY BrIndentRegular
        $ docPar (docLit $ Text.pack "else") elseExprDoc
        ]
      ]
  HsMultiIf _ cases -> do
    clauseDocs <- cases `forM` layoutGrhs
    binderDoc <- docLit $ Text.pack " ->"
    docAddBaseY BrIndentRegular $ docPar
      (docLit $ Text.pack "if")
      (layoutPatternBindFinal Text.empty binderDoc Nothing clauseDocs Nothing)
  HsLet binds exp1 -> do
    expDoc1 <- docSharedWrapper layoutExpr exp1
    mBindDocs <- layoutLocalBinds binds
    -- this `docSetIndentLevel` might seem out of place, but is here due to
    -- ghc-exactprint's DP handling of "let" in particular.
    -- Just pushing another indentation level is a straightforward approach
    -- to making brittany idempotent, even though the result is non-optimal
    -- if "let" is moved horizontally as part of the transformation, as the
    -- comments before the first let item are moved horizontally with it.
    docSetIndentLevel $ case mBindDocs of
      Just [bindDoc] -> docAlt
        [ docSeq
          [ appSep $ docLit $ Text.pack "let"
          , appSep $ docForceSingleline $ return bindDoc
          , appSep $ docLit $ Text.pack "in"
          , docForceSingleline $ expDoc1
          ]
        , docLines
          [ docSeq
            [ appSep $ docLit $ Text.pack "let"
            , docSetBaseAndIndent $ return bindDoc
            ]
          , docSeq
            [ appSep $ docLit $ Text.pack "in "
            , docSetBaseY $ expDoc1
            ]
          ]
        , docLines
          [ docAddBaseY BrIndentRegular
          $ docPar
            (appSep $ docLit $ Text.pack "let")
            (docSetBaseAndIndent $ return bindDoc)
          , docAddBaseY BrIndentRegular
          $ docPar
            (appSep $ docLit $ Text.pack "in")
            (docSetBaseY $ expDoc1)
          ]
        ]
      Just bindDocs@(_:_) -> docAlt
        [ docLines
          [ docSeq
            [ appSep $ docLit $ Text.pack "let"
            , docSetBaseAndIndent $ docLines $ return <$> bindDocs
            ]
          , docSeq
            [ appSep $ docLit $ Text.pack "in "
            , docSetBaseY $ expDoc1
            ]
          ]
        , docLines
          [ docAddBaseY BrIndentRegular
          $ docPar
            (docLit $ Text.pack "let")
            (docSetBaseAndIndent $ docLines $ return <$> bindDocs)
          , docAddBaseY BrIndentRegular
          $ docPar
            (docLit $ Text.pack "in")
            (docSetBaseY $ expDoc1)
          ]
        ]
      _ -> docSeq [appSep $ docLit $ Text.pack "let in", expDoc1]
    -- docSeq [appSep $ docLit "let in", expDoc1]
  HsDo DoExpr (L _ stmts) _ -> do
    stmtDocs <- docSharedWrapper layoutStmt `mapM` stmts
    docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
          (docLit $ Text.pack "do")
          (docSetBaseAndIndent $ docNonBottomSpacing $ docLines stmtDocs)
  HsDo x  (L _ stmts) _ | case x of { ListComp -> True
                                    ; MonadComp -> True
                                    ; _ -> False } -> do
    stmtDocs <- docSharedWrapper layoutStmt `mapM` stmts
    hasComments <- hasAnyCommentsBelow lexpr
    docAltFilter
      [ (,) (not hasComments)
      $ docSeq
        [ docNodeAnnKW lexpr Nothing
        $ appSep
        $ docLit
        $ Text.pack "["
        , docNodeAnnKW lexpr (Just AnnOpenS)
        $ appSep
        $ docForceSingleline
        $ List.last stmtDocs
        , appSep $ docLit $ Text.pack "|"
        , docSeq $ List.intersperse docCommaSep
                $ fmap docForceSingleline $ List.init stmtDocs
        , docLit $ Text.pack " ]"
        ]
      , (,) True
      $ let
          start = docCols ColListComp
                    [ docNodeAnnKW lexpr Nothing
                    $ appSep $ docLit $ Text.pack "["
                    , docNodeAnnKW lexpr (Just AnnOpenS)
                    $ List.last stmtDocs
                    ]
          (s1:sM) = List.init stmtDocs
          line1 = docCols ColListComp
                    [appSep $ docLit $ Text.pack "|", s1]
          lineM = sM <&> \d ->
                  docCols ColListComp [docCommaSep, d]
          end   = docLit $ Text.pack "]"
        in docSetBaseY $ docLines $ [start, line1] ++ lineM ++ [end]
      ]
  HsDo{} -> do
    -- TODO
    unknownNodeError "HsDo{} no comp" lexpr
  ExplicitList _ _ elems@(_:_) -> do
    elemDocs <- elems `forM` docSharedWrapper layoutExpr
    docAlt
      [ docSeq
      $  [docLit $ Text.pack "["]
      ++ List.intersperse docCommaSep (docForceSingleline <$> elemDocs)
      ++ [docLit $ Text.pack "]"]
      , let
          start = docCols ColList
                    [appSep $ docLit $ Text.pack "[", List.head elemDocs]
          lines = List.tail elemDocs <&> \d ->
                  docCols ColList [docCommaSep, d]
          end   = docLit $ Text.pack "]"
        in docSetBaseY $ docLines $ [start] ++ lines ++ [end]
      ]
  ExplicitList _ _ [] ->
    docLit $ Text.pack "[]"
  ExplicitPArr{} -> do
    -- TODO
    unknownNodeError "ExplicitPArr{}" lexpr
  RecordCon lname _ _ (HsRecFields [] Nothing) -> do
    let t = lrdrNameToText lname
    docWrapNode lname $ docSeq
      [ docNodeAnnKW lexpr (Just AnnOpenC) $ docLit $ t <> Text.pack "{"
      , docLit $ Text.pack "}"
      ]
  RecordCon lname _ _ (HsRecFields fs@(_:_) Nothing) -> do
    let nameDoc = docWrapNode lname $ docLit $ lrdrNameToText lname
    ((fd1l, fd1n, fd1e):fdr) <- fs `forM` \fieldl@(L _ (HsRecField (L _ (FieldOcc lnameF _)) fExpr pun)) -> do
      fExpDoc <- if pun
        then return Nothing
        else Just <$> docSharedWrapper layoutExpr fExpr
      return $ (fieldl, lrdrNameToText lnameF, fExpDoc)
    docAlt
      [ docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
          (docNodeAnnKW lexpr Nothing $ nameDoc)
          (docNonBottomSpacing $ docLines $ let
            line1 = docCols ColRecUpdate
              [ appSep $ docLit $ Text.pack "{"
              , docWrapNodePrior fd1l $ appSep $ docLit $ fd1n
              , case fd1e of
                  Just x -> docSeq
                    [ appSep $ docLit $ Text.pack "="
                    , docWrapNodeRest fd1l $ docAddBaseY BrIndentRegular $ x
                    ]
                  Nothing -> docEmpty
              ]
            lineR = fdr <&> \(lfield, fText, fDoc) -> docCols ColRecUpdate
              [ appSep $ docLit $ Text.pack ","
              , appSep $ docLit $ fText
              , case fDoc of
                  Just x -> docWrapNode lfield $ docSeq
                    [ appSep $ docLit $ Text.pack "="
                    , docAddBaseY BrIndentRegular x
                    ]
                  Nothing -> docEmpty
              ]
            lineN = docSeq
              [ docNodeAnnKW lexpr (Just AnnOpenC) docEmpty
              , docLit $ Text.pack "}"
              ]
            in [line1] ++ lineR ++ [lineN])
      -- TODO oneliner (?)
      ]
  RecordCon lname _ _ (HsRecFields [] (Just 0)) -> do
    let t = lrdrNameToText lname
    docWrapNode lname $ docLit $ t <> Text.pack " {..}"
  RecordCon{} ->
    unknownNodeError "RecordCon with puns" lexpr
  RecordUpd rExpr [] _ _ _ _ -> do
    rExprDoc <- docSharedWrapper layoutExpr rExpr
    docSeq [rExprDoc, docLit $ Text.pack "{}"]
  RecordUpd rExpr fields@(_:_) _ _ _ _ -> do
    rExprDoc <- docSharedWrapper layoutExpr rExpr
    rFs@((rF1f, rF1n, rF1e):rFr) <- fields
      `forM` \lfield@(L _ (HsRecField (L _ ambName) rFExpr pun)) -> do
        rFExpDoc <- if pun
          then return Nothing
          else Just <$> docSharedWrapper layoutExpr rFExpr
        return $ case ambName of
          Unambiguous n _ -> (lfield, lrdrNameToText n, rFExpDoc)
          Ambiguous   n _ -> (lfield, lrdrNameToText n, rFExpDoc)
    docAlt
      -- singleline
      [ docSetParSpacing
      $ docSeq
        [ docNodeAnnKW lexpr Nothing $ appSep rExprDoc
        , appSep $ docLit $ Text.pack "{"
        , appSep $ docSeq $ List.intersperse docCommaSep
                $ rFs <&> \case
                  (lfield, fieldStr, Just fieldDoc) ->
                    docWrapNode lfield $ docSeq
                          [ appSep $ docLit fieldStr
                          , appSep $ docLit $ Text.pack "="
                          , docForceSingleline fieldDoc
                          ]
                  (lfield, fieldStr, Nothing) ->
                    docWrapNode lfield $ docLit fieldStr
        , docLit $ Text.pack "}"
        ]
      -- wild-indentation block
      , docSeq
        [ docNodeAnnKW lexpr Nothing $ appSep rExprDoc
        , docSetBaseY $ docLines $ let
            line1 = docCols ColRecUpdate
              [ appSep $ docLit $ Text.pack "{"
              , docWrapNodePrior rF1f $ appSep $ docLit $ rF1n
              , case rF1e of
                  Just x -> docWrapNodeRest rF1f $ docSeq
                                   [ appSep $ docLit $ Text.pack "="
                                   , docForceSingleline $ x
                                   ]
                  Nothing -> docEmpty
              ]
            lineR = rFr <&> \(lfield, fText, fDoc) -> docWrapNode lfield $ docCols ColRecUpdate
              [ appSep $ docLit $ Text.pack ","
              , appSep $ docLit $ fText
              , case fDoc of
                  Just x ->  docSeq [ appSep $ docLit $ Text.pack "="
                                    , docForceSingleline x
                                    ]
                  Nothing -> docEmpty
              ]
            lineN = docSeq
              [ docNodeAnnKW lexpr (Just AnnOpenC) docEmpty
              , docLit $ Text.pack "}"
              ]
            in [line1] ++ lineR ++ [lineN]
        ]
      -- strict indentation block
      , docSetParSpacing
      $ docAddBaseY BrIndentRegular
      $ docPar
          (docNodeAnnKW lexpr Nothing $ rExprDoc)
          (docNonBottomSpacing $ docLines $ let
            line1 = docCols ColRecUpdate
              [ appSep $ docLit $ Text.pack "{"
              , docWrapNodePrior rF1f $ appSep $ docLit $ rF1n
              , docWrapNodeRest rF1f $ case rF1e of
                  Just x -> docSeq [ appSep $ docLit $ Text.pack "="
                                   , docAddBaseY BrIndentRegular $ x
                                   ]
                  Nothing -> docEmpty
              ]
            lineR = rFr <&> \(lfield, fText, fDoc) -> docWrapNode lfield $ docCols ColRecUpdate
              [ appSep $ docLit $ Text.pack ","
              , appSep $ docLit $ fText
              , case fDoc of
                  Just x ->  docSeq [ appSep $ docLit $ Text.pack "="
                                    , docAddBaseY BrIndentRegular x
                                    ]
                  Nothing -> docEmpty
              ]
            lineN = docSeq
              [ docNodeAnnKW lexpr (Just AnnOpenC) docEmpty
              , docLit $ Text.pack "}"
              ]
            in [line1] ++ lineR ++ [lineN])
      ]
  ExprWithTySig exp1 (HsIB _ (HsWC _ _ typ1)) -> do
    expDoc <- docSharedWrapper layoutExpr exp1
    typDoc <- docSharedWrapper layoutType typ1
    docSeq
      [ appSep expDoc
      , appSep $ docLit $ Text.pack "::"
      , typDoc
      ]
  ExprWithTySigOut{} -> do
    -- TODO
    unknownNodeError "ExprWithTySigOut{}" lexpr
  ArithSeq _ Nothing info ->
    case info of
      From e1 -> do
        e1Doc <- docSharedWrapper layoutExpr e1
        docSeq
          [ docLit $ Text.pack "["
          , appSep $ docForceSingleline e1Doc
          , docLit $ Text.pack "..]"
          ]
      FromThen e1 e2 -> do
        e1Doc <- docSharedWrapper layoutExpr e1
        e2Doc <- docSharedWrapper layoutExpr e2
        docSeq
          [ docLit $ Text.pack "["
          , docForceSingleline e1Doc
          , appSep $ docLit $ Text.pack ","
          , appSep $ docForceSingleline e2Doc
          , docLit $ Text.pack "..]"
          ]
      FromTo e1 eN -> do
        e1Doc <- docSharedWrapper layoutExpr e1
        eNDoc <- docSharedWrapper layoutExpr eN
        docSeq
          [ docLit $ Text.pack "["
          , appSep $ docForceSingleline e1Doc
          , appSep $ docLit $ Text.pack ".."
          , docForceSingleline eNDoc
          , docLit $ Text.pack "]"
          ]
      FromThenTo e1 e2 eN -> do
        e1Doc <- docSharedWrapper layoutExpr e1
        e2Doc <- docSharedWrapper layoutExpr e2
        eNDoc <- docSharedWrapper layoutExpr eN
        docSeq
          [ docLit $ Text.pack "["
          , docForceSingleline e1Doc
          , appSep $ docLit $ Text.pack ","
          , appSep $ docForceSingleline e2Doc
          , appSep $ docLit $ Text.pack ".."
          , docForceSingleline eNDoc
          , docLit $ Text.pack "]"
          ]
  ArithSeq{} ->
    unknownNodeError "ArithSeq" lexpr
  PArrSeq{} -> do
    -- TODO
    unknownNodeError "PArrSeq{}" lexpr
  HsSCC{} -> do
    -- TODO
    unknownNodeError "HsSCC{}" lexpr
  HsCoreAnn{} -> do
    -- TODO
    unknownNodeError "HsCoreAnn{}" lexpr
  HsBracket{} -> do
    -- TODO
    unknownNodeError "HsBracket{}" lexpr
  HsRnBracketOut{} -> do
    -- TODO
    unknownNodeError "HsRnBracketOut{}" lexpr
  HsTcBracketOut{} -> do
    -- TODO
    unknownNodeError "HsTcBracketOut{}" lexpr
  HsSpliceE{} -> do
    -- TODO
    unknownNodeError "HsSpliceE{}" lexpr
  HsProc{} -> do
    -- TODO
    unknownNodeError "HsProc{}" lexpr
  HsStatic{} -> do
    -- TODO
    unknownNodeError "HsStatic{}" lexpr
  HsArrApp{} -> do
    -- TODO
    unknownNodeError "HsArrApp{}" lexpr
  HsArrForm{} -> do
    -- TODO
    unknownNodeError "HsArrForm{}" lexpr
  HsTick{} -> do
    -- TODO
    unknownNodeError "HsTick{}" lexpr
  HsBinTick{} -> do
    -- TODO
    unknownNodeError "HsBinTick{}" lexpr
  HsTickPragma{} -> do
    -- TODO
    unknownNodeError "HsTickPragma{}" lexpr
  EWildPat{} -> do
    docLit $ Text.pack "_"
  EAsPat{} -> do
    -- TODO
    unknownNodeError "EAsPat{}" lexpr
  EViewPat{} -> do
    -- TODO
    unknownNodeError "EViewPat{}" lexpr
  ELazyPat{} -> do
    -- TODO
    unknownNodeError "ELazyPat{}" lexpr
  HsWrap{} -> do
    -- TODO
    unknownNodeError "HsWrap{}" lexpr

litBriDoc :: HsLit -> BriDocFInt
litBriDoc = \case
  HsChar       t _c           -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ ['\'', c, '\'']
  HsCharPrim   t _c           -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ ['\'', c, '\'']
  HsString     t _fastString  -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ FastString.unpackFS fastString
  HsStringPrim t _byteString  -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ Data.ByteString.Char8.unpack byteString
  HsInt        t _i           -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ show i
  HsIntPrim    t _i           -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ show i
  HsWordPrim   t _i           -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ show i
  HsInt64Prim  t _i           -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ show i
  HsWord64Prim t _i           -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ show i
  HsInteger    t _i _type     -> BDFLit $ Text.pack t -- BDFLit $ Text.pack $ show i
  HsRat        (FL t _) _type -> BDFLit $ Text.pack t
  HsFloatPrim  (FL t _)       -> BDFLit $ Text.pack t
  HsDoublePrim (FL t _)       -> BDFLit $ Text.pack t

overLitValBriDoc :: OverLitVal -> BriDocFInt
overLitValBriDoc = \case
  HsIntegral t _        -> BDFLit $ Text.pack t
  HsFractional (FL t _) -> BDFLit $ Text.pack t
  HsIsString t _        -> BDFLit $ Text.pack t
