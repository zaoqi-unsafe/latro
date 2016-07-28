#lang at-exp racket

(module+ test
  (require "common.rkt"
           rackunit)

  (test-case "it distinguishes between type and value names in annotations"
    (check-equal?
      @interp-sexp{
        type foo = Int

        foo : foo -> foo -> foo
        foo(a, b) = a + b

        main(_) = IO.println(foo(2, 4))
      }
      6))

  (test-case "it respects lexical scope for functions"
    (check-equal?
      @interp-sexp{
        def v = 42
        foo(v) = v + 1

        main(_) = IO.println(v + foo(3))
      }
      46))

  (test-case "it does not export local definitions on modules"
    (check-match
      @interp-sexp{
        module M {
          f() {
            def v = 3
            v
          }
        }

        main(_) = IO.println(M.v)
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (UnboundRawIdentifier v))))

  (test-case "it does not allow rebinding in the same scope"
    (check-match
      @interp-sexp{
        main(_) {
          def v = 42
          def v = 43
          IO.println(v)
        }
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (IdAlreadyBound v))))

  (test-case "it does not allow rebinding of an id to a module"
    (check-match
      @interp{
        def m = 42
        module m {
          def x = 43
        }

        main(_) = ()
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (IdAlreadyBound m))))

  (test-case "it does allow rebinding in nested scopes"
    (check-equal?
      @interp-sexp{
        def v = 42

        main(_) {
          def x = fun(x) { def v = 43  v }(1)
          IO.println(x)
        }
      }
      43))

  (test-case "it allows rebinding in a nested 'if' scope"
    (check-equal?
      @interp-lines{
        module m {
          def x = False

          f() {
            if (True) {
              def x = 42
            } else {
              ()
            }
          }
        }

        main(_) {
          def %(a, b) = %(m.f(), m.x)
          IO.println(a)
          IO.println(b)
        }
      }
      '("Unit"
        "False"
        "Unit")))

  (test-case "it refers to the correct value after a rebinding in a nested scope"
    (check-equal?
      @interp-sexp{
        def v = 3

        main(_) {
          def v = fun(x) { def v = 43  v }(1) + v
          IO.println(v)
        }
      }
      46))

  (test-case "it resolves module-scoped types with matching names"
    (check-equal?
      @interp-sexp{
        module Number {
          type t = Int
        }

        module Div {
          type t =
            | Num(Number.t)
            | ByZero

          div(x, 0) = ByZero()
          div(x, y) = Num(x / y)
        }

        main(_) {
          def Div.Num(answer) = Div.div(100, 10)
          IO.println(answer)
        }
      }
      10))

  (test-case "it scopes shadowing type identifiers"
    (check-equal?
      @interp-sexp{
        module I {
          type t = Int

          module B {
            type t = Bool

            boolId : t -> t
            boolId(b) = b
          }

          intId : t -> t
          intId(i) = i
        }

        main(_) = IO.println(I.B.boolId(False))
      }
      'False))

  (test-case "it does not add bindings introduced in subexpressions to the module export env"
    (check-match
      @interp-sexp{
        module m {
          f() {
            if (True) {
              def x = 42
            } else {
              ()
            }
          }
        }

        main(_) = IO.println(m.x)
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (UnboundRawIdentifier x))))

  (test-case "it does not add locals in function bodies to the module export env"
    (check-match
      @interp-sexp{
        module m {
          f : (-> Int)
          f() {
            def x = 42
            x
          }
        }

        main(_) = IO.println(m.x)
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (UnboundRawIdentifier x))))

  (test-case "it does not re-export imported bindings"
    (check-match
      @interp-sexp{
        module Foo {
          def v = 42
        }

        module Bar {
          import Foo
        }

        main(_) = IO.println(Bar.v)
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (UnboundRawIdentifier v))))

  (test-case "it does not allow bindings in a pattern to escape into other clauses"
    (check-match
      @interp-sexp{
        type Foo =
          | B(Bool)
          | I(Int)

        main(_) {
          def _ = switch (I(42)) {
              case I(x) -> x
              case B(b) -> x
            }
        }
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (UnboundRawIdentifier x))))

  (test-case "it does not allow bindings to escape from then/else scopes"
    (check-match
      @interp-sexp{
        main(_) {
          def v = if (True) {
            def x = 42
            x
          } else { 0 }

          IO.println(x)
        }
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (UnboundRawIdentifier x))))

  (test-case "it does not allow bindings to escape the test exp of an if/else"
    (check-match
      @interp-sexp{
        main(_) {
          def _ = if (if (True) { def x = 42 True } else { False }) {
              x
            } else {
              x
            }
        }
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (UnboundRawIdentifier x))))

  (test-case "it does not require type definitions to be in order"
    (check-equal?
      @interp-sexp{
        type foo = bar
        type bar = Int

        x : foo
        def x = 42

        main(_) = IO.println(x)
      }
      42))

  (test-case "it allows circular dependencies between types"
    (check-equal?
      @interp-lines{
        type Expr =
          | ExprNum(Int)
          | ExprStm(Stm)

        type Stm =
          | StmDef(Char[], Expr)

        main(_) = IO.println([ StmDef("x", ExprNum(42)) ])
      }
      '("[StmDef(\"x\", ExprNum(42))]"
        "Unit")))

  (test-case "it allows circular dependencies between module-level types"
    (check-equal?
      @interp-lines{
        module Expr {
          type t =
            | ExprNum(Int)
            | ExprStm(Stm.t)
        }

        module Stm {
          type t =
            | StmDef(Char[], Expr.t)
        }

        main(_) = IO.println([ Stm.StmDef("x", Expr.ExprNum(42)) ])
      }
      '("[StmDef(\"x\", ExprNum(42))]"
        "Unit")))

  (test-case "it allows use-before-defines in top-level definitions"
    (check-equal?
      @interp-sexp{
        def y = x
        def x = 42

        main(_) = IO.println(y)
      }
      42))

  (test-case "it allows use-before-defines in module-level definitions"
    (check-equal?
      @interp-sexp{
        module M {
          def y = x
          def x = 42
        }

        main(_) = IO.println(M.y)
      }
      42))

  (test-case "it allows use-before-defines that refer to other modules"
    (check-equal?
      @interp-sexp{
        module M {
          def y = N.x
        }

        module N {
          def x = 42
        }

        main(_) = IO.println(M.y)
      }
      42))

  (test-case "it does not allow use-before-defines in local contexts"
    (check-match
      @interp-sexp{
        foo(a) {
          def x = y
          def y = a

          x + y
        }
      }
      `(AtPos ,_ (CompilerModule AlphaConvert) (UnboundRawIdentifier y))))

  (test-case "it fails on incorrect qualified paths"
    (check-match
      @interp-sexp{
        module M {
          module N {
            def foo = 42
          }
        }

        module M' {
          def bar = N.foo
        }

        main(_) = IO.println(M'.bar)
      }
      `(AtPos (SourcePos ,_ 8 ,_) (CompilerModule AlphaConvert) (UnboundRawIdentifier N))))

  (test-case "it does not extend type name resolution to closures of closed modules"
    (check-match
      @interp-sexp{
        type Str = Char[]

        module M { }

        f : M.Str -> M.Str
        f(s) { s }
      }
      `(AtPos (SourcePos ,_ 5 ,_) (CompilerModule AlphaConvert) (UnboundRawIdentifier Str))))

  (test-case "it does not extend variable name resolution to closures of closed modules"
    (check-match
      @interp{
        def foo = 42

        module M {
          def bar = foo
        }

        main(_) = IO.println(M.foo + M.bar)
      }
      `(AtPos (SourcePos ,_ 7 ,_) (CompilerModule AlphaConvert) (UnboundRawIdentifier foo))))

  (test-case "it can resolve pattern names in the module closure"
    (check-equal?
      @interp-sexp{
        module Root {
          type A = | Foo(Int) | Bar(Int)

          module M {
            f(a) {
              switch (a) {
                case Foo(x) -> x
                case _ -> 0
              }
            }
          }
        }

        main(_) = IO.println(Root.M.f(Root.Foo(43)))
      }
      43))

  (test-case "does not re-export pattern names from the module closure"
    (check-match
      @typecheck{
        type A = | Foo(Int) | Bar(Int)

        module M { }

        main(_) {
          def v = switch (Foo(42)) {
            case M.Foo(x) -> x
            case _ -> 0
          }

          IO.println(v)
        }
      }
      `(AtPos (SourcePos ,_ 7 ,_) (CompilerModule AlphaConvert) (UnboundRawIdentifier Foo))))

  (test-case "it does not allow module-exported type bindings to escape"
    (check-match
      @typecheck{
        module Geometry {
          type Point = struct {
            Int X;
            Int Y;
          }
        }

        main(_) {
          def p = Point %{ X = 0; Y = 0; }
          IO.println(p)
        }
      }
      `(AtPos (SourcePos ,_ 9 ,_) (CompilerModule AlphaConvert) (UnboundRawIdentifier Point))))
)