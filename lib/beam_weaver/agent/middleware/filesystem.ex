defmodule BeamWeaver.Agent.Middleware.Filesystem do
  @moduledoc "Middleware that contributes DeepAgents filesystem tools."

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.Middleware.Offload
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools

  import BeamWeaver.Agent.Middleware.Helpers,
    only: [append_prompt: 2, artifact_prefix: 2, maybe_put_files_update: 3]

  @chars_per_token 4
  @tool_token_limit_before_evict 20_000
  @human_message_token_limit_before_evict 50_000
  @tools_excluded_from_evict ~w(ls glob grep read_file edit_file write_file)

  @filesystem_system_prompt """
  ## Following Conventions

  - Read files before editing - understand existing content before making changes
  - Mimic existing style, naming conventions, and patterns

  ## Filesystem Tools `ls`, `read_file`, `write_file`, `edit_file`, `glob`, `grep`

  You have access to a filesystem which you can interact with using these tools.
  All file paths must start with a /. Follow the tool docs for the available tools, and use pagination (offset/limit) when reading large files.

  - ls: list files in a directory (requires absolute path)
  - read_file: read a file from the filesystem
  - write_file: write to a file in the filesystem
  - edit_file: edit a file in the filesystem
  - glob: find files matching a pattern (e.g., "**/*.ex")
  - grep: search for text within files

  ## Large Tool Results

  When a tool result is too large, it may be offloaded into the filesystem instead of being returned inline. In those cases, use `read_file` to inspect the saved result in chunks, or use `grep` within `%{large_tool_results_prefix}/` if you need to search across offloaded tool results and do not know the exact file path. Offloaded tool results are stored under `%{large_tool_results_prefix}/<tool_call_id>`.
  """

  @execution_system_prompt """
  ## Execute Tool `execute`

  You have access to an `execute` tool for running shell commands in a sandboxed environment.
  Use this tool to run commands, scripts, tests, builds, and other shell operations.

  - execute: run a shell command in the sandbox (returns output and exit code)
  """

  @too_large_tool_msg """
  Tool result too large, the result of this tool call %{tool_call_id} was saved in the filesystem at this path: %{file_path}

  You can read the result from the filesystem by using the read_file tool, but make sure to only read part of the result at a time.

  You can do this by specifying an offset and limit in the read_file tool call. For example, to read the first 100 lines, you can use the read_file tool with offset=0 and limit=100.

  Here is a preview showing the head and tail of the result (lines of the form `... [N lines truncated] ...` indicate omitted lines in the middle of the content):

  %{content_sample}
  """

  @too_large_human_msg """
  Message content too large and was saved to the filesystem at: %{file_path}

  You can read the full content using the read_file tool with pagination (offset and limit parameters).

  Here is a preview showing the head and tail of the content:

  %{content_sample}
  """

  defstruct backend: State.new(),
            permissions: [],
            state_key: :files,
            system_prompt: nil,
            tool_token_limit_before_evict: @tool_token_limit_before_evict,
            human_message_token_limit_before_evict: @human_message_token_limit_before_evict,
            large_tool_results_prefix: "/large_tool_results",
            conversation_history_prefix: "/conversation_history"

  def new(opts \\ []) do
    backend = Keyword.get(opts, :backend, State.new())

    %__MODULE__{
      backend: backend,
      permissions: Keyword.get(opts, :permissions, []),
      state_key: Keyword.get(opts, :state_key, :files),
      system_prompt: Keyword.get(opts, :system_prompt),
      tool_token_limit_before_evict: Keyword.get(opts, :tool_token_limit_before_evict, @tool_token_limit_before_evict),
      human_message_token_limit_before_evict:
        Keyword.get(
          opts,
          :human_message_token_limit_before_evict,
          @human_message_token_limit_before_evict
        ),
      large_tool_results_prefix:
        Keyword.get(
          opts,
          :large_tool_results_prefix,
          artifact_prefix(backend, "large_tool_results")
        ),
      conversation_history_prefix:
        Keyword.get(
          opts,
          :conversation_history_prefix,
          artifact_prefix(backend, "conversation_history")
        )
    }
  end

  @impl true
  def name(_middleware), do: :deepagents_filesystem

  @impl true
  def state_schema(%__MODULE__{state_key: state_key}) do
    %{state_key => Graph.channel({BinaryOperatorAggregate, &Map.merge/2}, initial: %{})}
  end

  @impl true
  def tools(%__MODULE__{} = middleware) do
    FilesystemTools.tools(middleware.backend,
      permissions: middleware.permissions,
      state_key: middleware.state_key
    )
  end

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    {messages, command} = evict_and_truncate_human_messages(middleware, request)

    request =
      ModelRequest.override(request,
        messages: messages,
        system_message: append_prompt(request.system_message, system_prompt(middleware))
      )

    request
    |> handler.()
    |> maybe_attach_command(command)
  end

  def wrap_tool_call(%__MODULE__{} = middleware, %ToolCallRequest{} = request, handler) do
    result = handler.(request)

    if evict_tool_result?(middleware, request) do
      intercept_large_tool_result(middleware, result, request)
    else
      result
    end
  end

  defp evict_tool_result?(%__MODULE__{tool_token_limit_before_evict: nil}, _request), do: false

  defp evict_tool_result?(%__MODULE__{}, %ToolCallRequest{} = request),
    do: tool_name(request) not in @tools_excluded_from_evict

  defp intercept_large_tool_result(
         %__MODULE__{} = middleware,
         %Message{role: :tool} = message,
         request
       ) do
    case process_large_message(middleware, message, request) do
      {:ok, %Message{} = message, nil} ->
        message

      {:ok, %Message{} = message, files_update} ->
        %Command{update: %{middleware.state_key => files_update, messages: [message]}}

      :unchanged ->
        message
    end
  end

  defp intercept_large_tool_result(
         %__MODULE__{} = middleware,
         %Command{update: update} = command,
         request
       )
       when is_map(update) do
    {messages_key, messages} = command_messages(update)

    if is_nil(messages_key) or not is_list(messages) do
      command
    else
      {processed, files_update} =
        Enum.reduce(messages, {[], nil}, fn
          %Message{role: :tool} = message, {messages, files_acc} ->
            case process_large_message(middleware, message, request, files_acc) do
              {:ok, %Message{} = message, files_update} ->
                {[message | messages], Offload.merge_files_update(files_acc, files_update)}

              :unchanged ->
                {[message | messages], files_acc}
            end

          message, {messages, files_acc} ->
            {[message | messages], files_acc}
        end)

      update =
        update
        |> Map.put(messages_key, Enum.reverse(processed))
        |> maybe_put_files_update(middleware.state_key, files_update)

      %{command | update: update}
    end
  end

  defp intercept_large_tool_result(_middleware, result, _request), do: result

  defp process_large_message(middleware, message, request, state_files_override \\ nil) do
    content = Message.text(message)
    threshold = @chars_per_token * middleware.tool_token_limit_before_evict

    if String.length(content) <= threshold do
      :unchanged
    else
      offload_tool_message(middleware, message, content, request, state_files_override)
    end
  end

  defp offload_tool_message(middleware, message, content, request, state_files_override) do
    tool_call_id = message.tool_call_id || tool_call_id(request) || "unknown"

    file_path =
      middleware.large_tool_results_prefix <> "/" <> Offload.sanitize_tool_call_id(tool_call_id)

    opts =
      request
      |> backend_opts()
      |> Offload.maybe_put_state_files(middleware.state_key, state_files_override)

    case Filesystem.write(middleware.backend, file_path, content, opts) do
      %Filesystem.WriteResult{error: nil, files_update: files_update} ->
        replacement =
          Offload.format_notice(@too_large_tool_msg,
            tool_call_id: tool_call_id,
            file_path: file_path,
            content_sample: Offload.content_preview(content)
          )

        {:ok, %{message | content: Offload.evicted_content(message, replacement)}, files_update}

      _error ->
        :unchanged
    end
  end

  defp evict_and_truncate_human_messages(
         %__MODULE__{human_message_token_limit_before_evict: nil},
         %ModelRequest{} = request
       ),
       do: {request.messages || [], nil}

  defp evict_and_truncate_human_messages(%__MODULE__{} = middleware, %ModelRequest{} = request) do
    messages = request.messages || []
    threshold = @chars_per_token * middleware.human_message_token_limit_before_evict
    last_index = last_human_message_index(messages)

    newly_evicted =
      if is_integer(last_index) do
        message = Enum.at(messages, last_index)

        user_message?(message) and evicted_to(message) in [nil, ""] and
          String.length(Message.text(message)) > threshold
      else
        false
      end

    cond do
      newly_evicted ->
        evict_latest_human_message(middleware, request, messages, last_index)

      Enum.any?(messages, &(user_message?(&1) and evicted_to(&1) not in [nil, ""])) ->
        {Enum.map(messages, &truncate_evicted_human_message/1), nil}

      true ->
        {messages, nil}
    end
  end

  defp evict_latest_human_message(middleware, request, messages, index) do
    message = Enum.at(messages, index)
    file_path = middleware.conversation_history_prefix <> "/" <> ID.uuidv7() <> ".md"
    content = Message.text(message)

    case Filesystem.write(
           middleware.backend,
           file_path,
           content,
           backend_opts_from_model_request(request)
         ) do
      %Filesystem.WriteResult{error: nil, files_update: files_update} ->
        tagged = tag_evicted_human_message(message, file_path)
        tagged_messages = List.replace_at(messages, index, tagged)
        model_messages = Enum.map(tagged_messages, &truncate_evicted_human_message/1)

        update =
          %{messages: Overwrite.new(tagged_messages)}
          |> maybe_put_files_update(middleware.state_key, files_update)

        {model_messages, %Command{update: update}}

      _error ->
        {messages, nil}
    end
  end

  defp truncate_evicted_human_message(%Message{role: :user} = message) do
    case evicted_to(message) do
      path when is_binary(path) and path != "" ->
        replacement =
          Offload.format_notice(@too_large_human_msg,
            file_path: path,
            content_sample: Offload.content_preview(Message.text(message))
          )

        %{message | content: Offload.evicted_content(message, replacement)}

      _missing ->
        message
    end
  end

  defp truncate_evicted_human_message(message), do: message

  defp tag_evicted_human_message(%Message{} = message, file_path) do
    metadata =
      message.metadata
      |> Map.put(:lc_evicted_to, file_path)

    %{message | id: message.id || ID.uuidv7(), metadata: metadata}
  end

  defp last_human_message_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: :user}, index} -> index
      _other -> nil
    end)
  end

  defp user_message?(%Message{role: :user}), do: true
  defp user_message?(_message), do: false

  defp evicted_to(%Message{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, :lc_evicted_to)

  defp evicted_to(_message), do: nil

  defp maybe_attach_command(result, nil), do: result

  defp maybe_attach_command({:ok, %ModelResponse{} = response}, %Command{} = command),
    do: %ExtendedModelResponse{model_response: response, command: command}

  defp maybe_attach_command(%ModelResponse{} = response, %Command{} = command),
    do: %ExtendedModelResponse{model_response: response, command: command}

  defp maybe_attach_command({:ok, %ExtendedModelResponse{} = response}, %Command{} = command),
    do: %{response | command: merge_commands(response.command, command)}

  defp maybe_attach_command(%ExtendedModelResponse{} = response, %Command{} = command),
    do: %{response | command: merge_commands(response.command, command)}

  defp maybe_attach_command(%Message{} = message, %Command{} = command),
    do: %ExtendedModelResponse{
      model_response: %ModelResponse{messages: [message]},
      command: command
    }

  defp maybe_attach_command(result, _command), do: result

  defp merge_commands(nil, command), do: command

  defp merge_commands(%Command{} = left, %Command{} = right) do
    %Command{
      update: Map.merge(left.update || %{}, right.update || %{}),
      goto: left.goto || right.goto,
      resume: left.resume || right.resume,
      graph: left.graph || right.graph
    }
  end

  defp system_prompt(%__MODULE__{system_prompt: prompt}) when is_binary(prompt), do: prompt

  defp system_prompt(%__MODULE__{} = middleware) do
    prompt =
      @filesystem_system_prompt
      |> String.trim()
      |> String.replace("%{large_tool_results_prefix}", middleware.large_tool_results_prefix)

    if Executable.executable?(middleware.backend),
      do: prompt <> "\n\n" <> String.trim(@execution_system_prompt),
      else: prompt
  end

  defp command_messages(update) when is_map(update) do
    cond do
      Map.has_key?(update, :messages) -> {:messages, Map.fetch!(update, :messages)}
      Map.has_key?(update, "messages") -> {"messages", Map.fetch!(update, "messages")}
      true -> {nil, nil}
    end
  end

  defp backend_opts(%ToolCallRequest{} = request) do
    [
      state: request.state || %{},
      store: runtime_value(request.runtime, :store),
      runtime: request.runtime
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp backend_opts_from_model_request(%ModelRequest{} = request) do
    [
      state: request.state || %{},
      store: runtime_value(request.runtime, :store),
      runtime: request.runtime
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp runtime_value(%{store: store}, :store), do: store
  defp runtime_value(_runtime, _key), do: nil

  defp tool_name(%ToolCallRequest{tool_call: %{name: name}}), do: to_string(name)
  defp tool_name(%ToolCallRequest{tool_call: %{"name" => name}}), do: to_string(name)
  defp tool_name(_request), do: ""

  defp tool_call_id(%ToolCallRequest{tool_call: %{id: id}}), do: id
  defp tool_call_id(%ToolCallRequest{tool_call: %{"id" => id}}), do: id
  defp tool_call_id(_request), do: nil
end
