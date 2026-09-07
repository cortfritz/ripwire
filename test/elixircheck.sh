#!/usr/bin/env bash
# elixircheck.sh — the Elixir ingest coverage gate (grammar + tags.scm + the four gated capture classes).
#
# Modeled on luacheck.sh / phpcheck.sh: a small fixture, every assertion pinned to what the binary
# ACTUALLY does (each number below was read off a real run before it was written down), plus mutation arms
# so the edge/keyword assertions are non-tautological.
#
# ── WHY THIS GATE IS NOT VACUOUS ──────────────────────────────────────────────────────────────────────
# Against a binary with no Elixir grammar, every .ex/.exs file leaves the index as `why="unsupported-ext"`
# and the map reports files=0 symbols=0. That is the trivial red and it is NOT what this gate is for.
#
# Elixir is homoiconic: `defmodule Foo do`, `def greet(n) do`, `alias Foo.Bar` and `greet("x")` are ALL
# `(call target: (identifier) …)` — the SAME node type — and only the target's TEXT separates them. The
# upstream tags.scm settles that with `#any-of?` predicates, which are a SILENT NO-OP in ripwire's tags
# pass (ingest_names.h::isCppCastKeyword records the same trap costing --uses=static_cast 165 phantom
# rows). So a naive port of the upstream query does not narrow at ALL: every call in the file becomes a
# module AND a function AND a call, and a `files>0 symbols>0` gate would still be green.
#
# The arms below are therefore written against exactly the ways that failure shows up:
#   §2  each keyword lands in its OWN kind (a broken gate collapses them into one)
#   §4  `def` / `defmodule` / `if` are NOT symbols and NOT call targets (a missing keyword skip mints them)
#   §5  `alias` IS a role="import" use-site and `defmodule` is NOT (both are the same query pattern)
#   §6  a def's own HEAD is not a call to itself — the phantom `render → render` edge, MEASURED on this
#       fixture before elixirIsDefinitionHead existed, which is why §6 pins the edge COUNT, not just a name
#   §7  params are the head call's real formals, not the 0 the generic parameter-list search returns
#
# ── FIXTURE (test/elixirfix/) ─────────────────────────────────────────────────────────────────────────
#   lib/repo/greeter.ex    defmodule + alias/import/require + defstruct + @attr + defguard + defmacro
#                          def greet(name) when is_name(name)   -- the guarded head shape
#                          def greet(_other), do: @default      -- the keyword-body clause (2nd overload)
#                          def default do                       -- the bare zero-arity head shape
#                          defp emit(text)                      -- a private def, and a remote call out
#   lib/repo/formatter.ex  def title/1, def shout/1 -> title()  -- a same-file local call
#   lib/repo/util.ex       def trim(text), do: ...              -- one-line keyword body
#   lib/repo/render.ex     defprotocol + defimpl                -- the iface, and the impl that mints none
#   test/greeter_test.exs  use ExUnit.Case + `test "…" do`      -- the metaprogramming floor, in .exs
#
# ── FINDINGS from running `ripwire test/elixirfix` and reading the raw output ─────────────────────────
#   - 5 files / 17 symbols / edges=9 / ambiguous=0 / unresolved=0, clean stderr (no ABI/degrade line).
#   - `.exs` is indexed exactly like `.ex` — the test file contributes 2 of the 17 symbols.
#   - `defimpl Repo.Render, for: Repo.Greeter` mints NO container symbol (it defines `Repo.Render.Repo
#     .Greeter`, a name that is nowhere in the text) while its `def render` IS captured — so `render`
#     carries overloads="2", the protocol callback plus the impl clause.
#   - `test "it greets" do` mints NO def: it is a macro call. Its body's `Greeter.greet(…)` call is
#     attributed to the enclosing MODULE symbol, which is why GreeterTest (t="cls") carries an edge.
#   - cx is 1 for every Elixir function. `if`/`case`/`cond`/`with` are macro calls, not statement node
#     types, so isDecisionType has nothing to match. "No decision points found", the safe direction.
#
# Usage:
#   bash test/elixircheck.sh
#   RIPWIRE_BIN=build/ripwire bash test/elixircheck.sh
#   RIPWIRE_BIN=asan/ripwire  bash test/elixircheck.sh
#
# Exits non-zero on any failure; prints PASS/FAIL per check and ALL PASS on success.

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"          # allow a repo-relative RIPWIRE_BIN
FIX="$ROOT/test/elixirfix"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0

ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required for XML assertions"; exit 2; }
[ -d "$FIX" ] || { echo "no fixture at $FIX"; exit 2; }

