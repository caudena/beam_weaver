defmodule BeamWeaver.StructuredQuery do
  @moduledoc """
  Native structured retrieval query values.

  This is intentionally a small Elixir value layer that compiles to
  BeamWeaver filter maps. It is not a Pydantic AST clone.
  """

  alias BeamWeaver.Core.Error

  @type operator :: :and | :or | :not
  @type comparator :: :eq | :ne | :gt | :gte | :lt | :lte | :contain | :like | :in | :nin

  defmodule Comparison do
    @moduledoc "Comparison of a metadata attribute to a value."
    @enforce_keys [:comparator, :attribute, :value]
    defstruct [:comparator, :attribute, :value]

    @type t :: %__MODULE__{
            comparator: BeamWeaver.StructuredQuery.comparator(),
            attribute: String.t() | atom() | [String.t() | atom()],
            value: term()
          }
  end

  defmodule Operation do
    @moduledoc "Logical operation over structured-query filters."
    @enforce_keys [:operator, :arguments]
    defstruct [:operator, arguments: []]

    @type t :: %__MODULE__{
            operator: BeamWeaver.StructuredQuery.operator(),
            arguments: [BeamWeaver.StructuredQuery.filter()]
          }
  end

  defmodule Query do
    @moduledoc "Query string with an optional filter expression and limit."
    @enforce_keys [:query]
    defstruct [:query, :filter, :limit]

    @type t :: %__MODULE__{
            query: String.t(),
            filter: BeamWeaver.StructuredQuery.filter() | nil,
            limit: pos_integer() | nil
          }
  end

  @type filter :: Comparison.t() | Operation.t()
  @type t :: Query.t()

  @doc "Builds a structured query."
  @spec new(String.t(), filter() | nil, keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(query, filter \\ nil, opts \\ [])

  def new(query, filter, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit)

    with :ok <- validate_filter_or_nil(filter),
         :ok <- validate_limit(limit) do
      {:ok, %Query{query: query, filter: filter, limit: limit}}
    end
  end

  def new(query, _filter, _opts),
    do: {:error, Error.new(:invalid_structured_query, "query must be a string", %{query: query})}

  @doc "Builds a comparison filter."
  @spec comparison(comparator(), String.t() | atom() | [String.t() | atom()], term()) ::
          {:ok, Comparison.t()} | {:error, Error.t()}
  def comparison(comparator, attribute, value) do
    with {:ok, comparator} <- normalize_comparator(comparator),
         :ok <- validate_attribute(attribute) do
      {:ok, %Comparison{comparator: comparator, attribute: attribute, value: value}}
    end
  end

  @doc "Builds a logical operation."
  @spec operation(operator(), [filter()]) :: {:ok, Operation.t()} | {:error, Error.t()}
  def operation(operator, arguments) when is_list(arguments) do
    with {:ok, operator} <- normalize_operator(operator),
         :ok <- validate_operation_arguments(operator, arguments) do
      {:ok, %Operation{operator: operator, arguments: arguments}}
    end
  end

  def operation(_operator, arguments),
    do:
      {:error,
       Error.new(:invalid_structured_query, "operation arguments must be a list", %{
         arguments: arguments
       })}

  @doc """
  Compiles a structured-query filter to the native BeamWeaver filter map.
  """
  @spec to_filter(filter() | nil) :: {:ok, map()} | {:error, Error.t()}
  def to_filter(nil), do: {:ok, %{}}

  def to_filter(%Comparison{comparator: comparator, attribute: attribute, value: value}) do
    key = filter_key(attribute)

    filter =
      case comparator do
        :eq -> %{key => value}
        :ne -> %{key => %{"$ne" => value}}
        :gt -> %{key => %{"$gt" => value}}
        :gte -> %{key => %{"$gte" => value}}
        :lt -> %{key => %{"$lt" => value}}
        :lte -> %{key => %{"$lte" => value}}
        :contain -> %{key => %{"$contain" => value}}
        :like -> %{key => %{"$like" => value}}
        :in -> %{key => %{"$in" => List.wrap(value)}}
        :nin -> %{key => %{"$nin" => List.wrap(value)}}
      end

    {:ok, filter}
  end

  def to_filter(%Operation{operator: operator, arguments: arguments}) do
    with {:ok, filters} <- map_filters(arguments) do
      case operator do
        :and -> {:ok, %{"$and" => filters}}
        :or -> {:ok, %{"$or" => filters}}
        :not -> {:ok, %{"$not" => List.first(filters)}}
      end
    end
  end

  def to_filter(other),
    do:
      {:error,
       Error.new(:invalid_structured_query, "expected a structured-query filter", %{
         filter: inspect(other)
       })}

  @doc "Returns `{query, opts}` suitable for retriever or vector-store calls."
  @spec to_retrieval(t()) :: {:ok, {String.t(), keyword()}} | {:error, Error.t()}
  def to_retrieval(%Query{} = query) do
    with {:ok, filter} <- to_filter(query.filter) do
      opts = []
      opts = if filter == %{}, do: opts, else: Keyword.put(opts, :filter, filter)
      opts = if is_integer(query.limit), do: Keyword.put(opts, :k, query.limit), else: opts
      {:ok, {query.query, opts}}
    end
  end

  @doc """
  Dispatches a query expression to a visitor module or function map.
  """
  @spec accept(t() | filter(), module() | map(), keyword()) :: term()
  def accept(expression, visitor, opts \\ [])

  def accept(%Comparison{} = comparison, visitor, opts),
    do: dispatch(visitor, :visit_comparison, [comparison, opts])

  def accept(%Operation{} = operation, visitor, opts),
    do: dispatch(visitor, :visit_operation, [operation, opts])

  def accept(%Query{} = query, visitor, opts),
    do: dispatch(visitor, :visit_structured_query, [query, opts])

  defp dispatch(visitor, callback, args) when is_atom(visitor) do
    apply(visitor, callback, args)
  end

  defp dispatch(visitor, callback, args) when is_map(visitor) do
    case Map.fetch(visitor, callback) do
      {:ok, fun} when is_function(fun) ->
        apply(fun, args)

      :error ->
        {:error,
         Error.new(:invalid_structured_query_visitor, "visitor callback missing", %{
           callback: callback
         })}
    end
  end

  defp normalize_comparator(comparator)
       when comparator in [:eq, "eq", :==, "=="],
       do: {:ok, :eq}

  defp normalize_comparator(comparator) when comparator in [:ne, "ne", :!=, "!="], do: {:ok, :ne}
  defp normalize_comparator(comparator) when comparator in [:gt, "gt", :>, ">"], do: {:ok, :gt}

  defp normalize_comparator(comparator) when comparator in [:gte, "gte", :>=, ">="],
    do: {:ok, :gte}

  defp normalize_comparator(comparator) when comparator in [:lt, "lt", :<, "<"], do: {:ok, :lt}

  defp normalize_comparator(comparator) when comparator in [:lte, "lte", :<=, "<="],
    do: {:ok, :lte}

  defp normalize_comparator(comparator) when comparator in [:contain, "contain"],
    do: {:ok, :contain}

  defp normalize_comparator(comparator) when comparator in [:like, "like"], do: {:ok, :like}
  defp normalize_comparator(comparator) when comparator in [:in, "in"], do: {:ok, :in}
  defp normalize_comparator(comparator) when comparator in [:nin, "nin"], do: {:ok, :nin}

  defp normalize_comparator(comparator),
    do: {:error, Error.new(:invalid_structured_query, "unsupported comparator", %{comparator: comparator})}

  defp normalize_operator(operator) when operator in [:and, "and"], do: {:ok, :and}
  defp normalize_operator(operator) when operator in [:or, "or"], do: {:ok, :or}
  defp normalize_operator(operator) when operator in [:not, "not"], do: {:ok, :not}

  defp normalize_operator(operator),
    do: {:error, Error.new(:invalid_structured_query, "unsupported operator", %{operator: operator})}

  defp validate_attribute(attribute) when is_atom(attribute) or is_binary(attribute), do: :ok

  defp validate_attribute(attribute) when is_list(attribute) do
    if Enum.all?(attribute, &(is_atom(&1) or is_binary(&1))) and attribute != [] do
      :ok
    else
      {:error,
       Error.new(:invalid_structured_query, "attribute path must contain atoms or strings", %{
         attribute: attribute
       })}
    end
  end

  defp validate_attribute(attribute),
    do:
      {:error,
       Error.new(:invalid_structured_query, "attribute must be an atom, string, or path", %{
         attribute: attribute
       })}

  defp validate_filter_or_nil(nil), do: :ok
  defp validate_filter_or_nil(%Comparison{}), do: :ok
  defp validate_filter_or_nil(%Operation{}), do: :ok

  defp validate_filter_or_nil(filter),
    do:
      {:error,
       Error.new(:invalid_structured_query, "filter must be a structured-query expression", %{
         filter: inspect(filter)
       })}

  defp validate_limit(nil), do: :ok
  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit(limit),
    do: {:error, Error.new(:invalid_structured_query, "limit must be a positive integer", %{limit: limit})}

  defp validate_operation_arguments(:not, [_argument]), do: :ok

  defp validate_operation_arguments(:not, arguments),
    do:
      {:error,
       Error.new(:invalid_structured_query, "not operation requires exactly one argument", %{
         arguments: arguments
       })}

  defp validate_operation_arguments(_operator, [_argument | _rest] = arguments) do
    Enum.reduce_while(arguments, :ok, fn argument, :ok ->
      case validate_filter_or_nil(argument) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_operation_arguments(_operator, arguments),
    do:
      {:error,
       Error.new(:invalid_structured_query, "operation requires at least one argument", %{
         arguments: arguments
       })}

  defp map_filters(arguments) do
    Enum.reduce_while(arguments, {:ok, []}, fn argument, {:ok, filters} ->
      case to_filter(argument) do
        {:ok, filter} -> {:cont, {:ok, [filter | filters]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, filters} -> {:ok, Enum.reverse(filters)}
      error -> error
    end
  end

  defp filter_key(attribute) when is_list(attribute), do: Enum.map(attribute, &to_string/1)
  defp filter_key(attribute), do: to_string(attribute)
end
