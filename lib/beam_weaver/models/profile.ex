defmodule BeamWeaver.Models.Profile do
  @moduledoc """
  Model capability metadata.
  """

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :provider,
    :id,
    :name,
    :status,
    :release_date,
    :last_updated,
    max_input_tokens: nil,
    max_output_tokens: nil,
    text_inputs: true,
    image_inputs: false,
    image_url_inputs: false,
    pdf_inputs: false,
    audio_inputs: false,
    video_inputs: false,
    text_outputs: true,
    image_outputs: false,
    audio_outputs: false,
    video_outputs: false,
    reasoning_output: false,
    tool_calling: false,
    tool_choice: false,
    parallel_tool_calls: false,
    structured_output: false,
    streaming: false,
    responses_api: false,
    chat_completions_api: false,
    usage_metadata: false,
    usage_metadata_details: %{},
    tokenizer: nil,
    supported_params: :unknown,
    supported_params_by_api: %{},
    temperature: true,
    image_tool_message: false,
    pdf_tool_message: false,
    open_weights: false,
    attachment: false,
    extra: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Builds a profile from plain data while preserving unknown future keys in
  `extra`.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{})

  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%__MODULE__{} = profile), do: profile

  def new(%{} = attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
    known = known_keys()

    {profile_attrs, extra_attrs} =
      Enum.split_with(attrs, fn {key, _value} -> key in known end)

    extra =
      attrs
      |> Map.get(:extra, %{})
      |> normalize_extra()
      |> Map.merge(Map.new(extra_attrs))
      |> Map.delete(:extra)

    __MODULE__
    |> struct(Map.new(profile_attrs))
    |> Map.put(:extra, extra)
  end

  @doc """
  Checks whether a profile advertises a capability.
  """
  def supports?(%__MODULE__{} = profile, capability) when is_atom(capability) do
    Map.get(profile, capability) == true
  end

  def supports?(_profile, _capability), do: false

  @doc """
  Checks whether a standard invocation parameter is supported.

  Unknown profiles remain permissive and report support for any param.
  """
  def supports_param?(%__MODULE__{supported_params: :unknown}, _param), do: true

  def supports_param?(%__MODULE__{supported_params: params}, param) when is_list(params),
    do: param in params

  def supports_param?(_profile, _param), do: false

  @doc """
  Checks whether a standard invocation parameter is supported for an API path.
  """
  def supports_param?(%__MODULE__{} = profile, api, param) when is_atom(api) do
    params =
      profile.supported_params_by_api
      |> normalize_api_params()
      |> Map.get(api)

    case params do
      nil -> supports_param?(profile, param)
      :unknown -> true
      values when is_list(values) -> param in values
      _other -> false
    end
  end

  def supports_param?(profile, _api, param), do: supports_param?(profile, param)

  @doc """
  Checks whether a profile supports an OpenAI API path.
  """
  def api_supported?(%__MODULE__{} = profile, :responses), do: profile.responses_api == true

  def api_supported?(%__MODULE__{} = profile, :chat_completions),
    do: profile.chat_completions_api == true

  def api_supported?(_profile, _api), do: false

  @doc """
  Returns the tokenizer family advertised by a profile.
  """
  def tokenizer_family(%__MODULE__{tokenizer: tokenizer}), do: tokenizer
  def tokenizer_family(_profile), do: nil

  @doc false
  def known_keys do
    %__MODULE__{}
    |> Map.from_struct()
    |> Map.keys()
  end

  defp normalize_key(key) when is_binary(key) do
    known = Enum.map(known_keys(), &Atom.to_string/1)

    if key in known do
      String.to_existing_atom(key)
    else
      key
    end
  end

  defp normalize_key(key), do: key

  defp normalize_extra(extra) when is_list(extra), do: Map.new(extra)
  defp normalize_extra(extra) when is_map(extra), do: extra
  defp normalize_extra(_extra), do: %{}

  defp normalize_api_params(params) when is_map(params) do
    Map.new(params, fn
      {key, value} when is_binary(key) ->
        {normalize_api_key(key), value}

      {key, value} ->
        {key, value}
    end)
  end

  defp normalize_api_params(_params), do: %{}

  defp normalize_api_key("responses"), do: :responses
  defp normalize_api_key("chat_completions"), do: :chat_completions
  defp normalize_api_key(key), do: key
end
