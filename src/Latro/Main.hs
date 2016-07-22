module Main where

import AlphaConvert
import Collapse
import Common
import Compiler
import Control.Exception.Base (evaluate)
import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Trans.Class
import Data.Char (toLower)
import Data.Functor.Identity (runIdentity)
import Data.List (intersperse)
import Errors
import Errors.Display
import ILGen
import Parse
import Interp
import Reorder
import Semant
import Semant.Display
import Sexpable
import System.Console.GetOpt
import System.Console.Haskeline
import System.Environment (getArgs)
import System.Exit
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import Types


combineAsts :: [RawAst CompUnit] -> RawAst CompUnit
combineAsts cus =
  CompUnit mtSourcePos $ concatMap (\(CompUnit _ bodyEs) -> bodyEs) cus


flags =
  [ Option "a" [] (ReqArg (OptShowPhaseOutput . readPhaseName) "PHASE")
      "Stop after PHASE and show its output"
  , Option "e" ["eval"] (ReqArg OptEvaluateExpr "EXPR")
      "Evaluate 'expr' in an interactive-prompt style context"
  , Option "l" ["lib"] (ReqArg OptLoadFile "FILE")
      "Load FILE as a library source (useful in concert with -e)"
  , Option "i" ["repl"] (NoArg OptInteractive)
      "Run interactive read-eval-print loop"
  , Option "s" ["sexp"] (NoArg OptSexp)
      "Display output as an s-expression (only available in non-interactive mode)"
  , Option "h" ["help"] (NoArg OptHelp)
      "Show help"
  ]


data Phase =
    PhaseParse
  | PhaseAlphaConvert
  | PhaseInfixReorder
  | PhaseILGen
  | PhaseTypecheckType
  | PhaseTypecheckAst
  | PhaseUnknown String
  deriving (Eq, Show)


readPhaseName :: String -> Phase
readPhaseName name =
  case map toLower name of
    "parse" -> PhaseParse
    "alpha" -> PhaseAlphaConvert
    "infix" -> PhaseInfixReorder
    "ilgen" -> PhaseILGen
    "type"  -> PhaseTypecheckType
    "typed" -> PhaseTypecheckAst
    _       -> PhaseUnknown name


data Opt =
    OptShowPhaseOutput Phase
  | OptEvaluateExpr ProgramText
  | OptLoadFile FilePath
  | OptInteractive
  | OptSexp
  | OptHelp
  deriving (Eq, Show)


optEnabled :: Opt -> [Opt] -> Bool
optEnabled = elem


data ReplCmd =
    ReplCmdQuit
  | ReplCmdLibFile FilePath
  | ReplCmdShowType ProgramText
  | ReplCmdEval ProgramText
  deriving (Eq)


type ProgramText = String


data SourceBuf =
    SourceBufFile FilePath ProgramText
  | SourceBufRepl ProgramText


fileSourceBufs :: [FilePath] -> [ProgramText] -> [SourceBuf]
fileSourceBufs = zipWith SourceBufFile


breakIfOpt :: Sexpable a => [Opt] -> Opt -> CompilerPass CompilerEnv a -> GenericCompilerPass Sexp CompilerEnv a
breakIfOpt opts opt m = do
  result <- withExceptT sexp m
  if optEnabled opt opts
    then ExceptT . return $ Left $ sexp result
    else return result


parseBuf :: SourceBuf -> GenericCompilerPass Sexp CompilerEnv (RawAst CompUnit)
parseBuf buf =
    withExceptT sexp $ ExceptT . return $ syntaxRule path source
  where
    (path, source, syntaxRule) = case buf of
      SourceBufFile path source -> (path, source, parseTopLevel)
      SourceBufRepl source      -> ("<<repl>>", source, parseInteractive)


semAnal :: [SourceBuf] -> [Opt] -> GenericCompilerPass Sexp CompilerEnv (Typed ILCompUnit)
semAnal sourceBufs opts = do
    asts <- mapM parseBuf sourceBufs
    let ast = combineAsts asts
    collapsedAst <- withExceptT sexp $ runCollapseFunClauses ast
    alphaConvertedAst <- dumpOnPhase PhaseAlphaConvert $ runAlphaConvert collapsedAst
    reorderedAst <- dumpOnPhase PhaseInfixReorder $ runReorderInfixes alphaConvertedAst
    untypedIL <- dumpOnPhase PhaseILGen $ runILGen reorderedAst
    (ty, typedIL) <- withExceptT sexp $ runTypecheck untypedIL
    case opts of
      _ | optEnabled (OptShowPhaseOutput PhaseTypecheckType) opts -> throwError $ sexp ty
        | optEnabled (OptShowPhaseOutput PhaseTypecheckAst) opts  -> throwError $ sexp typedIL
        | otherwise -> return typedIL
  where
    dumpOnPhase ph = breakIfOpt opts $ OptShowPhaseOutput ph


