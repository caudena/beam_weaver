defmodule BeamWeaver.Moonshot.ResponsesModel do
  @moduledoc """
  Kimi's stateless Responses API for K3 series models. Send the full message
  history for each turn, including the model's reasoning and tool replies.
  See [Moonshot](providers/moonshot.md#responses).
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Models.ProfileRegistry.Moonshot, as: Profiles
  alias BeamWeaver.Moonshot.{Client, Messages, Tools}
  alias BeamWeaver.OpenAI.ChatModel.{RequestBuilder, TokenCounter}
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.StructuredOutput
  alias BeamWeaver.Result

  @default_model Profiles.default_model()
  @default_endpoint "https://api.moonshot.ai/v1/responses"

  @request_fields ~w(model input instructions stream max_output_tokens reasoning text tools tool_choice include
                     prompt_cache_key prompt_cache_options safety_identifier)
  @passthrough_input_types ~w(function_call custom_tool_call custom_tool_call_output web_search_call)
  @includes ~w(web_search_call.results web_search_call.action.sources)

  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            default_headers: [],
            extra_body: %{},
            max_tokens: nil,
            max_completion_tokens: nil,
            max_output_tokens: nil,
            reasoning: nil,
            reasoning_effort: nil,
            prompt_cache_key: nil,
            prompt_cache_options: nil,
            safety_identifier: nil,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            streaming: false,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel, stream_source: :moonshot_responses

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = opts |> ChatOptions.keyword_options() |> Compat.expand_base_url(endpoint: "responses")
    model = Keyword.get(opts, :model, @default_model)

    struct!(
      __MODULE__,
      opts |> Keyword.put(:model, model) |> Keyword.put(:profile, ChatOptions.profile_option(opts, :moonshot, model))
    )
  end

  def count_tokens(%__MODULE__{} = model, input, opts \\ []), do: TokenCounter.count(model, input, opts)

  @impl true
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    id = Keyword.get(opts, :model, model.model)

    with :ok <- validate_request(id, opts),
         {:ok, body} <- RequestBuilder.request_body(model, messages, opts),
         :ok <- validate_fields(body),
         :ok <- validate_reasoning(body["reasoning"]),
         :ok <- Tools.validate_responses_tools(body["tools"]),
         :ok <- validate_output(body["text"]),
         {:ok, input} <- Result.traverse(body["input"], &input_item/1) do
      {:ok, Map.put(body, "input", input)}
    end
  end

  defp validate_request(model, opts) do
    cond do
      not Profiles.k3_model?(model) ->
        {:error,
         Error.new(:unsupported_model, "Kimi Responses requires a K3 series model", %{
           provider: :moonshot,
           model: model,
           supported: Profiles.k3_models()
         })}

      Keyword.get(opts, :use_previous_response_id) == true ->
        invalid("Kimi Responses requires the full message history", :use_previous_response_id)

      true ->
        :ok
    end
  end

  defp validate_fields(body) do
    unsupported = Map.keys(body) -- @request_fields

    cond do
      unsupported != [] ->
        {:error,
         Error.new(:unsupported_model_param, "Kimi Responses does not support these fields", %{params: unsupported})}

      body["tool_choice"] not in [nil, "auto"] ->
        invalid("Kimi Responses tool_choice must be auto", :tool_choice)

      not valid_includes?(body["include"]) ->
        invalid("Kimi Responses include only accepts hosted web-search fields", :include)

      true ->
        :ok
    end
  end

  defp valid_includes?(nil), do: true
  defp valid_includes?(values) when is_list(values), do: Enum.all?(values, &(&1 in @includes))
  defp valid_includes?(_values), do: false

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%{"effort" => effort} = value) when map_size(value) == 1 and effort in ["low", "high", "max"],
    do: :ok

  defp validate_reasoning(_reasoning),
    do: invalid("Kimi Responses reasoning takes a low, high, or max effort", :reasoning)

  defp validate_output(nil), do: :ok

  defp validate_output(%{"format" => %{"type" => "json_schema", "schema" => %{}}} = text) when map_size(text) == 1,
    do: :ok

  defp validate_output(_text), do: invalid("Kimi Responses text configuration takes a JSON schema", :text)

  defp input_item(%{"type" => "message", "role" => role, "content" => content} = item)
       when role in ["user", "assistant", "system", "developer"] do
    with {:ok, content} <- content_parts(content) do
      role = if role == "system", do: "developer", else: role

      {:ok,
       item
       |> Map.take(["type", "status"])
       |> Map.merge(%{"role" => role, "content" => content})}
    end
  end

  defp input_item(%{"type" => "additional_tools", "tools" => tools} = item) do
    with :ok <- Tools.validate_responses_tools(tools), do: {:ok, item}
  end

  defp input_item(%{"type" => "function_call_output", "output" => output} = item) do
    with {:ok, output} <- content_parts(output),
         do: {:ok, item |> Map.drop(["name", "namespace"]) |> Map.put("output", output)}
  end

  defp input_item(%{"type" => "reasoning"} = item), do: {:ok, Map.delete(item, "encrypted_content")}

  defp input_item(%{"type" => type} = item) when type in @passthrough_input_types, do: {:ok, item}
  defp input_item(_item), do: invalid("Kimi Responses does not support this input item", :input)

  defp content_parts(text) when is_binary(text), do: {:ok, text}
  defp content_parts(parts) when is_list(parts), do: Result.traverse(parts, &content_part/1)
  defp content_parts(_content), do: invalid("Kimi Responses requires text or image content", :input)

  defp content_part(%{"type" => type, "text" => text}) when type in ["input_text", "output_text"] and is_binary(text),
    do: {:ok, %{"type" => type, "text" => text}}

  defp content_part(%{"type" => "input_image", "image_url" => "data:image/" <> _} = image),
    do: {:ok, Map.take(image, ["type", "image_url", "detail"])}

  defp content_part(_part), do: invalid("Kimi Responses requires text or inline image data URLs", :input)

  defp invalid(message, param) do
    {:error, Error.new(:unsupported_model_param, message, %{provider: :moonshot, params: [param]})}
  end

  defp client(model) do
    %Client{
      endpoint: model.endpoint,
      responses_endpoint: model.endpoint,
      api_key: model.api_key,
      default_headers: model.default_headers,
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  @impl true
  def stream_metadata(model, body, opts),
    do: model |> InvocationMetadata.provider(:moonshot, body, opts, :responses) |> InvocationMetadata.to_metadata_map()

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.responses(client(model), body, opts)
  def send_request(:stream, model, body, opts), do: Client.responses_stream(client(model), body, opts)
  def send_request(:stream_response, model, body, opts), do: Client.responses_stream_response(client(model), body, opts)

  def send_request(:stream_events, model, body, opts),
    do: Client.responses_stream_typed_events(client(model), body, opts)

  @impl true
  def decode_response(response, _opts), do: Messages.responses_to_message(response)

  @impl true
  def parse_response(_model, message, opts),
    do: StructuredOutput.maybe_parse(message, opts, provider_name: "Kimi Responses")

  @impl true
  def forced_tool_choice?(_model, _opts), do: false
end