echo "elixircheck: BIN=$BIN  FIX=$FIX"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 0. PRESENCE: the fixture really spells every shape the arms below assert ==="
# ═══════════════════════════════════════════════════════════════════════════
# A gate whose probe target can vanish passes for the wrong reason (CONTRIBUTING.md §2). These greps are
# the guard: if a fixture edit deletes a shape, THIS arm reds instead of the assertion going inert.
presence(){ grep -qF -- "$2" "$FIX/$1" && ok "fixture $1 spells: $3" || no "fixture $1 no longer spells: $3"; }
presence lib/repo/greeter.ex   'defmodule Repo.Greeter do'          'a defmodule with a dotted alias name'
presence lib/repo/greeter.ex   'def greet(name) when is_name(name)' 'the GUARDED head shape (binary_operator)'
presence lib/repo/greeter.ex   'def greet(_other), do:'             'the keyword-body clause (2nd overload)'
presence lib/repo/greeter.ex   'def default do'                     'the BARE zero-arity head shape'
presence lib/repo/greeter.ex   'defp emit(text) do'                 'a private def'
presence lib/repo/greeter.ex   'defguard is_name(n)'                'a defguard (macro family)'
presence lib/repo/greeter.ex   'defmacro trace(expr) do'            'a defmacro'
presence lib/repo/greeter.ex   'alias Repo.Formatter'               'an alias directive'
presence lib/repo/greeter.ex   'import Repo.Util'                   'an import directive'
presence lib/repo/greeter.ex   'require Logger'                     'a require directive'
presence lib/repo/greeter.ex   'defstruct'                          'a defstruct (deliberately not captured)'
presence lib/repo/greeter.ex   '|> trim()'                          'a pipe into a call'
presence lib/repo/render.ex    'defprotocol Repo.Render do'         'a defprotocol'
presence lib/repo/render.ex    'defimpl Repo.Render, for:'          'the defimpl whose container floor §3 asserts'
presence test/greeter_test.exs 'test "it greets" do'                'the ExUnit macro call the floor §3 asserts'
presence test/greeter_test.exs 'use ExUnit.Case'                    'a use directive'

MAP_OUT="$TMP/map.xml"
"$BIN" "$FIX" --no-cache >"$MAP_OUT" 2>"$TMP/map.err"
MAP_EXIT=$?
[ "$MAP_EXIT" -eq 0 ] && ok "default map: exits 0 on the Elixir fixture" || no "default map: exited $MAP_EXIT: $( cat "$TMP/map.err" )"
command -v xmllint >/dev/null 2>&1 && { xmllint --noout "$MAP_OUT" && ok "default map: passes xmllint --noout" || no "default map: xmllint failed"; }
[ -s "$TMP/map.err" ] && no "default map: unexpected stderr (ABI/degrade?): $( cat "$TMP/map.err" )" || ok "default map: clean stderr (no ABI mismatch / degrade)"

parse(){   # $1 = map xml → a JSON {basename: [{t,n,calls:[…]}]}
python3 - "$1" <<'PYEOF'
import sys, re, json
xml = open(sys.argv[1], encoding='utf-8').read()
out = {}
for path, body in re.findall(r'<f p="([^"]+)"[^>]*>(.*?)</f>', xml, re.S):
    name = path.split('/')[-1]
    syms = []
    for sm in re.finditer(r'<s t="(\w+)" n="([^"]*)"[^>]*>(.*?)</s>|<s t="(\w+)" n="([^"]*)"[^>]*/>', body, re.S):
        if sm.group(1) is not None:
            t, n, inner = sm.group(1), sm.group(2), sm.group(3)
        else:
            t, n, inner = sm.group(4), sm.group(5), ""
        syms.append({"t": t, "n": n, "calls": re.findall(r'<c n="([^"]*)"', inner)})
    out[name] = syms
print(json.dumps(out))
PYEOF
}
parse "$MAP_OUT" >"$TMP/parsed.json"

