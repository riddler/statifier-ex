defmodule Statifier.CorpusSchemaChecker do
  @moduledoc """
  A small, hand-written JSON Schema checker for the schemas under
  `conformance/schema/`, and for nothing else.

  It implements exactly the draft 2020-12 keywords those schemas use -
  `type`, `enum`, `const`, `pattern`, `minLength`, `minimum`, `properties`,
  `required`, `additionalProperties: false`, `items`, `minItems`,
  `uniqueItems`, `allOf`, `if`/`then`, `not`, and a `$ref` naming a sibling
  schema file - and treats `$schema`, `$id`, `title` and `description` as
  annotations. It is not a general JSON Schema engine: `unsupported_keywords/1`
  lists any other keyword a schema uses, so a schema that grows a keyword this
  checker would silently ignore fails its test instead of passing it.

  Test-only and dependency-free on purpose; the model is predicator-ex's
  hand-written conformance schema checker.
  """

  @annotations ~w($schema $id title description)
  @assertions ~w(type enum const pattern minLength minimum properties required
                 additionalProperties items minItems uniqueItems allOf if then not $ref)

  @typedoc "An error: the JSON pointer into the instance, and what failed there."
  @type error :: {pointer :: String.t(), reason :: String.t()}

  @doc "Every keyword this checker understands, annotations included."
  @spec supported_keywords() :: [String.t()]
  def supported_keywords, do: @annotations ++ @assertions

  @doc """
  Returns every keyword `schema` uses, at any depth, that this checker does
  not implement, as `{schema_pointer, keyword}` pairs. Empty means every
  keyword the schema uses is checked.
  """
  @spec unsupported_keywords(schema :: map() | boolean()) :: [{String.t(), String.t()}]
  def unsupported_keywords(schema), do: walk_keywords(schema, "")

  @doc """
  Returns every `$ref` value in `schema`, at any depth, so a test can prove
  each one resolves.
  """
  @spec refs(schema :: map() | boolean()) :: [String.t()]
  def refs(schema) when is_map(schema) do
    own = if is_binary(schema["$ref"]), do: [schema["$ref"]], else: []
    own ++ Enum.flat_map(subschemas(schema), fn {_pointer, sub} -> refs(sub) end)
  end

  def refs(_schema), do: []

  @doc """
  Validates `instance` against `schema`. A `$ref` names a schema file in
  `schema_dir`. Returns the errors found; an empty list means valid.
  """
  @spec errors(schema :: map() | boolean(), instance :: term(), schema_dir :: Path.t()) :: [
          error()
        ]
  def errors(schema, instance, schema_dir), do: check(schema, instance, "", schema_dir)

  @doc "Loads and decodes the schema file `name` from `schema_dir`."
  @spec load(schema_dir :: Path.t(), name :: String.t()) :: map()
  def load(schema_dir, name), do: schema_dir |> Path.join(name) |> File.read!() |> JSON.decode!()

  # --- keyword walk -------------------------------------------------------

  defp walk_keywords(schema, pointer) when is_map(schema) do
    own =
      for {key, value} <- schema, not supported?(key, value) do
        {pointer, key}
      end

    nested =
      Enum.flat_map(subschemas(schema), fn {sub_pointer, sub} ->
        walk_keywords(sub, pointer <> sub_pointer)
      end)

    own ++ nested
  end

  defp walk_keywords(_schema, _pointer), do: []

  # Two keywords are implemented for one form only: `additionalProperties`
  # as `false`, and `$ref` as a bare sibling file name.
  defp supported?("additionalProperties", value), do: value == false

  defp supported?("$ref", value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z]+\.json\z/, value)

  defp supported?(key, _value), do: key in @annotations or key in @assertions

  defp subschemas(schema) do
    properties =
      for {name, sub} <- Map.get(schema, "properties", %{}), do: {"/properties/#{name}", sub}

    all_of =
      for {sub, index} <- Enum.with_index(Map.get(schema, "allOf", [])),
          do: {"/allOf/#{index}", sub}

    single =
      for key <- ~w(items if then not), Map.has_key?(schema, key), do: {"/" <> key, schema[key]}

    properties ++ all_of ++ single
  end

  # --- validation ---------------------------------------------------------

  defp check(true, _instance, _pointer, _dir), do: []
  defp check(false, _instance, pointer, _dir), do: [{pointer, "no value is allowed here"}]

  defp check(schema, instance, pointer, dir) when is_map(schema) do
    Enum.flat_map(schema, fn {keyword, value} ->
      keyword(keyword, value, schema, instance, pointer, dir)
    end)
  end

  defp keyword(annotation, _value, _schema, _instance, _pointer, _dir)
       when annotation in @annotations,
       do: []

  defp keyword("type", type, _schema, instance, pointer, _dir) do
    types = List.wrap(type)

    if Enum.any?(types, &type?(&1, instance)),
      do: [],
      else: [{pointer, "expected type #{Enum.join(types, " or ")}"}]
  end

  defp keyword("enum", allowed, _schema, instance, pointer, _dir) do
    if instance in allowed, do: [], else: [{pointer, "not one of #{inspect(allowed)}"}]
  end

  defp keyword("const", expected, _schema, instance, pointer, _dir) do
    if instance == expected, do: [], else: [{pointer, "expected #{inspect(expected)}"}]
  end

  defp keyword("pattern", pattern, _schema, instance, pointer, _dir) when is_binary(instance) do
    if Regex.match?(Regex.compile!(pattern), instance),
      do: [],
      else: [{pointer, "does not match #{pattern}"}]
  end

  defp keyword("minLength", min, _schema, instance, pointer, _dir) when is_binary(instance) do
    if length(String.codepoints(instance)) >= min,
      do: [],
      else: [{pointer, "shorter than #{min}"}]
  end

  defp keyword("minimum", min, _schema, instance, pointer, _dir) when is_number(instance) do
    if instance >= min, do: [], else: [{pointer, "less than #{min}"}]
  end

  defp keyword("required", keys, _schema, instance, pointer, _dir) when is_map(instance) do
    for key <- keys, not Map.has_key?(instance, key), do: {pointer, "missing required #{key}"}
  end

  defp keyword("properties", properties, _schema, instance, pointer, dir)
       when is_map(instance) do
    Enum.flat_map(properties, fn {key, sub} ->
      if Map.has_key?(instance, key),
        do: check(sub, instance[key], pointer <> "/" <> key, dir),
        else: []
    end)
  end

  defp keyword("additionalProperties", false, schema, instance, pointer, _dir)
       when is_map(instance) do
    known = schema |> Map.get("properties", %{}) |> Map.keys()

    for key <- Map.keys(instance), key not in known do
      {pointer <> "/" <> key, "property is not allowed"}
    end
  end

  defp keyword("items", sub, _schema, instance, pointer, dir) when is_list(instance) do
    instance
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> check(sub, item, "#{pointer}/#{index}", dir) end)
  end

  defp keyword("minItems", min, _schema, instance, pointer, _dir) when is_list(instance) do
    if length(instance) >= min, do: [], else: [{pointer, "fewer than #{min} items"}]
  end

  defp keyword("uniqueItems", true, _schema, instance, pointer, _dir) when is_list(instance) do
    if length(Enum.uniq(instance)) == length(instance),
      do: [],
      else: [{pointer, "items are not unique"}]
  end

  defp keyword("allOf", subs, _schema, instance, pointer, dir) do
    Enum.flat_map(subs, &check(&1, instance, pointer, dir))
  end

  defp keyword("if", condition, schema, instance, pointer, dir) do
    if check(condition, instance, pointer, dir) == [] and Map.has_key?(schema, "then"),
      do: check(schema["then"], instance, pointer, dir),
      else: []
  end

  defp keyword("then", _sub, _schema, _instance, _pointer, _dir), do: []

  defp keyword("not", sub, _schema, instance, pointer, dir) do
    if check(sub, instance, pointer, dir) == [],
      do: [{pointer, "matches a schema it must not match: #{inspect(sub)}"}],
      else: []
  end

  defp keyword("$ref", name, _schema, instance, pointer, dir) do
    dir |> load(name) |> check(instance, pointer, dir)
  end

  # A type-specific keyword applied to a value of another type asserts nothing.
  defp keyword(keyword, _value, _schema, _instance, _pointer, _dir)
       when keyword in @assertions,
       do: []

  defp keyword(keyword, _value, _schema, _instance, pointer, _dir) do
    raise ArgumentError, "unsupported JSON Schema keyword #{inspect(keyword)} at #{pointer}"
  end

  defp type?("string", value), do: is_binary(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("number", value), do: is_number(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("null", value), do: is_nil(value)
  defp type?("array", value), do: is_list(value)
  defp type?("object", value), do: is_map(value)
end
