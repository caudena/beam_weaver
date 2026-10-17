defmodule BeamWeaver.Core.Message do
  @moduledoc """
  A chat message: what a user, the model, a tool or the system said.

  ```elixir
  alias BeamWeaver.Core.Message

  messages = [
    Message.system("You are Acme's support agent."),
    Message.user("Where is my order A-1001?"),
    Message.assistant("Order A-1001 shipped on Monday.")
  ]

  messages |> List.last() |> Message.text()
  #=> "Order A-1001 shipped on Monday."
  ```

  `role` is `:system`, `:user`, `:assistant` or `:tool`. `content` is a string
  or a list of content blocks (text, images, files); `text/1` joins the text.
  An assistant message lists the tools the model wants to call in
  `tool_calls`, and each `:tool` message answers one of them through
  `tool_call_id`. Replies from a model carry token counts in `usage_metadata`.
  See [Messages](messages.md).
  """

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ToolCallParser
  alias BeamWeaver.MapShape

  @roles [:system, :user, :assistant, :tool]

  @enforce_keys [:role, :content]
  defstruct [
    :role,
    :content,
    :id,
    :name,
    metadata: %{},
    response_metadata: %{},
    usage_metadata: nil,
    status: nil,
    artifacts: [],
    server_tool_calls: [],
    server_tool_results: [],
    tool_calls: [],
    tool_call_id: nil
  ]

  @type role :: :system | :user | :assistant | :tool
  @type content :: String.t() | [map()]

  @type t :: %__MODULE__{
          role: role(),
          content: content(),
          id: String.t() | nil,
          name: String.t() | nil,
          metadata: map(),
          response_metadata: map(),
          usage_metadata: map() | nil,
          status: atom() | String.t() | nil,
          artifacts: [term()],
          server_tool_calls: [term()],
          server_tool_results: [term()],
          tool_calls: [map()],
          tool_call_id: String.t() | nil
        }

  @doc """
  Builds a message with validation.
  """
  @spec new(role(), content(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(role, content, opts \\ []) do
    content = normalize_content(role, content)

    with :ok <- validate_role(role),
         :ok <- validate_content(content) do
      {:ok,
       %__MODULE__{
         role: role,
         content: content,
         id: normalize_id(Keyword.get(opts, :id)),
         name: Keyword.get(opts, :name),
         metadata: Keyword.get(opts, :metadata, %{}),
         response_metadata: Keyword.get(opts, :response_metadata, %{}),
         usage_metadata: Keyword.get(opts, :usage_metadata),
         status: Keyword.get(opts, :status),
         artifacts: Keyword.get(opts, :artifacts, []),
         server_tool_calls: Keyword.get(opts, :server_tool_calls, []),
         server_tool_results: Keyword.get(opts, :server_tool_results, []),
         tool_calls: Keyword.get(opts, :tool_calls, []),
         tool_call_id: normalize_tool_call_id(role, Keyword.get(opts, :tool_call_id))
       }}
    end
  end

  @doc """
  Builds a message and raises on invalid input.
  """
  @spec new!(role(), content(), keyword()) :: t()
  def new!(role, content, opts \\ []) do
    case new(role, content, opts) do
      {:ok, message} -> message
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @doc """
  Builds a system message.
  """
  @spec system(content(), keyword()) :: t()
  def system(content, opts \\ []), do: new!(:system, content, opts)

  @doc """
  Builds a user message.
  """
  @spec user(content(), keyword()) :: t()
  def user(content, opts \\ []), do: new!(:user, content, opts)

  @doc """
  Builds an assistant message.
  """
  @spec assistant(content(), keyword()) :: t()
  def assistant(content, opts \\ []), do: new!(:assistant, content, opts)

  @doc """
  Builds a tool message.
  """
  @spec tool(content(), keyword()) :: t()
  def tool(content, opts \\ []), do: new!(:tool, content, opts)

  @doc """
  Builds a message from a message, a string (a user message), a
  `{role, content}` tuple, or a message map with `role` and `content` keys.

  Maps may use atom or string keys and may carry OpenAI-style `tool_calls` and
  `refusal` fields. A map field of the wrong shape, such as a `metadata` that
  isn't a map, is an `:invalid_message` error, as in `validate/1`. The
  `"developer"` role becomes a system message tagged with
  `metadata.openai_role: :developer`.
  """
  @spec from(term()) :: {:ok, t()} | {:error, Error.t()}
  def from(%__MODULE__{} = message), do: {:ok, message}
  def from(content) when is_binary(content), do: {:ok, user(content)}

  def from({role, content}) do
    {role, opts} = input_role(role)
    new(role, content, opts)
  end

  def from(map) when is_map(map) and not is_struct(map) do
    map = Map.new(map, fn {key, value} -> {input_key(key), value} end)

    if Map.has_key?(map, "content") do
      from_map(map)
    else
      {:error, Error.new(:invalid_message, "message maps must include role and content", %{map: inspect(map)})}
    end
  end

  def from(value),
    do: {:error, Error.new(:invalid_message, "value cannot be converted to a message", %{value: inspect(value)})}

  # A field of the wrong shape, such as a string `metadata`, is an error, as in
  # `validate/1`.
  defp from_map(map) do
    {role, role_opts} = input_role(map["role"])
    metadata = map["metadata"] || %{}

    with :ok <- validate_map_field(metadata, :metadata),
         {:ok, tool_calls, invalid_tool_calls} <- input_tool_calls(map["tool_calls"] || []),
         metadata =
           metadata
           |> MapShape.put_optional(:refusal, map["refusal"])
           |> MapShape.put_optional(:invalid_tool_calls, invalid_tool_calls),
         opts = Keyword.merge(map_opts(map, metadata, tool_calls), role_opts, &merge_role_opt/3),
         {:ok, message} <- new(role, map["content"] || "", opts),
         :ok <- validate(message) do
      {:ok, message}
    end
  end

  defp map_opts(map, metadata, tool_calls) do
    [
      id: map["id"],
      name: map["name"],
      metadata: metadata,
      response_metadata: map["response_metadata"] || %{},
      usage_metadata: map["usage_metadata"],
      status: map["status"],
      artifacts: List.wrap(map["artifacts"]),
      server_tool_calls: map["server_tool_calls"] || [],
      server_tool_results: map["server_tool_results"] || [],
      tool_calls: tool_calls,
      tool_call_id: map["tool_call_id"]
    ]
  end

  defp input_key(key) when is_atom(key), do: Atom.to_string(key)
  defp input_key(key), do: key

  defp input_role(role) when role in ["developer", :developer], do: {:system, [metadata: %{openai_role: :developer}]}
  defp input_role("system"), do: {:system, []}
  defp input_role("user"), do: {:user, []}
  defp input_role("assistant"), do: {:assistant, []}
  defp input_role("tool"), do: {:tool, []}
  defp input_role(role), do: {role, []}

  defp merge_role_opt(:metadata, left, right), do: Map.merge(left, right)
  defp merge_role_opt(_key, _left, right), do: right

  defp input_tool_calls(tool_calls) when is_list(tool_calls) do
    {valid, invalid} =
      tool_calls
      |> Enum.map(&ToolCallParser.normalize_openai_call(&1, :atom_keys))
      |> Enum.split_with(&match?({:ok, _call}, &1))

    {:ok, Enum.map(valid, &elem(&1, 1)), Enum.map(invalid, &elem(&1, 1))}
  end

  defp input_tool_calls(_tool_calls), do: {:error, Error.new(:invalid_tool_call, "tool calls must be a list")}

  @doc """
  Extracts text from string content and text content blocks.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) when is_binary(content), do: content

  def text(%__MODULE__{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      text when is_binary(text) -> [text]
      %ContentBlock.Text{text: text} when is_binary(text) -> [text]
      %ContentBlock.PlainText{text: text} when is_binary(text) -> [text]
      %{type: :text, text: text} when is_binary(text) -> [text]
      %{type: :plain_text, text: text} when is_binary(text) -> [text]
      %{content: text} when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("")
  end

  @doc """
  Returns normalized typed content blocks for message content.
  """
  @spec content_blocks(t()) :: {:ok, [term()]} | {:error, Error.t()}
  def content_blocks(%__MODULE__{} = message) do
    with {:ok, blocks} <- normalize_message_content_blocks(message.content) do
      {:ok, message_extra_blocks(message) ++ append_missing_tool_calls(blocks, message)}
    end
  end

  defp normalize_message_content_blocks(""), do: ContentBlock.normalize_many([])

  defp normalize_message_content_blocks(content) when is_binary(content),
    do: ContentBlock.normalize_many([content])

  defp normalize_message_content_blocks(content) when is_list(content),
    do: ContentBlock.normalize_many(content)

  @doc """
  Validates that a term is a BeamWeaver message.
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = message) do
    with :ok <- validate_role(message.role),
         :ok <- validate_content(message.content),
         :ok <- validate_map_field(message.metadata, :metadata),
         :ok <- validate_map_field(message.response_metadata, :response_metadata),
         :ok <- validate_optional_map(message.usage_metadata, :usage_metadata),
         :ok <- validate_list_field(message.artifacts, :artifacts),
         :ok <- validate_list_field(message.server_tool_calls, :server_tool_calls),
         :ok <- validate_list_field(message.server_tool_results, :server_tool_results) do
      validate_tool_calls(message.tool_calls)
    end
  end

  def validate(_term), do: {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}

  defp validate_role(role) when role in @roles, do: :ok

  defp validate_role(role) do
    {:error, Error.new(:invalid_role, "unsupported message role", %{role: role, supported_roles: @roles})}
  end

  defp normalize_content(:tool, content) when is_tuple(content),
    do: normalize_content(:tool, Tuple.to_list(content))

  defp normalize_content(:tool, content) when is_list(content) do
    content
    |> Enum.map(fn
      item when is_binary(item) or is_map(item) -> item
      item -> stringify_tool_content(item)
    end)
    |> normalize_content_list()
  end

  defp normalize_content(:tool, content) when is_binary(content), do: content
  defp normalize_content(:tool, content), do: stringify_tool_content(content)
  defp normalize_content(_role, content) when is_list(content), do: normalize_content_list(content)
  defp normalize_content(_role, content), do: content

  defp normalize_content_list(content) do
    case ContentBlock.normalize_many(content) do
      {:ok, blocks} -> blocks
      {:error, _error} -> content
    end
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id) when is_integer(id) or is_float(id), do: to_string(id)
  defp normalize_id(id), do: id

  defp normalize_tool_call_id(:tool, id), do: normalize_id(id)
  defp normalize_tool_call_id(_role, id), do: id

  defp stringify_tool_content(content) when is_map(content) or is_list(content) do
    case BeamWeaver.JSON.encode(content) do
      {:ok, json} -> json
      {:error, _error} -> inspect(content)
    end
  end

  defp stringify_tool_content(content),
    do: if(String.Chars.impl_for(content), do: to_string(content), else: inspect(content))

  defp message_extra_blocks(%__MODULE__{role: :assistant, metadata: metadata}) do
    case metadata_value(metadata, :reasoning_content) do
      reasoning when is_binary(reasoning) and reasoning != "" ->
        [ContentBlock.reasoning(reasoning)]

      _other ->
        []
    end
  end

  defp message_extra_blocks(_message), do: []

  defp append_missing_tool_calls(blocks, %__MODULE__{role: :assistant, tool_calls: calls})
       when is_list(calls) and calls != [] do
    existing_ids =
      blocks
      |> Enum.filter(&tool_call_block?/1)
      |> Enum.map(&block_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    missing =
      calls
      |> Enum.reject(fn call ->
        id = block_id(call)
        not is_nil(id) and MapSet.member?(existing_ids, id)
      end)
      |> Enum.map(&tool_call_block/1)

    blocks ++ missing
  end

  defp append_missing_tool_calls(blocks, _message), do: blocks

  defp tool_call_block?(block) when is_map(block) do
    Map.get(block, :type) == :tool_call
  end

  defp tool_call_block?(_block), do: false

  defp tool_call_block(call) when is_map(call) do
    %{
      type: :tool_call,
      id: Map.get(call, :id),
      provider_id: Map.get(call, :provider_id),
      call_id: Map.get(call, :call_id),
      name: Map.get(call, :name),
      thought_signature: Map.get(call, :thought_signature),
      args: Map.get(call, :args, %{})
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp block_id(block) when is_map(block), do: Map.get(block, :id)
  defp block_id(_block), do: nil

  defp metadata_value(map, key) when is_map(map), do: Map.get(map, key)

  defp metadata_value(_map, _key), do: nil

  defp validate_content(content) when is_binary(content), do: :ok
  defp validate_content(content) when is_list(content), do: :ok

  defp validate_content(content) do
    {:error,
     Error.new(:invalid_content, "message content must be a string or list of content blocks", %{
       content: content
     })}
  end

  defp validate_map_field(value, _field) when is_map(value), do: :ok

  defp validate_map_field(value, field) do
    {:error, Error.new(:invalid_message, "message #{field} must be a map", %{field: field, value: value})}
  end

  defp validate_optional_map(nil, _field), do: :ok
  defp validate_optional_map(value, field), do: validate_map_field(value, field)

  defp validate_list_field(value, _field) when is_list(value), do: :ok

  defp validate_list_field(value, field) do
    {:error, Error.new(:invalid_message, "message #{field} must be a list", %{field: field, value: value})}
  end

  defp validate_tool_calls(calls) when is_list(calls) do
    if Enum.all?(calls, &is_map/1) do
      :ok
    else
      {:error, Error.new(:invalid_tool_call, "tool calls must be maps")}
    end
  end

  defp validate_tool_calls(_calls),
    do: {:error, Error.new(:invalid_tool_call, "tool calls must be a list")}
end