ask(){   # $1 = parsed.json, $2 = python expression over `d` → prints True/False
python3 - "$1" "$2" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
def has(f, n, t):     return any(s["n"] == n and s["t"] == t for s in d.get(f, []))
def name(n):          return any(s["n"] == n for syms in d.values() for s in syms)
def kind(n):          return sorted({s["t"] for syms in d.values() for s in syms if s["n"] == n})
def edge(frm, to):    return any(s["n"] == frm and to in s["calls"] for syms in d.values() for s in syms)
def calls(frm):       return sorted({c for syms in d.values() for s in syms if s["n"] == frm for c in s["calls"]})
def nsyms():          return sum(len(v) for v in d.values())
print(eval(sys.argv[2]))
PYEOF
}
assert_true(){ [ "$( ask "$TMP/parsed.json" "$1" )" = "True" ] && ok "$2" || no "$2"; }

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 1. STRUCTURE: 5 files (.ex AND .exs), 17 symbols, 9 edges ==="
# ═══════════════════════════════════════════════════════════════════════════
grep -q 'files=5 symbols=17' "$MAP_OUT" && ok "header: files=5 symbols=17" || no "header: expected files=5 symbols=17: $( grep -o 'files=[0-9]* symbols=[0-9]*' "$MAP_OUT" )"
grep -q 'edges=9' "$MAP_OUT"            && ok "header: edges=9"            || no "header: expected edges=9: $( grep -o 'edges=[0-9]*' "$MAP_OUT" )"
grep -q 'ambiguous=0' "$MAP_OUT"        && ok "header: ambiguous=0"        || no "header: expected ambiguous=0: $( grep -o 'ambiguous=[0-9]*' "$MAP_OUT" )"
grep -q 'unresolved=0' "$MAP_OUT"       && ok "header: unresolved=0"       || no "header: expected unresolved=0: $( grep -o 'unresolved=[0-9]*' "$MAP_OUT" )"
# .exs is NOT a second-class tier: an ExUnit file is indexed under the same grammar and the same query.
assert_true 'len(d.get("greeter_test.exs", [])) == 2' '.exs is indexed: greeter_test.exs contributes 2 symbols'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 2. KIND MAPPING: each def keyword lands in its OWN kind ==="
# ═══════════════════════════════════════════════════════════════════════════
# A collapsed gate (or a ported #any-of? query) makes these all the same kind — that is the failure mode.
assert_true 'has("greeter.ex", "Greeter", "cls")'    'defmodule Repo.Greeter    -> t="cls"'
assert_true 'has("render.ex", "Render", "iface")'    'defprotocol Repo.Render   -> t="iface"'
assert_true 'has("greeter.ex", "greet", "fn")'       'def greet                 -> t="fn"'
assert_true 'has("greeter.ex", "emit", "fn")'        'defp emit                 -> t="fn"'
assert_true 'has("greeter.ex", "default", "fn")'     'def default (bare head)   -> t="fn"'
assert_true 'has("greeter.ex", "trace", "macro")'    'defmacro trace            -> t="macro"'
assert_true 'has("greeter.ex", "is_name", "macro")'  'defguard is_name          -> t="macro"'
assert_true 'has("util.ex", "trim", "fn")'           'def trim (keyword body)   -> t="fn"'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 3. DISCLOSED FLOORS: defimpl mints no container, ExUnit test/2 mints no def ==="
# ═══════════════════════════════════════════════════════════════════════════
# `defimpl Repo.Render, for: Repo.Greeter` defines the module `Repo.Render.Repo.Greeter` — a name that
# appears nowhere in the source. Naming that container "Render" would put a WRONG name in the map, so it
# mints nothing; its `def render` IS captured, which is why `render` carries overloads="2".
assert_true 'len([s for syms in d.values() for s in syms if s["n"] == "Render"]) == 1' \
            'defimpl mints NO second Render container (only the protocol'"'"'s own iface symbol)'
assert_true 'name("render")' 'defimpl'"'"'s `def render` IS captured (the functions survive, the shell does not)'
grep -q 'n="render" overloads="2"' "$MAP_OUT" && ok 'render carries overloads="2" (protocol callback + impl clause)' \
                                              || no 'expected n="render" overloads="2"'
# `test "it greets" do` is a macro CALL. ripwire reads source text, so a def only a macro expansion would
# create is invisible — Elixir's largest extraction floor, stated in queries/elixir/tags.scm.
assert_true 'not name("it greets")' 'ExUnit `test "…" do` mints NO def (the metaprogramming floor)'
# defstruct fields and @module attributes are a keyword list and a unary_operator, not declarations.
assert_true 'not name("salutation")' 'defstruct fields mint no symbols'
assert_true 'not name("default_greeting")' '@module attributes mint no symbols'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 4. KEYWORD SKIP: def / defmodule / control forms are neither symbols nor call targets ==="
# ═══════════════════════════════════════════════════════════════════════════
# In this grammar `def greet(n) do` IS a call to `def`. Without elixirNonCallKeyword every Elixir file
# mints a reference to `def`/`defmodule`/`if`, and `--callers=def` becomes the busiest node in the map.
for kw in def defp defmodule defprotocol defimpl defmacro defguard defstruct alias import require use case cond if with quote; do
    assert_true "not name(\"$kw\")"                                "\`$kw\` is not a symbol"
    assert_true "not any(\"$kw\" in s['calls'] for syms in d.values() for s in syms)" "\`$kw\` is not a call target"
