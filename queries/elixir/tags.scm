; ripwire Elixir tags — written for ripwire (.ex/.exs). Derived from the upstream
; elixir-lang/tree-sitter-elixir v0.3.5 node-types.json and verified against real parses
; (test/elixirfix + the AST dump `--match` prints).
;
; ── WHY THIS QUERY LOOKS NOTHING LIKE UPSTREAM'S ────────────────────────────────────────────────
; Elixir is homoiconic and its grammar says so: there are 45 named node types and NOT ONE of them is
; a definition. `defmodule Foo do … end`, `def greet(n) do … end`, `alias Foo.Bar` and an ordinary
; `greet("x")` are ALL the same node — `(call target: (identifier) …)`. What separates them is the
; TEXT of the target identifier, nothing else.
;
; Upstream's queries/tags.scm settles that with `#any-of?` predicates. In ripwire that would be a
; SILENT NO-OP: query predicates are wired into --match/--lint only, never the tags pass (see
; ingest_names.h's isCppCastKeyword note, which records the same trap costing --uses=static_cast 165
; phantom rows). A ported-as-is upstream query does not narrow — it captures every call in the file
; as a module AND as a function AND as a call.
;
; So the discrimination lives where it is actually enforceable: the patterns below are LOOSE and
; STRUCTURAL, each carries an Elixir-only capture name, and ingest_names.h::elixirDefCaptureDropped
; reads the outer call's target text once and drops every capture whose keyword does not match. The
; four capture names are `definition.exmod` / `.exproto` / `.exdef` / `.exmacro`; they are Elixir-only
; so no other language pays a branch for any of this. Patterns that overlap (a `defmodule` and a
; `defprotocol` are the same shape; so are a `def` and a `defmacro`) are written twice on purpose —
; both match, and the gate keeps exactly one.
;
; ── WHAT IS CAPTURED ────────────────────────────────────────────────────────────────────────────
;   defmodule Foo.Bar do          → t="cls"    (Elixir's ONLY named container of functions; the thing
;                                               a remote call `Foo.Bar.baz()` names. Elixir has no
;                                               class, so mapping this to `other` would leave every
;                                               container in an Elixir map untyped.)
;   defprotocol Foo do            → t="iface"  (a named set of callbacks implemented elsewhere)
;   def/defp/defdelegate/defn/defnp → t="fn"
;   defmacro/defmacrop/defguard/defguardp → t="macro" (callable, expanded at compile time — the same
;                                               honest kind Rust's macro_definition already takes)
;   f(..) / Mod.f(..) / x |> f    → reference.call
;   alias/import/require/use Mod  → reference.import (role="import" use-sites, exactly like C++'s
;                                               `using ns::name;` — NOT a file-include edge; see below)
;
; ── DISCLOSED FLOORS (decisions, not drift — asserted by test/elixircheck.sh so they stay decisions) ──
;   - `defimpl Foo, for: Bar` mints NO symbol. It defines the module `Foo.Bar`, a name that appears
;     nowhere in the source text; naming it `Foo` would put a wrong name in the map, which is the one
;     direction the honesty rule forbids. Its `def`s are still captured — they are ordinary defs
;     inside it — so the functions are visible and only the synthetic container name is absent.
;   - IMPORTS ARE NOT FILE EDGES. `alias`/`import`/`require`/`use` name MODULES, and Elixir's
;     module→file mapping is a convention (`lib/foo/bar.ex`), not a rule the compiler enforces — one
;     .ex file may define any number of modules. So Elixir is deliberately absent from lintrules.h's
;     dependencyCapable set: an Elixir file is never a node in the --deps/--arch graph, and a zero
;     there means "not measured", never "none exists". The reference.import capture above still gives
;     `--uses` its role="import" use-sites, which is a name edge and claims to be nothing more.
;   - DYNAMIC DISPATCH names nothing: `apply(mod, fun, args)`, `Kernel.apply/3`, a captured function
;     `&Mod.fun/1` passed and then called, and protocol dispatch itself (the whole point of a protocol
;     is that the callee is chosen at run time). None produce an edge.
;   - METAPROGRAMMING. A `def` generated inside `quote do … end` by a macro — Ecto's `schema`, Phoenix's
;     `router`, `use ExUnit.Case`'s injected callbacks — exists only after expansion. ripwire reads
;     source text, so those defs are invisible. This is Elixir's single largest extraction floor and it
;     is structural, not a bug: `test "it works" do` in an ExUnit file is a macro call, not a def.
;   - MODULE ATTRIBUTES (`@moduledoc`, `@default "x"`, `@behaviour Foo`) are not captured. They are
;     unary_operator nodes over a call, they are lower-case by convention so the SCREAMING_SNAKE
;     constant policy every other language's @definition.constant rides could not gate them, and
;     `defstruct` fields are a keyword list, not named declarations.
;   - COMPLEXITY IS A FLOOR OF 1. `if`/`case`/`cond`/`unless`/`for`/`with`/`try` are macro CALLS in
;     this grammar, not statement node types, so ingest_metrics.h's decision-point table — which is
;     keyed on node type across every other grammar — finds nothing to count. cx/ccx therefore read 1
;     for every Elixir function. That is "no decision points found", the safe direction, and Elixir is
;     correspondingly absent from evCountedLang.

; ══ definitions ═════════════════════════════════════════════════════════════════════════════════
; Every pattern here also matches ordinary calls of the same shape (`assert Foo`, `send pid, msg`).
; elixirDefCaptureDropped is what makes each one mean what its capture name says.

; defmodule Foo.Bar do … end   —   and the identical-shape `defprotocol Foo do … end`.
; The `(do_block)` is load-bearing, not decoration: it is the one structural fact that separates a
; module DEFINITION from the directive `alias Foo.Bar`, which is the same call with the same first
; argument and no block.
(call
  target: (identifier)
  (arguments . (alias) @name)
  (do_block)) @definition.exmod

(call
  target: (identifier)
  (arguments . (alias) @name)
  (do_block)) @definition.exproto

; def greet(name) do … end   /   defp emit(text) do … end   /   def greet(_), do: @default
; The leading anchor pins the name to the FIRST argument, so `def foo(bar())` cannot bind `bar`.
(call
  target: (identifier)
  (arguments . (call target: (identifier) @name))) @definition.exdef

(call
  target: (identifier)
  (arguments . (call target: (identifier) @name))) @definition.exmacro

; def greet(name) when is_name(name) do … end — the guard clause wraps the head in a binary_operator.
(call
  target: (identifier)
  (arguments . (binary_operator
    left: (call target: (identifier) @name)
    operator: "when"))) @definition.exdef

(call
  target: (identifier)
  (arguments . (binary_operator
    left: (call target: (identifier) @name)
    operator: "when"))) @definition.exmacro

; def version do … end — a zero-arity head written without parentheses is a bare identifier.
(call
  target: (identifier)
  (arguments . (identifier) @name)
  (do_block)) @definition.exdef

(call
  target: (identifier)
  (arguments . (identifier) @name)
  (do_block)) @definition.exmacro

; ══ references ══════════════════════════════════════════════════════════════════════════════════

; f(..) — a local call. This pattern ALSO names `def`, `defmodule`, `case`, `if` and every other
; special form, because in this grammar they are all local calls; ingest_sidecap.h skips those by
; keyword text (elixirNonCallKeyword), the same way a C++ cast keyword is skipped there.
(call
  target: (identifier) @name) @reference.call

; Mod.f(..) — a remote call. The captured name is the final identifier, which is what byName resolves
; on; the module half rides the reference.import edges above.
(call
  target: (dot right: (identifier) @name)) @reference.call

; x |> f — a pipe into a BARE name. `x |> f()` is already the local-call pattern above.
(binary_operator
  operator: "|>"
  right: (identifier) @name) @reference.call

; alias Foo.Bar / import Foo / require Logger / use GenServer — same shape as `defmodule Foo` minus
; the do_block. Kept only for the four directive keywords (elixirImportDirectiveKept).
(call
  target: (identifier)
  (arguments . (alias) @name)) @reference.import
