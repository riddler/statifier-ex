# SCION scxml-test-framework cases with no predicator equivalent, or that
# duplicate the separately-generated W3C corpus. A key is either a bare spec
# directory ("script") to exclude every case under it, or "spec/name"
# ("assign-current-small-step/test0") to exclude one case within an
# otherwise-included spec.
#
# Reasons:
#   :needs_external_fetch  - <script src>; rejected at load, external fetch
#                            never happens (ADR-0026 decision 2; st-322 owns
#                            the external-fetch question)
#   :needs_ecmascript      - the body uses a construct predicator's statement
#                            grammar does not have, named per entry
#                            (ADR-0004's ECMAScript-dependence clause)
#   :duplicates_w3c_corpus - SCION's own untransformed mirror of the W3C IRP
#                            suite (datamodel="ecmascript", no predicator XSL
#                            applied); tools/corpus/scxml_w3 generates the
#                            real W3C corpus from the primary IRP source
#   :contradicts_w3c_semantics - asserts behavior the REC normatively
#                            forbids, rather than a gap in predicator support;
#                            permanently out (ADR-0022)

%{
  "w3c-ecma" =>
    {:duplicates_w3c_corpus,
     "SCION framework's embedded copy of the W3C IRP suite; duplicates tools/corpus/scxml_w3's output with no predicator transform applied"},
  "script-src" =>
    {:needs_external_fetch,
     "<script src=\"*.js\"/> - external fetch never happens (ADR-0026 decision 2)"},
  "error" =>
    {:needs_ecmascript, "function definition and var (function doError() { var x = y; })"},
  "assign-current-small-step/test0" =>
    {:needs_ecmascript,
     "compound assignment (*=) - predicator's statement grammar is `location \"=\" expression` only"},
  "more-parallel/test10" =>
    {:contradicts_w3c_semantics,
     "assumes a <parallel> can be the LCCA; the REC's compound-state definition, 3.1.5, and Appendix D's findLCCA prose all exclude <parallel> from LCCA candidacy (ADR-0022)"},
  "more-parallel/test10b" =>
    {:contradicts_w3c_semantics,
     "assumes a <parallel> can be the LCCA; the REC's compound-state definition, 3.1.5, and Appendix D's findLCCA prose all exclude <parallel> from LCCA candidacy (ADR-0022)"}
}