done

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 5. EDGES: local, remote, and pipe-into-name calls all resolve ==="
# ═══════════════════════════════════════════════════════════════════════════
assert_true 'edge("shout", "title")'   'same-file local call    shout -> title'
assert_true 'edge("emit", "shout")'    'REMOTE call             emit  -> Formatter.shout'
assert_true 'edge("greet", "trim")'    'PIPE into a call        greet -> Util.trim'
assert_true 'edge("greet", "title")'   'PIPE into a remote call greet -> Formatter.title'
assert_true 'edge("greet", "is_name")' 'a `when` guard IS a real call to the guard macro'
assert_true 'edge("greet", "emit")'    'pipe chain tail         greet -> emit'
assert_true 'edge("helper", "default")' '.exs file calls into a .ex module'
# The ExUnit body's call is attributed to the enclosing MODULE, since `test "…" do` is not a def.
assert_true 'edge("GreeterTest", "greet")' 'a call inside `test "…" do` attributes to the module symbol'
# Logger.debug / String.upcase resolve to nothing in-corpus and drop — which is why unresolved=0.
assert_true 'not name("debug")'  'an out-of-corpus remote callee (Logger.debug) mints no symbol'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 6. THE DEF HEAD IS NOT A CALL (the measured phantom edge) ==="
# ═══════════════════════════════════════════════════════════════════════════
# `def render(term)` parses as (call target: def (arguments (call target: render …))) — that inner call is
# the thing being DEFINED. Self-edges are dropped downstream, which hid this everywhere EXCEPT where two
# defs share a name: the protocol callback and the defimpl clause resolved each other's HEADS and produced
# a phantom `render -> render` edge, taking edges from 9 to 11. Both halves are asserted.
assert_true 'not edge("render", "render")' 'no phantom self-edge from a def head (render -> render)'
assert_true 'not edge("greet", "greet")'   'no phantom self-edge across greet'"'"'s two clauses'
# ...and the guard's RIGHT-hand side must survive, which is what makes the anchor test in
# elixirIsDefinitionHead load-bearing rather than a blanket skip:
assert_true 'edge("greet", "is_name")' 'the `when` RHS survives the head skip (not a blanket drop)'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 7. IMPORT DIRECTIVES: alias/import/require/use are role=import use-sites, defmodule is not ==="
# ═══════════════════════════════════════════════════════════════════════════
# Both are the SAME query pattern — `(call target: (identifier) (arguments . (alias) @name))` — separated
# only by elixirImportDirectiveKept. These arms pin both directions of that gate.
"$BIN" "$FIX" --uses=Formatter --no-cache >"$TMP/uses_fmt.xml" 2>/dev/null
grep -q 'role="import"' "$TMP/uses_fmt.xml" && ok 'alias Repo.Formatter -> a role="import" use-site' \
                                            || no 'expected a role="import" use-site for Formatter'
