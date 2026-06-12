defmodule BeamWeaver.Models.ProfileCompiler do
  @moduledoc """
  Compiles models.dev-style data into BeamWeaver model profiles.

  This is the Elixir-native equivalent of the pure profile transformation logic
  from `langchain_model_profiles.cli`: it maps raw provider data, applies
  provider/model augmentations, validates keys against `Profile`, and returns
  deterministic profile structs. Fetching remote data and writing generated
  source files remain separate tooling concerns.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile

  @doc """
  Converts one models.dev model record into a profile map.

  `nil` values are omitted. The returned map intentionally contains only
  profile fields; provider/model identifiers are attached by `compile_provider/3`.
  """
  @spec model_data_to_profile(map()) :: map()
  def model_data_to_profile(model_data) when is_map(model_data) do
    limit = get_map(model_data, "limit")
    modalities = get_map(model_data, "modalities")
    input_modalities = get_list(modalities, "input")
    output_modalities = get_list(modalities, "output")

    %{
      name: get_value(model_data, "name"),
      status: get_value(model_data, "status"),
      release_date: get_value(model_data, "release_date"),
      last_updated: get_value(model_data, "last_updated"),
      open_weights: get_value(model_data, "open_weights"),
      max_input_tokens: get_value(limit, "context"),
      max_output_tokens: get_value(limit, "output"),
      text_inputs: "text" in input_modalities,
      image_inputs: "image" in input_modalities,
      audio_inputs: "audio" in input_modalities,
      pdf_inputs: "pdf" in input_modalities or truthy?(get_value(model_data, "pdf_inputs")),
      video_inputs: "video" in input_modalities,
      text_outputs: "text" in output_modalities,
      image_outputs: "image" in output_modalities,
      audio_outputs: "audio" in output_modalities,
      video_outputs: "video" in output_modalities,
      reasoning_output: get_value(model_data, "reasoning"),
      tool_calling: get_value(model_data, "tool_call"),
      tool_choice: get_value(model_data, "tool_choice"),
      structured_output: get_value(model_data, "structured_output"),
      structured_output_with_tools: get_value(model_data, "structured_output_with_tools"),
      structured_output_max_schema_bytes: get_value(model_data, "structured_output_max_schema_bytes"),
      structured_output_max_schema_properties: get_value(model_data, "structured_output_max_schema_properties"),
      attachment: get_value(model_data, "attachment"),
      temperature: get_value(model_data, "temperature"),
      image_url_inputs: get_value(model_data, "image_url_inputs"),
      image_tool_message: get_value(model_data, "image_tool_message"),
      pdf_tool_message: get_value(model_data, "pdf_tool_message")
    }
    |> reject_nil_values()
  end

  @doc """
  Merges non-nil overrides into a profile map.
  """
  @spec apply_overrides(map(), [map() | nil]) :: map()
  def apply_overrides(profile, overrides) when is_list(overrides) do
    Enum.reduce(overrides, profile, fn
      nil, acc ->
        acc

      override, acc when is_map(override) ->
        override
        |> normalize_keys()
        |> reject_nil_values()
        |> then(&Map.merge(acc, &1))
    end)
  end

  @doc """
  Returns profile keys that are not declared by `BeamWeaver.Models.Profile`.
  """
  @spec undeclared_keys(map() | [map() | Profile.t()]) :: [atom() | String.t()]
  def undeclared_keys(profiles) when is_map(profiles) do
    profiles
    |> Map.values()
    |> undeclared_keys()
  end

  def undeclared_keys(profiles) when is_list(profiles) do
    declared = MapSet.new(Profile.known_keys())

    profiles
    |> Enum.flat_map(fn
      %Profile{} = profile ->
        Map.keys(profile.extra || %{})

      profile when is_map(profile) ->
        Map.keys(normalize_keys(profile)) -- MapSet.to_list(declared)

      _other ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
  end

  @doc """
  Validates that profile maps only contain keys declared by `Profile`.
  """
  @spec validate_keys(map() | [map() | Profile.t()]) :: :ok | {:error, Error.t()}
  def validate_keys(profiles) do
    case undeclared_keys(profiles) do
      [] ->
        :ok

      keys ->
        {:error,
         Error.new(:undeclared_profile_keys, "profile data contains undeclared keys", %{
           keys: keys
         })}
    end
  end

  @doc """
  Compiles a provider's models.dev response into sorted Profile structs.

  Options:

    * `:provider_overrides` - values applied to every provider model.
    * `:model_overrides` - map of model id to model-specific values. Models
      present only in overrides are included.
  """
  @spec compile_provider(map(), String.t() | atom(), keyword()) ::
          {:ok, [Profile.t()]} | {:error, Error.t()}
  def compile_provider(models_dev_response, provider, opts \\ [])
      when is_map(models_dev_response) do
    provider_key = to_string(provider)

    with {:ok, provider_data} <- fetch_provider(models_dev_response, provider_key) do
      provider_overrides = Keyword.get(opts, :provider_overrides, %{})
      model_overrides = Keyword.get(opts, :model_overrides, %{})
      provider_atom = provider_atom(provider_key)

      model_ids =
        provider_data
        |> get_map("models")
        |> Map.keys()
        |> Kernel.++(model_overrides |> normalize_model_overrides() |> Map.keys())
        |> Enum.uniq()
        |> Enum.sort()

      profiles =
        Enum.map(model_ids, fn model_id ->
          model_data =
            provider_data
            |> get_map("models")
            |> Map.get(model_id, %{})

          override =
            model_overrides
            |> normalize_model_overrides()
            |> Map.get(model_id, %{})

          model_data
          |> model_data_to_profile()
          |> apply_overrides([provider_overrides, override])
          |> Map.put(:provider, provider_atom)
          |> Map.put(:id, model_id)
          |> Profile.new()
        end)

      {:ok, profiles}
    end
  end

  defp fetch_provider(response, provider) do
    case get_value(response, provider) do
      provider_data when is_map(provider_data) ->
        {:ok, stringify_lookup_keys(provider_data)}

      _missing ->
        {:error,
         Error.new(:missing_profile_provider, "models.dev response has no provider", %{
           provider: provider
         })}
    end
  end

  defp normalize_model_overrides(overrides) when is_map(overrides) do
    Map.new(overrides, fn {model_id, attrs} -> {to_string(model_id), attrs || %{}} end)
  end

  defp get_map(map, key) do
    case get_value(map, key) do
      value when is_map(value) -> stringify_lookup_keys(value)
      _other -> %{}
    end
  end

  defp get_list(map, key) do
    case get_value(map, key) do
      value when is_list(value) -> Enum.map(value, &to_string/1)
      _other -> []
    end
  end

  defp get_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp stringify_lookup_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_keys(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_binary(key) do
    if key in Enum.map(Profile.known_keys(), &Atom.to_string/1) do
      String.to_existing_atom(key)
    else
      key
    end
  end

  defp normalize_key(key), do: key

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp truthy?(value), do: value == true

  defp provider_atom(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> provider
  end
end
