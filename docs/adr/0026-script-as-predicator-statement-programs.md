# ADR-0026: `<script>` bodies are predicator statement programs

Status: accepted (2026-08-14) - amends ADR-0004 in part

## Context

ADR-0004 made predicator the datamodel, permanently, and closed with one
deliberately conditional consequence: "`<script>` remains unsupported
unless/until predicator grows a safe statement layer." That clause froze
`<script>` without deciding it - the record's own wording anticipates the
condition being met, and `docs/datamodel.md` carried the same posture
("stays unsupported. The direction we want instead: a small, safe
statement layer in predicator itself").

Predicator 5.0.0 grew exactly that layer, and the pin has since moved to
`~> 7.0` (mix.exs:41, st-5ma): `parse_program/2` parses a statement
grammar (sequences of assignments and expression statements over the
existing expression language), the ISA gained `store`/`pop`, and
`Predicator.execute/1,2,3` runs a program and returns the resulting
context - `{:ok, %Context{}}`, or
`{:error, error, %Context{}}` where the third element is the context "as
of the last successfully completed statement" (its documented contract:
every earlier write survives, the failing statement's write does not
happen, and no later statement runs). Nothing in the layer is `eval`;
it is the same non-evaluative instruction set the expression language
compiles to, extended with writes. ADR-0004's stated condition is
therefore met, and keeping `<script>` excluded would be a new decision on
new grounds, not the standing constraint. Four `:needs_script` entries in
`tools/corpus/scion/exclusions.exs` (the `script`, `script-src`, and
`error` directories, plus `assign-current-small-step/test0`) rest on that
constraint alone: "predicator has no statement layer" is now false.

Three spec clauses shape what supporting `<script>` must mean. 5.8
(normative) on evaluation timing:

> The SCXML Processor MUST evaluate any `<script>` element that is a
> child of `<scxml>` at document load time. It MUST evaluate all other
> `<script>` elements as part of normal executable content evaluation.

5.8.2 on the `src` attribute:

> A conformant SCXML document MUST specify either the 'src' attribute or
> child content, but not both. If 'src' is specified, the SCXML Processor
> MUST download the script from the specified location at load time. If
> the script can not be downloaded within a platform-specific timeout
> interval, the document is considered non-conformant, and the platform
> MUST reject it.

And 4.9 (normative) on errors in executable content:

> The SCXML processor MUST execute the elements of a block in document
> order. If the processing of an element causes an error to be raised,
> the processor MUST NOT process the remaining elements of the block.
> (The execution of other blocks of executable content is not affected.)

4.9's model is stop-at-the-error, keep-what-ran: it halts the *rest* of
the block but says nothing about undoing what already executed, and the
mandatory IRP test156
(`test/scxml_tests/mandatory/foreach/test156_test.exs`) observes exactly
that - `Var1` is incremented by the element *before* the erroring one,
and the pass path requires `Var1==1`, so the prior write must have stuck.
An all-or-nothing rollback is not a conforming shape at any granularity
this suite can see.

## Decision

**`<script>` is supported. Its body compiles with predicator's
`parse_program/2` and executes with `Predicator.execute/3` against the
session datamodel. This amends ADR-0004 in part: the "`<script>` remains
unsupported" consequence is discharged on the record's own condition,
and everything else in ADR-0004 - predicator as the sole datamodel, no
ECMAScript engine, no Elixir eval - stands unchanged.** The body is a
predicator statement program, not a script in a general-purpose
language; the security posture ADR-0004 stakes out is not spent here,
because the statement layer is the same non-evaluative instruction set
expressions already run on, with writes.

Four subsidiary decisions:

1. **Errors keep the partial context, then raise `error.execution`.**
   When `Predicator.execute/3` returns `{:error, error, %Context{}}`,
   the third element is kept: the partial context - every write up to
   but not including the failing statement - is written back to the
   datamodel, and the error maps to `error.execution` exactly as every
   other evaluation error does. Discarding the partial context (the
   all-or-nothing option predicator's docs leave to the caller) is
   rejected: 4.9's error model is stop-and-keep, test156 observes prior
   writes surviving an error in a sequenced construct, and rollback
   would make `<script>` the one place in the engine where an error
   silently unwrites data. Statement granularity inside one `<script>`
   mirrors element granularity inside one block: the failing statement's
   write does not happen, no later statement runs, everything earlier
   stands.

2. **`<script src>` is rejected as unsupported, with a named error.**
   5.8.2's download MUST is a load-time fetch of a document-named URI -
   the same I/O-in-the-core and security objections ADR-0024 records
   for `<data src>`, at document-load time instead of binding time. The
   unresolved question of external fetch belongs to st-322, and this
   record defers to it exactly as ADR-0024 did; `<script src>` does not
   settle it. Until then a document using `src` is rejected at load with
   a named unsupported error - not silently ignored, and not an empty
   no-op script. This lands on the conforming side of 5.8.2's own
   fallback: a script that "can not be downloaded" obliges the platform
   to *reject* the document, and a platform that never fetches cannot
   download anything.

3. **Top-level `<script>` is a load-time path, not executable content.**
   Per 5.8, a `<script>` child of `<scxml>` is evaluated at document
   load time, before the initial state is entered - the
   `executeGlobalScriptElement(doc)` seam already commented at
   `lib/statifier/interpreter.ex:129` (initialize/2's skipped preamble).
   It shares the compile path and the execution semantics of decision 1
   (partial context stands, `error.execution` queued as an internal
   event for the first macrostep), but it is a distinct interpreter
   path: no block runner, no `<onentry>` context. All other `<script>`
   occurrences are ordinary executable content under the st-wju.5
   contract - a `Statifier.Machine.Content.Script` struct with a
   `defimpl Statifier.ExecutableContent` in the same file, nothing added
   to the interpreter or the block runner.

4. **The ceiling is stated up front: corpus script bodies are
   ECMAScript, and predicator's statement grammar is not.** Object
   literals, `typeof`, and function definitions still will not parse.
   Predicator additionally reserves `if`, `else`, `while`, `undefined`,
   and (since 6.0) `null`, so a body using one as an identifier is a
   parse error (the st-p3t and st-5ma sweeps). Only the subset of the
   four excluded `:needs_script` corpus entries whose bodies fall inside
   the statement grammar joins the ratchet; the rest stay out, excluded
   now for the ECMAScript-dependence reason ADR-0004 already accepts
   ("W3C tests that irreducibly require ECMAScript are excluded"), not
   the no-statement-layer reason. **The corpus flip must not read as a
   regression**: removing `:needs_script` exclusions and gaining fewer
   passing files than the directories once held is the expected outcome,
   because the exclusion reason changes per file rather than vanishing
   wholesale. Which exact files clear the grammar is determined at
   implementation time, file by file, not promised here.

Amendment, not supersession: ADR-0004's Decision section is untouched -
this record changes no sentence of it, and every consequence except the
`<script>` bullet still holds. Superseding a record whose own text
scheduled this outcome would misstate the history; the amendment
convention (ADR-0002, ADR-0019/0020, tracked in the README status
column) is the recorded shape for exactly this.

## Consequences

- ADR-0004 carries an amendment note and the README table marks it
  "amended in part by 0026"; `docs/datamodel.md`'s "Statement sequences
  and `<script>`" section is rewritten to state support and cite this
  record, and upstreaming seam 4 is marked landed.
- The `:needs_script` reason string in
  `tools/corpus/scion/exclusions.exs` ("predicator has no statement
  layer") becomes false and must not survive the implementation: each of
  the four entries is either removed (body parses; file joins the
  corpus and, if passing, the ratchet) or re-recorded under the
  ECMAScript-dependence reason with the specific construct named.
- A `<script>` body failing mid-program retains prior writes and raises
  `error.execution` - test156's semantics applied at statement
  granularity. Any future all-or-nothing request is a change to this
  record, not a flag.
- `<script src>` documents are rejected at load with a named error. If
  st-322 ever settles external fetch in favor of fetching, `<script
  src>` re-argues its case there; ADR-0024's `<data src>` never-fetch
  decision is not silently extended to cover it, and this record's
  rejection is not silently relaxed.
- The feature detector's `script_elements :unsupported` entry
  (test/support/feature_detector.ex) flips to whatever partial-support
  notation the registry uses, per the ceiling in decision 4.
- st-t3f (rewriting basic script bodies at corpus-generation time) is
  rescoped to bodies the statement grammar cannot execute, or closed as
  superseded - its blanket premise is gone.
- Open question, deliberately not settled here: whether a *top-level*
  `<script>` evaluation error should ever be escalated to a document
  rejection rather than a queued `error.execution`. 5.8 mandates
  rejection only for an undownloadable `src`; this record queues
  `error.execution` for inline-body failures at load time (decision 3)
  because that is the executable-content error model and no corpus file
  demands otherwise. If a mandatory test surfaces that observes
  rejection, that is an amendment here.
