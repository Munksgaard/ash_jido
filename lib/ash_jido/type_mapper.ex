defmodule AshJido.TypeMapper do
  @moduledoc false

  @doc """
  Converts an Ash type to a NimbleOptions schema entry.

  ## Examples

      iex> AshJido.TypeMapper.ash_type_to_nimble_options(Ash.Type.String, %{allow_nil?: false})
      [type: :string, required: true]

      iex> AshJido.TypeMapper.ash_type_to_nimble_options(Ash.Type.Integer, %{allow_nil?: true})
      [type: :integer]
  """
  def ash_type_to_nimble_options(ash_type, field_config \\ %{}) do
    base_type = map_ash_type(ash_type)

    [type: base_type]
    |> maybe_add_required(field_config)
    |> maybe_add_doc(field_config)
    |> maybe_add_default(field_config)
  end

  @doc """
  Converts an Ash TypedStruct module to a NimbleOptions keyword list schema.

  This is useful for generating structured output schemas for LLM calls
  via ReqLLM.generate_object/4.

  ## Examples

      iex> AshJido.TypeMapper.typed_struct_to_schema(MyApp.PersonResult)
      [
        name: [type: :string, required: true, doc: "The person's name"],
        age: [type: :integer, doc: "The person's age"]
      ]
  """
  @spec typed_struct_to_schema(module()) :: keyword()
  def typed_struct_to_schema(module) when is_atom(module) do
    # Get field definitions from the TypedStruct's subtype_constraints
    constraints = module.subtype_constraints()
    fields = Keyword.get(constraints, :fields, [])

    Keyword.new(fields, fn {name, field_opts} ->
      field_config = Map.new(field_opts)
      opts = ash_type_to_nimble_options(field_config[:type], field_config)

      # Add enum constraint for atoms with one_of
      opts = maybe_add_enum_constraint(opts, field_config)

      {name, opts}
    end)
  end

  @doc """
  Converts an Ash TypedStruct module to a schema, optionally wrapped as an
  array for list return types.

  With `:single` mode, returns a NimbleOptions keyword list (same as `/1`).

  With `:array` mode, returns a JSON Schema map with `"type" => "array"`
  wrapping the object schema. This is necessary because NimbleOptions keyword
  lists cannot represent a top-level array — only objects. The JSON Schema map
  format is accepted by ReqLLM.generate_object/4.

  ## Examples

      schema = AshJido.TypeMapper.typed_struct_to_schema(MyApp.PersonResult, :array)
      # => %{"type" => "array", "items" => %{"type" => "object", "properties" => ...}}
  """
  @spec typed_struct_to_schema(module(), :single | :array) :: keyword() | map()
  def typed_struct_to_schema(module, :single), do: typed_struct_to_schema(module)

  def typed_struct_to_schema(module, :array) do
    object_schema = typed_struct_to_schema(module)
    %{"type" => "array", "items" => keyword_schema_to_json_schema(object_schema)}
  end

  @doc false
  def keyword_schema_to_json_schema(schema) when is_list(schema) do
    {properties, required} =
      Enum.reduce(schema, {%{}, []}, fn {key, opts}, {props, req} ->
        name = to_string(key)
        prop = nimble_type_to_json_property(opts[:type] || :string, opts)
        props = Map.put(props, name, prop)
        req = if opts[:required], do: [name | req], else: req
        {props, req}
      end)

    schema = %{"type" => "object", "properties" => properties}
    if required == [], do: schema, else: Map.put(schema, "required", Enum.reverse(required))
  end

  defp nimble_type_to_json_property(type, opts) do
    base = nimble_type_to_json_type(type)
    if opts[:doc], do: Map.put(base, "description", opts[:doc]), else: base
  end

  defp nimble_type_to_json_type(:string), do: %{"type" => "string"}
  defp nimble_type_to_json_type(:integer), do: %{"type" => "integer"}
  defp nimble_type_to_json_type(:float), do: %{"type" => "number"}
  defp nimble_type_to_json_type(:boolean), do: %{"type" => "boolean"}
  defp nimble_type_to_json_type(:atom), do: %{"type" => "string"}
  defp nimble_type_to_json_type(:map), do: %{"type" => "object"}
  defp nimble_type_to_json_type(:any), do: %{}
  defp nimble_type_to_json_type({:list, inner}), do: %{"type" => "array", "items" => nimble_type_to_json_type(inner)}
  defp nimble_type_to_json_type({:in, values}), do: %{"type" => "string", "enum" => values}
  defp nimble_type_to_json_type(_), do: %{"type" => "string"}

  @doc """
  Maps an Ash type to its corresponding NimbleOptions type.
  """
  def map_ash_type(ash_type) do
    case ash_type do
      Ash.Type.String -> :string
      Ash.Type.Integer -> :integer
      Ash.Type.Float -> :float
      Ash.Type.Decimal -> :float
      Ash.Type.Boolean -> :boolean
      Ash.Type.UUID -> :string
      Ash.Type.Date -> :string
      Ash.Type.DateTime -> :string
      Ash.Type.Time -> :string
      Ash.Type.Binary -> :string
      Ash.Type.Atom -> :atom
      Ash.Type.Map -> :map
      Ash.Type.Term -> :any
      {:array, inner_type} -> {:list, map_ash_type(inner_type)}
      _ -> :any
    end
  end

  defp maybe_add_required(options, field_config) do
    case field_config do
      %{allow_nil?: false} -> Keyword.put(options, :required, true)
      _ -> options
    end
  end

  defp maybe_add_doc(options, field_config) do
    case field_config do
      %{description: description} when is_binary(description) ->
        Keyword.put(options, :doc, description)

      _ ->
        options
    end
  end

  defp maybe_add_default(options, field_config) do
    case field_config do
      %{default: default} when not is_nil(default) ->
        Keyword.put(options, :default, default)

      _ ->
        options
    end
  end

  # Handles enum constraints for atoms with one_of values
  # For LLMs, we convert atom enums to string values since LLMs return strings
  defp maybe_add_enum_constraint(opts, %{type: Ash.Type.Atom, constraints: constraints})
       when is_list(constraints) do
    case Keyword.get(constraints, :one_of) do
      values when is_list(values) and values != [] ->
        # Convert atom enum values to string list for LLM schema
        # LLMs return strings, not atoms — the values serve as documentation
        string_values = Enum.map(values, &to_string/1)

        # Use {:in, values} constraint for NimbleOptions
        opts
        |> Keyword.put(:type, {:in, string_values})

      _ ->
        opts
    end
  end

  defp maybe_add_enum_constraint(opts, _field_config), do: opts
end
