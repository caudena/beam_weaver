defmodule BeamWeaver.OpenAI.RequestMetadata do
  @moduledoc false

  # OpenAI's API reference gives a request's `metadata`, on Responses and on
  # Chat Completions alike, at most 16 key-value pairs, with keys of at most
  # 64 characters and string values of at most 512. A model's metadata is
  # checked when the model is created (see `BeamWeaver.OpenAI.Provider`) and
  # with each call's, as it is sent: keys and atom values become strings.

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.Options

  @max_pairs 16
  @max_key_length 64
  @max_value_length 512

  @spec validate(term(), String.t() | nil) :: :ok | {:error, Error.t()}
  def validate(nil, _model), do: :ok

  def validate(metadata, model) when is_map(metadata) do
    pairs = Options.normalize_option_map(metadata)
    keys = Map.keys(pairs)

    cond do
      map_size(pairs) > @max_pairs ->
        error(model, "OpenAI metadata takes at most #{@max_pairs} key-value pairs", max_pairs: @max_pairs)

      key = Enum.find(keys, &Options.longer_than?(&1, @max_key_length)) ->
        error(model, "OpenAI metadata key #{name(key)} is longer than #{@max_key_length} characters",
          key: key,
          max_key_length: @max_key_length
        )

      key = Enum.find(keys, &(not is_binary(pairs[&1]))) ->
        error(model, "OpenAI metadata value for #{name(key)} must be a string", key: key, expected: :string)

      key = Enum.find(keys, &Options.longer_than?(pairs[&1], @max_value_length)) ->
        error(model, "OpenAI metadata value for #{name(key)} is longer than #{@max_value_length} characters",
          key: key,
          max_value_length: @max_value_length
        )

      true ->
        :ok
    end
  end

  def validate(_metadata, model),
    do: error(model, "OpenAI metadata must be a map of string keys to string values", expected: :map)

  # The error names a key, never a value, which can carry a user id.
  defp name(key), do: inspect(key, printable_limit: @max_key_length)

  defp error(model, message, details) do
    {:error,
     Error.new(
       :unsupported_model_param,
       message,
       Enum.into(details, %{provider: :openai, model: model, params: [:metadata]})
     )}
  end
end
