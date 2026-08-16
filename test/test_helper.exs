# The test suite is the ADR-0027 embedder: `Statifier.Supervisor`'s children
# are fixed, module-qualified names, so exactly one runtime can exist per node
# and it cannot be owned by a test process (a `Supervisor` started from a test
# dies with it). Placing it here lets `async: true` corpus tests share one
# registry and one DynamicSupervisor; sessions are `restart: :temporary` and
# registered under unique UXID session ids, so they cannot collide.
{:ok, _runtime} = Statifier.Supervisor.start_link([])

ExUnit.start(exclude: [:scion, :scxml_w3, :adr_judge_corpus])
