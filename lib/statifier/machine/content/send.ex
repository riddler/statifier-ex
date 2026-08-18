defmodule Statifier.Machine.Content.Send do
  @moduledoc """
  A compiled `<send>` executable-content node (spec 6.2) - the interned
  counterpart to `Statifier.Document.Send`.

  `event`, `target`, `type`, and `delay` each fold their own static/expr
  attribute pair into a single `Machine.expr() | nil`, mirroring
  `Statifier.Machine.Invoke.type`/`.src`: `{:static, v}` from
  `event`/`target`/`type`/`delay`, `{:compiled, ...}` from
  `eventexpr`/`targetexpr`/`typeexpr`/`delayexpr`, `nil` when neither
  sibling was written (an already-validated document never writes both -
  6.2.1's "Must not occur with" pairs).

  `id` is the author's literal `id` attribute, used verbatim
  (ADR-0008 as amended). `idlocation` stays a **raw, uncompiled location
  path string**, never a compiled expression - `Statifier.Machine.Invoke.idlocation`'s
  own moduledoc gives the reason: a location path cannot be resolved any
  earlier than execute time, even in principle.

  `namelist` and `params` are kept as two separate lists of
  `Statifier.Machine.Param.t()`, every `namelist` entry compiled with
  `kind: :location` - the same split `Statifier.Machine.Invoke` keeps for
  its own `namelist`/`params`, so the validator can enforce 6.2.1's
  "namelist Must not occur with the `<param>` element".

  `content` folds `<content>`'s markup into a single `Machine.expr()`,
  exactly as `Machine.Invoke.content` and `Machine.Donedata.expr` do - `nil`
  when `<send>` has no `<content>` child.

  `attribute_locations` is `Statifier.Document.Send`'s own map, carried
  through unchanged rather than distilled into individual `*_location`
  fields - the same call `Statifier.Machine.Invoke`'s moduledoc makes for
  its own eight source attributes.

  Its `Statifier.ExecutableContent` implementation lives right below the
  struct: this file is the whole node, top to bottom, with no dispatcher
  anywhere else in the tree.
  """

  alias Statifier.{Document, Duration, Effect, Evaluator, EventData, Machine, MachineState}
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter.Datamodel
  alias Statifier.Machine.Content.Send
  alias Statifier.Machine.Param
  alias Statifier.Parser.Location
  alias Statifier.Send.Routes
  alias Statifier.Send.Target

  @enforce_keys [:c_index, :location]
  defstruct [
    :c_index,
    :location,
    event: nil,
    target: nil,
    type: nil,
    id: nil,
    idlocation: nil,
    delay: nil,
    namelist: [],
    params: [],
    content: nil,
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          location: Location.t(),
          event: Machine.expr() | nil,
          target: Machine.expr() | nil,
          type: Machine.expr() | nil,
          id: String.t() | nil,
          idlocation: String.t() | nil,
          delay: Machine.expr() | nil,
          namelist: [Param.t()],
          params: [Param.t()],
          content: Machine.expr() | nil,
          attribute_locations: Document.attribute_locations()
        }

  defimpl Statifier.ExecutableContent do
    @moduledoc false

    # spec 6.2's <send>: resolve every argument (event, target, type, delay,
    # namelist/<param>, <content>), mint or read the send id, write
    # idlocation, then emit `{:send, %Effect.Send{}}` with no delay or
    # `{:send_delayed, %Effect.SendDelayed{}}` with one - preceded by
    # `{:datamodel_change, _}` when `idlocation` was written: the datamodel
    # write happens before the send is dispatched, and effects are performed
    # in the core's own order. This
    # `with` is deliberately shaped like `invoke_one/6`
    # (`lib/statifier/interpreter.ex:1278-1313`) - same order, same
    # delegation to `resolve_expr/2`/`resolve_params/2`/`resolve_content/2`
    # and `Interpreter.Datamodel.write_location/4` - so a reader who knows
    # one recognizes the other. An argument failure - `<content expr>`
    # included - still returns the two-element `{:error, reason}` form and
    # discards the message per ADR-0036; the block runner is the sole
    # execution-failure conversion site (ADR-0003). A resolved `target`/
    # `type` that classifies as invalid or unsupported (ADR-0047) is a
    # different case: the send id has already been minted and `idlocation`
    # already written by then, so that rejection returns the three-element
    # `{:error, context, reason}` form instead, carrying the context that
    # work landed in.
    @spec execute(node :: Send.t(), context :: Context.t()) ::
            {:ok, Context.t(),
             [
               {:datamodel_change, Effect.DatamodelChange.t()}
               | {:send, Effect.Send.t()}
               | {:send_delayed, Effect.SendDelayed.t()}
             ]}
            | {:error, term()}
            | {:error, Context.t(), term()}
    def execute(%Send{} = node, %Context{} = context) do
      %{datamodel_context: datamodel_context} = context

      with {:ok, event} <- resolve_expr(datamodel_context, node.event),
           {:ok, target} <- resolve_expr(datamodel_context, node.target),
           {:ok, type} <- resolve_expr(datamodel_context, node.type),
           {:ok, delay_ms} <- resolve_delay(datamodel_context, node.delay),
           {:ok, raw_params} <- resolve_params(datamodel_context, node.namelist ++ node.params),
           {:ok, content} <- resolve_content(datamodel_context, node.content) do
        {send_id, machine_state} = generate_send_id(context.machine_state, node)

        case maybe_write_idlocation(machine_state, datamodel_context, node.idlocation, send_id) do
          {:ok, machine_state, datamodel_context, write} ->
            new_context = %{
              context
              | machine_state: machine_state,
                datamodel_context: datamodel_context
            }

            fields = %{event: event, target: target, type: type}

            dispatch_or_reject(
              node,
              new_context,
              fields,
              raw_params,
              content,
              send_id,
              delay_ms,
              write
            )

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    # `reject_reason/4` decides between the two outcomes `execute/2` may
    # return once the send id is minted and `idlocation` is written: build
    # and return the effect, or reject with the composite error form.
    # Pulled out of `execute/2` itself to keep that function's own nesting
    # shallow.
    @spec dispatch_or_reject(
            node :: Send.t(),
            new_context :: Context.t(),
            fields :: %{event: term(), target: term(), type: term()},
            raw_params :: [{String.t(), term()}],
            content :: term(),
            send_id :: String.t(),
            delay_ms :: non_neg_integer() | nil,
            write :: Datamodel.Write.t() | nil
          ) ::
            {:ok, Context.t(), [tuple()]} | {:error, Context.t(), term()}
    defp dispatch_or_reject(
           node,
           new_context,
           fields,
           raw_params,
           content,
           send_id,
           delay_ms,
           write
         ) do
      %{owner: owner, machine_state: machine_state} = new_context

      case reject_reason(fields.target, fields.type, delay_ms, machine_state.routes) do
        nil ->
          fields = Map.put(fields, :data, data(node, raw_params, content))
          effect = build_effect(node, fields, send_id, delay_ms, owner, machine_state)

          # The datamodel write, when there is one, precedes the
          # :send/:send_delayed effect it accompanies - the write happens
          # before the send is dispatched, and Session performs
          # instructions in the core's effect order.
          {:ok, new_context,
           datamodel_change_effects(write, node, owner, machine_state) ++ [effect]}

        {kind, reason} ->
          # ADR-0047/ADR-0048: 6.2.4's invalid target, 6.2.5's unsupported
          # type, and ADR-0048's unreachable route are all rejected here,
          # in the core, so 4.9's block abort is honored. The id was
          # minted and idlocation written first (5.10.1's unconditional
          # MUST), and the composite error form is what keeps both: the
          # advanced send_counter and the datamodel write are in
          # new_context's machine_state, which the block runner keeps on
          # its fatal arm. `kind` (`:execution | :communication`) is an
          # atom, not an event-name string - `Statifier.Interpreter.Content`
          # is still the only site that names an `error.*` event.
          {:error, new_context, {:send_rejected, send_id, kind, reason}}
      end
    end

    # `event`/`target`/`type` - `nil` when the author wrote neither sibling
    # attribute, `Evaluator.evaluate/2` (which already handles both
    # `{:static, _}` and `{:compiled, _, _}`) otherwise. Mirrors
    # `invoke_one/6`'s own `resolve_expr/2`.
    @spec resolve_expr(datamodel_context :: Predicator.Context.t(), expr :: Machine.expr() | nil) ::
            {:ok, term()} | {:error, term()}
    defp resolve_expr(_datamodel_context, nil), do: {:ok, nil}
    defp resolve_expr(datamodel_context, expr), do: Evaluator.evaluate(datamodel_context, expr)

    # ADR-0047: 6.2.5's type check runs ahead of 6.2.4's target check,
    # matching the order `Statifier.Session.Effects` applies at its own
    # boundary. `nil` means the send is well-formed and dispatches. Both
    # `target` and `type` here are already-resolved values (the `with`
    # above ran `resolve_expr/2` on each), so a `targetexpr` that fails to
    # evaluate never reaches this function - that is still ADR-0036's
    # argument-failure path.
    #
    # ADR-0048: reachability, judged against the caller-declared snapshot on
    # `%MachineState{}` - a value, never a lookup (ADR-0003/ADR-0027 stay
    # structural). `nil` routes means the driver declared nothing, so the core
    # makes no determination and the effect is emitted exactly as before; the
    # session's `deliver/5` boundary is still the detector on that path
    # (ADR-0048 decision 5). A delayed send is exempt: 6.2.3 governs *argument*
    # evaluation at element-evaluation time and reachability is not an argument,
    # so the route is resolved when the timer fires (ADR-0048 decision 6).
    @spec reject_reason(
            target :: term(),
            type :: term(),
            delay_ms :: non_neg_integer() | nil,
            routes :: Routes.t() | nil
          ) ::
            {:execution, {:unsupported_type, term()} | {:invalid_target, term()}}
            | {:communication, {:unreachable_target, term()}}
            | nil
    defp reject_reason(target, type, delay_ms, routes) do
      cond do
        not Target.supported_type?(type) ->
          {:execution, {:unsupported_type, type}}

        match?({:invalid, _reason}, Target.parse(target)) ->
          {:execution, {:invalid_target, target}}

        unreachable?(target, delay_ms, routes) ->
          {:communication, {:unreachable_target, target}}

        true ->
          nil
      end
    end

    @spec unreachable?(
            target :: term(),
            delay_ms :: non_neg_integer() | nil,
            routes :: Routes.t() | nil
          ) :: boolean()
    defp unreachable?(_target, _delay_ms, nil), do: false
    defp unreachable?(_target, delay_ms, _routes) when is_integer(delay_ms), do: false

    defp unreachable?(target, nil, routes),
      do: not Routes.reachable?(routes, Target.parse(target))

    # `delay`/`delayexpr` (6.2.2), resolved to whole milliseconds via
    # `Statifier.Duration.to_ms/1`. `nil` (neither attribute) -> `{:ok, nil}`
    # (an immediate send). A static `delay` evaluates to its own literal
    # string; `delayexpr` may evaluate to a string or a native predicator
    # duration value (`Statifier.Duration.value/0`), so both are accepted
    # before `to_ms/1` is called. Anything else `delayexpr` might evaluate to
    # - `Statifier.Duration.to_ms/1` has no clause for it - is treated as an
    # argument failure here rather than let through to a `FunctionClauseError`:
    # a leaf never raises (ADR-0003), so an author-written `delayexpr` of the
    # wrong shape is reported the same way a parse failure is, both handled
    # by ADR-0036's discard.
    @spec resolve_delay(
            datamodel_context :: Predicator.Context.t(),
            delay :: Machine.expr() | nil
          ) ::
            {:ok, non_neg_integer() | nil} | {:error, term()}
    defp resolve_delay(_datamodel_context, nil), do: {:ok, nil}

    defp resolve_delay(datamodel_context, delay_expr) do
      case Evaluator.evaluate(datamodel_context, delay_expr) do
        {:ok, value} when is_binary(value) or is_map(value) -> Duration.to_ms(value)
        {:ok, other} -> {:error, {:invalid_delay, other}}
        {:error, reason} -> {:error, reason}
      end
    end

    # `namelist` and `<param>` locations/exprs, already merged in document
    # order by the caller. ADR-0036: `<param>` under `<send>` follows 6.2.2's
    # element-level discard, not 5.7's per-`<param>` ignore, so this halts at
    # the first failure instead of dropping it and continuing - the same
    # shape `invoke_one/6`'s own `resolve_params/2` already takes for
    # `<invoke>` under ADR-0031.
    @spec resolve_params(datamodel_context :: Predicator.Context.t(), params :: [Param.t()]) ::
            {:ok, [{String.t(), term()}]} | {:error, term()}
    defp resolve_params(datamodel_context, params) do
      result =
        Enum.reduce_while(params, {:ok, []}, fn %Param{name: name, expr: expr}, {:ok, pairs} ->
          case Evaluator.evaluate(datamodel_context, expr) do
            {:ok, value} -> {:cont, {:ok, [{name, value} | pairs]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
        {:error, reason} -> {:error, reason}
      end
    end

    # `<content>` under `<send>` - `nil` when absent, `<content>`'s text body
    # coerced through `EventData.coerce({:text, _})` when static, or
    # `<content expr>` evaluated and coerced through `{:value, _}` when
    # compiled. Mirrors `invoke_one/6`'s own `resolve_content/2`. Success
    # only: a failed `<content expr>` is this function's caller's `with`
    # failure (ADR-0036's discard), not this function's own.
    @spec resolve_content(
            datamodel_context :: Predicator.Context.t(),
            content :: Machine.expr() | nil
          ) ::
            {:ok, term()} | {:error, term()}
    defp resolve_content(_datamodel_context, nil), do: {:ok, nil}

    defp resolve_content(_datamodel_context, {:static, text}),
      do: {:ok, EventData.coerce({:text, text})}

    defp resolve_content(datamodel_context, {:compiled, _predicator_compiled, _source} = expr) do
      case Evaluator.evaluate(datamodel_context, expr) do
        {:ok, value} -> {:ok, EventData.coerce({:value, value})}
        {:error, reason} -> {:error, reason}
      end
    end

    # `_event.data`: `EventData.coerce({:params, raw_params})` when `<send>`
    # has no `<content>` child (`node.content` is structurally `nil`,
    # regardless of whether `raw_params` happens to be empty), the resolved
    # `<content>` value otherwise - 6.2.1/6.2.3's "Must not occur with"
    # exclusivity means the two never both apply to one document, but the
    # dispatch is keyed on the *node's own shape* rather than on which
    # resolved value happens to be non-nil, since a blank `<content/>`
    # legitimately coerces to `:undefined` too.
    @spec data(node :: Send.t(), raw_params :: [{String.t(), term()}], content :: term()) ::
            term()
    defp data(%Send{content: nil}, raw_params, _content),
      do: EventData.coerce({:params, raw_params})

    defp data(%Send{}, _raw_params, content), do: content

    # ADR-0035: the author's literal `id`, used verbatim, or the generated
    # `"send_" <> Integer.to_string(counter + 1)` off
    # `machine_state.send_counter` - generated fresh for *this* execution,
    # never memoized on the `<send>` element (3.14: "not at load time but
    # each time the element is executed", mirroring `generate_invoke_id/3`).
    # An author-written id never advances the counter - only a generated id
    # consumes the session-global sequence.
    @spec generate_send_id(machine_state :: MachineState.t(), node :: Send.t()) ::
            {String.t(), MachineState.t()}
    defp generate_send_id(machine_state, %Send{id: id}) when is_binary(id),
      do: {id, machine_state}

    defp generate_send_id(%MachineState{send_counter: counter} = machine_state, %Send{id: nil}) do
      machine_state = %{machine_state | send_counter: counter + 1}
      {"send_" <> Integer.to_string(counter + 1), machine_state}
    end

    # `idlocation`'s write (6.2.1) - a no-op tuple shaped like
    # `Interpreter.Datamodel.write_location/4`'s own success return when the
    # attribute is absent, so the caller's `case` needs only one shape
    # regardless. Mirrors `invoke_one/6`'s own `maybe_write_idlocation/4`. A
    # write failure is an argument failure per ADR-0036 - no effect,
    # `{:error, reason}`.
    @spec maybe_write_idlocation(
            machine_state :: MachineState.t(),
            datamodel_context :: Predicator.Context.t(),
            idlocation :: String.t() | nil,
            send_id :: String.t()
          ) ::
            {:ok, MachineState.t(), Predicator.Context.t(), Datamodel.Write.t() | nil}
            | {:error, term()}
    defp maybe_write_idlocation(machine_state, datamodel_context, nil, _send_id),
      do: {:ok, machine_state, datamodel_context, nil}

    defp maybe_write_idlocation(machine_state, datamodel_context, idlocation, send_id),
      do: Datamodel.write_location(machine_state, datamodel_context, idlocation, send_id)

    # `nil` (no idlocation was written, or the write failed and never
    # reached here) -> no effect; a %Datamodel.Write{} -> one
    # {:datamodel_change, _} effect, carrying this node's own c_index/owner
    # and the post-write counters (immaterial, since the write touches only
    # `datamodel`).
    @spec datamodel_change_effects(
            write :: Datamodel.Write.t() | nil,
            node :: Send.t(),
            owner :: Machine.Content.owner(),
            machine_state :: MachineState.t()
          ) :: [{:datamodel_change, Effect.DatamodelChange.t()}]
    defp datamodel_change_effects(nil, %Send{}, _owner, _machine_state), do: []

    defp datamodel_change_effects(
           %Datamodel.Write{} = write,
           %Send{c_index: c_index} = node,
           owner,
           ms
         ) do
      [
        {:datamodel_change,
         %Effect.DatamodelChange{
           location_path: write.path,
           location_source: node.idlocation,
           new_value: write.new_value,
           prior_value: write.prior_value,
           c_index: c_index,
           owner: owner,
           macrostep: ms.macrostep,
           microstep: ms.microstep,
           round: ms.round
         }}
      ]
    end

    # `nil` delay -> `{:send, %Effect.Send{}}`; a resolved delay ->
    # `{:send_delayed, %Effect.SendDelayed{}}`. Both carry `c_index`,
    # `owner` (which block emitted the send), and the step counters as they
    # stand at the moment of the send. `fields` bundles `event`/`target`/
    # `type`/`data` - the four resolved values both effect shapes share
    # verbatim - purely to keep this function's own arity under Credo's
    # limit; it carries no meaning of its own beyond that grouping.
    @spec build_effect(
            node :: Send.t(),
            fields :: %{
              event: String.t() | nil,
              target: String.t() | nil,
              type: String.t() | nil,
              data: term()
            },
            send_id :: String.t(),
            delay_ms :: non_neg_integer() | nil,
            owner :: Machine.Content.owner(),
            machine_state :: MachineState.t()
          ) :: {:send, Effect.Send.t()} | {:send_delayed, Effect.SendDelayed.t()}
    defp build_effect(%Send{c_index: c_index} = node, fields, send_id, nil, owner, ms) do
      {:send,
       %Effect.Send{
         event: fields.event,
         target: fields.target,
         type: fields.type,
         data: fields.data,
         send_id: send_id,
         c_index: c_index,
         owner: owner,
         macrostep: ms.macrostep,
         microstep: ms.microstep,
         round: ms.round,
         id_from_author?: id_from_author?(node)
       }}
    end

    defp build_effect(%Send{c_index: c_index} = node, fields, send_id, delay_ms, owner, ms)
         when is_integer(delay_ms) do
      {:send_delayed,
       %Effect.SendDelayed{
         event: fields.event,
         target: fields.target,
         type: fields.type,
         data: fields.data,
         send_id: send_id,
         delay_ms: delay_ms,
         c_index: c_index,
         owner: owner,
         macrostep: ms.macrostep,
         microstep: ms.microstep,
         round: ms.round,
         id_from_author?: id_from_author?(node)
       }}
    end

    # C.1's empty-`sendid` rule: `true` only when the author wrote `id` or
    # `idlocation` on this `<send>` - `send_id` itself is always non-`nil`
    # (ADR-0035 generates one when the author did not), so this flag is the
    # only place that distinction survives past `generate_send_id/2`.
    @spec id_from_author?(node :: Send.t()) :: boolean()
    defp id_from_author?(%Send{id: id, idlocation: idlocation}),
      do: id != nil or idlocation != nil
  end
end