grep -q 'p="lib/repo/greeter.ex:4"' "$TMP/uses_fmt.xml" && ok 'the import use-site points at the alias LINE' \
                                            || no "expected the use-site at greeter.ex:4: $( grep -o 'p="[^"]*"' "$TMP/uses_fmt.xml" | head -3 )"
# An import is NOT a call edge (graph.h admits Call+Macro only) — the module must not gain a caller.
assert_true 'not edge("Greeter", "Formatter")' 'an alias is a NAME edge, never a call edge'
# ...and Elixir is deliberately absent from dependencyCapable: a module is not a file, so an Elixir file
# is never a node in the --deps graph. A zero there reads "not measured", never "none exists".
"$BIN" "$FIX" --deps --no-cache >"$TMP/deps.xml" 2>/dev/null
grep -q '\.ex"' "$TMP/deps.xml" && no 'an .ex file appeared as a --deps node (Elixir is not dependencyCapable)' \
                                || ok 'no .ex file is a --deps node (the disclosed module-vs-file floor)'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 8. METRICS: params are the head's REAL formals; cx is the disclosed floor of 1 ==="
# ═══════════════════════════════════════════════════════════════════════════
"$BIN" "$FIX" --metrics --no-cache >"$TMP/metrics.xml" 2>/dev/null
pcount(){ grep -o "n=\"$1\"[^>]* params=\"[0-9]*\"" "$TMP/metrics.xml" | grep -o 'params="[0-9]*"' | head -1; }
# Elixir has no parameter-list node type, so the generic search returns 0 for EVERY def. params="0" on
# `def greet(name)` is not a floor, it is a wrong number — elixirParamCount exists to prevent exactly that.
[ "$( pcount greet )" = 'params="1"' ]   && ok 'def greet(name)      -> params="1" (not the generic search'"'"'s 0)' || no "greet params: $( pcount greet )"
[ "$( pcount title )" = 'params="1"' ]   && ok 'def title(text)      -> params="1"'                                 || no "title params: $( pcount title )"
[ "$( pcount default )" = 'params="0"' ] && ok 'def default (bare)   -> params="0" (a TRUE zero-arity)'              || no "default params: $( pcount default )"
[ "$( pcount trim )" = 'params="1"' ]    && ok 'def trim(text), do:  -> params="1" (keyword-body clause)'            || no "trim params: $( pcount trim )"
# cx: `if`/`case`/`cond`/`with` are macro CALLS here, not statement node types, so isDecisionType matches
# nothing and cx is 1 for every Elixir function. "No decision points FOUND" — the safe direction, and the
# reason Elixir is absent from model.h's evCountedLang. Asserted so the floor stays a decision, not drift.
grep -q 'cx="[2-9]"' "$TMP/metrics.xml" && no 'a cx above 1 appeared — the disclosed Elixir floor moved, update the docs' \
                                        || ok 'cx is the disclosed floor of 1 for every Elixir function'
grep -q ' ev="' "$TMP/metrics.xml" && no 'ev= emitted for Elixir (it is NOT in evCountedLang)' \
                                   || ok 'no ev= for Elixir (absent from evCountedLang, so "not measured")'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 9. MUTATION: the assertions above move when the source does (non-tautology) ==="
# ═══════════════════════════════════════════════════════════════════════════
MUT="$TMP/mut"
cp -R "$FIX" "$MUT"
# 9a. delete the alias -> the role="import" use-site must disappear.
grep -v 'alias Repo.Formatter' "$MUT/lib/repo/greeter.ex" >"$MUT/g.tmp" && mv "$MUT/g.tmp" "$MUT/lib/repo/greeter.ex"
"$BIN" "$MUT" --uses=Formatter --no-cache 2>/dev/null | grep -q 'role="import"' \
    && no '9a: removing `alias Repo.Formatter` left the import use-site behind (arm 7 is tautological)' \
    || ok '9a: removing the alias removes the role="import" use-site'
# 9b. rename a remote callee -> the cross-module edge must disappear.
sed -i.bak 's/def shout(text)/def bellow(text)/' "$MUT/lib/repo/formatter.ex" && rm -f "$MUT/lib/repo/formatter.ex.bak"
"$BIN" "$MUT" --no-cache 2>/dev/null >"$TMP/mut_map.xml"
parse "$TMP/mut_map.xml" >"$TMP/mut.json"
[ "$( ask "$TMP/mut.json" 'edge("emit", "shout")' )" = "False" ] \
    && ok '9b: renaming Formatter.shout drops the emit -> shout edge' \
    || no '9b: emit -> shout survived a rename of its callee (arm 5 is tautological)'
# 9c. turn a `defp` into a plain call -> the symbol must stop existing.
sed -i.bak 's/  defp emit(text) do/  emit(text) = fn -> nil end/' "$MUT/lib/repo/greeter.ex" && rm -f "$MUT/lib/repo/greeter.ex.bak"
"$BIN" "$MUT" --no-cache 2>/dev/null >"$TMP/mut2_map.xml"
parse "$TMP/mut2_map.xml" >"$TMP/mut2.json"
[ "$( ask "$TMP/mut2.json" 'has("greeter.ex", "emit", "fn")' )" = "False" ] \
    && ok '9c: dropping the `defp` keyword drops the symbol (the keyword gate is real)' \
    || no '9c: `emit` was still a t="fn" symbol without its `defp` keyword — the capture gate is not firing'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 10. DETERMINISM: byte-identical output across runs ==="
# ═══════════════════════════════════════════════════════════════════════════
"$BIN" "$FIX" --no-cache >"$TMP/det_a" 2>/dev/null
"$BIN" "$FIX" --no-cache >"$TMP/det_b" 2>/dev/null
[ -s "$TMP/det_a" ] || no "determinism: EMPTY baseline (0 B is vacuously identical, not deterministic)"
[ -s "$TMP/det_a" ] && { diff -q "$TMP/det_a" "$TMP/det_b" >/dev/null && ok "determinism: two runs byte-identical" || no "determinism: output differs between runs"; }

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILURES"; exit 1; }