eval :: [SourceBuf] -> [Opt] -> GenericCompilerPassT Sexp CompilerEnv IO Value
eval sourceBufs opts = do
  compilerEnv <- get
  let (semantResult, compilerEnv') = runState (runExceptT (semAnal sourceBufs opts)) compilerEnv
  case semantResult of
    Left sxp -> ExceptT . return $ Left sxp
    Right typedIL -> do put compilerEnv'
                        withExceptT sexp $ interp typedIL


readReplCmd :: InputT IO ReplCmd
readReplCmd = do
  input <- getInputLine "λ> "
  case input of
    Nothing -> return ReplCmdQuit
    Just input ->
      case words input of
        [] -> return ReplCmdQuit
        [":q"] -> return ReplCmdQuit
        (":t" : rest) ->
          return $ ReplCmdShowType $ unwords rest
        [":l", inputFilePath] ->
          return $ ReplCmdLibFile inputFilePath
        _ -> return $ ReplCmdEval input


loadLibFiles :: [Opt] -> CompilerEnv -> InputT IO (Either Sexp Value, CompilerEnv)
loadLibFiles ((OptLoadFile path) : opts) compilerEnv = do
  content <- lift $ readFile path
  (_, compilerEnv') <- lift $ runStateT (runExceptT (eval [SourceBufFile path content] opts)) compilerEnv
  loadLibFiles opts compilerEnv'
loadLibFiles (_ : opts) compilerEnv = loadLibFiles opts compilerEnv
loadLibFiles [] compilerEnv = return (Right ValueUnit, compilerEnv)


handleEvalResult :: (CompilerEnv -> InputT IO ())
                 -> (Value -> InputT IO ())
                 -> InputT IO (Either Sexp Value, CompilerEnv)
                 -> InputT IO ()
handleEvalResult k vHandler result = do
  (result, compilerEnv) <- result
  case result of
    Left sxp -> outputStrLn $ show sxp
    Right v  -> vHandler v
  k compilerEnv


runRepl :: [Opt] -> IO ()
runRepl opts =
    runInputT defaultSettings $ handleEvalResult loop (\_ -> return ()) $ loadLibFiles opts mt
  where env = mt :: CompilerEnv
        loop :: CompilerEnv -> InputT IO ()
        loop compilerEnv = do
          cmd <- readReplCmd
          case cmd of
            ReplCmdQuit -> return ()
            ReplCmdLibFile filePath -> do
              content <- lift $ readFile filePath
              let result = lift $ runStateT (runExceptT (eval [SourceBufFile filePath content] opts)) compilerEnv
              handleEvalResult loop (outputStrLn . show) result
            ReplCmdShowType input -> do
              outputStrLn "some type"
              loop compilerEnv
            ReplCmdEval input -> do
              let result = lift $ runStateT (runExceptT (eval [SourceBufRepl input] opts)) compilerEnv
              handleEvalResult loop (outputStrLn . show) result


runProgram :: [Opt] -> [FilePath] -> IO ()
runProgram opts filePaths = do
  sources <- mapM readFile filePaths
  (result, _) <- runStateT (runExceptT (eval (fileSourceBufs filePaths sources) opts)) mt
  case result of
    Left sxp  -> print sxp
    Right v   -> print v


header = "Usage: latro [-aelis] [FILE ...]"


parseOpts :: [String] -> IO ([Opt], [FilePath])
parseOpts args =
  case getOpt Permute flags args of
    (opts, fs, []) -> return (opts, fs)
    (_, _, errs)   -> do
      hPutStrLn stderr (concat errs ++ usageInfo header flags)
      exitWith (ExitFailure 1)


main :: IO ()
main = do
  args <- getArgs
  (opts, inputFiles) <- parseOpts args
  case () of
    _ | optEnabled OptHelp opts -> do
        hPutStrLn stderr (usageInfo header flags)
        exitWith ExitSuccess
      | null inputFiles -> runRepl opts
      | optEnabled OptInteractive opts -> runRepl opts
      | otherwise -> runProgram opts inputFiles
