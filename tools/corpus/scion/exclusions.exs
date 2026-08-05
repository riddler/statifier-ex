# SCION scxml-test-framework cases with no predicator equivalent, or that
# duplicate the separately-generated W3C corpus. A key is either a bare spec
# directory ("script") to exclude every case under it, or "spec/name"
# ("assign-current-small-step/test0") to exclude one case within an
# otherwise-included spec.
#
# Reasons:
#   :needs_script          - <script>/statements; permanently out (ADR-0004)
#   :duplicates_w3c_corpus - SCION's own untransformed mirror of the W3C IRP
#                            suite (datamodel="ecmascript", no predicator XSL
#                            applied); tools/corpus/scxml_w3 generates the
#                            real W3C corpus from the primary IRP source

%{
  "w3c-ecma" =>
    {:duplicates_w3c_corpus,
     "SCION framework's embedded copy of the W3C IRP suite; duplicates tools/corpus/scxml_w3's output with no predicator transform applied"},
  "script" => {:needs_script, "conf:script - predicator has no statement layer"},
  "script-src" =>
    {:needs_script, "external <script src> - same statement-layer gap as inline <script>"},
  "error" => {:needs_script, "conf:script - predicator has no statement layer"},
  "assign-current-small-step/test0" =>
    {:needs_script, "onentry <script> assignment - predicator has no statement layer"}
}
