import           Control.Monad.State
import           Data.List                               (isPrefixOf)
import           System.Console.Haskeline
import           System.Console.Haskeline.MonadException
import           System.Exit
import           Text.Parsec
import           Unbound.LocallyNameless                 hiding (rnf)
import           Unbound.LocallyNameless.Subst

import           Disco.Desugar
import           Disco.Interpret.Core
import           Disco.Parser
import           Disco.Pretty
import           Disco.Typecheck
import           Disco.Types

import           Queue

type Qelm = (Name Term, Term)
type REPLStateIO = StateT (Queue Qelm) IO

-- HDE: Is there a way around this?
instance MonadException m => MonadException (StateT s m) where
    controlIO f = StateT $ \s -> controlIO $ \(RunIO run) -> let
                    run' = RunIO (fmap (StateT . const) . run . flip runStateT s)
                    in fmap (flip runStateT s) $ f run'

io :: IO a -> REPLStateIO a
io i = liftIO i

pop :: REPLStateIO (Name Term, Term)
pop = get >>= return.headQ

push :: Qelm -> REPLStateIO ()
push t = get >>= put.(`snoc` t)

unfoldDefsInTerm :: (Queue Qelm) -> Term -> Term
unfoldDefsInTerm q t =
    let uq = toListQ $ unfoldQueue q
     in substs uq t

unfoldQueue :: (Queue Qelm) -> (Queue Qelm)
unfoldQueue q = fixQ q emptyQ step
 where
   step e@(x,t) _ r = (mapQ (substDef x t) r) `snoc` e
    where
      substDef :: Name Term -> Term -> Qelm -> Qelm
      substDef x t (y, t') = (y, subst x t t')

------------------------------------------------------------------------
-- Parsers for the REPL                                               --
------------------------------------------------------------------------

data REPLExpr =
   Let (Name Term) Term         -- Toplevel let-expression: for the REPL
 | TypeCheck Term               -- Typecheck a term
 | Eval Term                    -- Evaluate a term
 | ShowAST Term                 -- Show a terms AST
 | DumpState                    -- Trigger to dump the state for debugging.
 | Unfold Term                  -- Unfold the definitions in a term for debugging.
 | Parse Term                   -- Show the parsed AST
 | Desugar Term                 -- Show a desugared term
 deriving Show

letParser = do
  reservedOp "let"
  n <- ident
  symbol "="
  t <- parseTerm
  eof
  return $ Let n t

replTermCmdParser cmd c p = do
  symbol ":"
  ucmd <- many lower
  whiteSpace
  t <- p
  eof
  if (ucmd `isPrefixOf` cmd)
  then return $ c t
  else fail $ "Command \":"++cmd++"\" is unrecognized."

replIntCmdParser cmd c = do
  symbol ":"
  ucmd <- many lower
  whiteSpace
  eof
  if (ucmd `isPrefixOf` cmd)
  then return c
  else fail $ "Command \":"++cmd++"\" is unrecognized."

evalParser = do
  t <- parseTerm
  eof
  return.Eval $ t

typeCheckParser  = replTermCmdParser "type"   TypeCheck parseTerm
showASTParser    = replTermCmdParser "show"   ShowAST   parseTerm
unfoldTermParser = replTermCmdParser "unfold" Unfold    parseTerm
dumpStateParser  = replIntCmdParser  "dump"   DumpState
parseTermParser  = replTermCmdParser "parse"  Parse     parseTerm
desugarTermParser = replTermCmdParser "desugar" Desugar parseTerm

lineParser = letParser
          <|> try typeCheckParser
          <|> try evalParser
          <|> try showASTParser
          <|> try unfoldTermParser
          <|> try dumpStateParser
          <|> try evalParser
          <|> try parseTermParser
          <|> try desugarTermParser

parseLine :: String -> Either String REPLExpr
parseLine s = case (parse lineParser "" s) of
                Left msg -> Left $ show msg
                Right l -> Right l

handleCMD :: String -> REPLStateIO ()
handleCMD "" = return ()
handleCMD s =
    case (parseLine s) of
      Left msg -> io $ putStrLn msg
      Right l -> handleLine l
  where
    handleLine :: REPLExpr -> REPLStateIO ()
    handleLine (Let x t) = push (x , t)
    handleLine (TypeCheck t) = (type_check t) >>= (io.putStrLn)
    handleLine (Eval t) = (eval t) >>= (io.putStrLn)
    handleLine (ShowAST t) = get >>= (\defs -> io.putStrLn.show $ unfoldDefsInTerm defs t)
    handleLine (Unfold t) = get >>= (\defs -> io.putStrLn.renderDoc.prettyTerm $ unfoldDefsInTerm defs t)
    handleLine DumpState = get >>= io.print.(mapQ prettyDef)
     where
       prettyDef (x, t) = "let "++(name2String x)++" = "++(renderDoc.prettyTerm $ t)
    handleLine (Parse t) = io.print $ t
    handleLine (Desugar t) = handleDesugar t >>= (io.putStrLn)

handleDesugar :: Term -> REPLStateIO String
handleDesugar t = do
  case evalTCM (infer t) of
    Left err -> return.show $ err
    Right at -> return.show.runDSM.desugar $ at

eval :: Term -> REPLStateIO String
eval t = do
  defs <- get
  let tu = unfoldDefsInTerm defs t
   in case evalTCM (infer tu) of
        Left err -> return.show $ err
        Right at ->
            let ty = getType at
                c  = runDSM $ desugar at
             in case runIM (rnf c) of
                  Left err -> return.show $ err
                  Right v  -> return $ prettyValue ty v

type_check :: Term -> REPLStateIO String
type_check t = do
  defs <- get
  let tu = unfoldDefsInTerm defs t
   in case (evalTCM.infer $ tu) of
        Left err -> return.show $ err
        Right at -> return.renderDoc.prettyTy.getType $ at

banner :: String
banner = "Welcome to Disco!\n\nA language for programming discrete mathematics.\n\n"

main :: IO ()
main = do
  let settings = defaultSettings
        { historyFile = Just ".disco_history" }
  putStr banner
  evalStateT (runInputT settings loop) emptyQ
   where
       loop :: InputT REPLStateIO ()
       loop = do
           minput <- getInputLine "Disco> "
           case minput of
               Nothing -> return ()
               Just input | input `isPrefixOf` ":quit" -> liftIO $ putStrLn "Goodbye!" >> return ()
                          | otherwise -> (lift.handleCMD $ input) >> loop