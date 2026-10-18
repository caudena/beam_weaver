defmodule BeamWeaver.Agent.Middleware.Filesystem do
  @moduledoc """
  Middleware that gives an agent the filesystem tools from
  `BeamWeaver.Tools.Filesystem` and a system prompt describing them.

  It also writes oversized tool results and user messages to files and shows
  the model a short preview with the file path instead.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.Middleware.Offload
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Path, as: FsPath
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.MapAccess
  alias BeamWeaver.MapShape
  alias BeamWeaver.Tools.Filesystem, as: FilesystemTools

  import BeamWeaver.Agent.Middleware.Helpers,
    only: [append_prompt: 2, artifact_prefix: 2, last_role_index: 2, runtime_store: 1, tool_call_id: 1]

  @chars_per_token 4
  @tool_token_limit_before_evict 20_000
  @human_message_token_limit_before_evict 50_000
  @tools_excluded_from_evict ~w(ls glob grep read_file edit_file write_file)
  @file_change_tools ~w(write_file edit_file)

  @conventions_prompt """
  ## Following Conventions

  - Read files before editing - understand existing content before making changes
  - Mimic existing style, naming conventions, and patterns
  """

  @file_tools [
    {"ls", "list files in a directory (requires absolute path)"},
    {"read_file", "read a file from the filesystem"},
    {"write_file", "create a file, or replace one, in the filesystem"},
    {"edit_file", "edit a file in the filesystem"},
    {"glob", ~s|find files matching a pattern (e.g., "**/*.ex")|},
    {"grep", "search files for literal text, not a regex"}
  ]

  @file_tools_prompt """
  ## Filesystem Tools %{tool_names}

  You have access to a filesystem which you can interact with using these tools.
  All file paths must start with a /. Follow the tool docs for the available tools, and use pagination (offset/limit) when reading large files.

  %{tool_lines}
  """

  @large_tool_results_prompt """
  ## Large Tool Results

  When a tool result is too large, it may be offloaded into the filesystem instead of being returned inline. In those cases, %{how_to_read}. Offloaded tool results are stored under `%{large_tool_results_prefix}/<tool_call_id>`.
  """

  @offloaded_result_readers [
    {"read_file", "use `read_file` to inspect the saved result in chunks"},
    {"grep",
     "use `grep` within `%{large_tool_results_prefix}/` if you need to search across offloaded tool results and do not know the exact file path"}
  ]

  @execution_system_prompt """
  ## Execute Tool `execute`

  You have access to an `execute` tool for running shell commands in a sandboxed environment.
  Use this tool to run commands, scripts, tests, builds, and other shell operations.

  - execute: run a shell command in the sandbox. It returns the command's output followed by a line with its exit code, such as `[Command failed with exit code 1]`.
  - A command that runs longer than its `timeout` (in seconds, at most 3600) is stopped and returns an error instead; pass a larger `timeout` for long builds or tests.
  """

  @too_large_human_msg """
  Message content too large and was saved to the filesystem at: %{file_path}

  You can read the full content using the read_file tool with pagination (offset and limit parameters).

  Here is a preview showing the head and tail of the content%{preview_notes}:

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

  @impl true
  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    {messages, command} = evict_and_truncate_human_messages(middleware, request)

    request =
      request
      |> ModelRequest.override(
        messages: messages,
        system_message: append_prompt(request.system_message, system_prompt(middleware, request))
      )
      |> with_grep_description()

    request
    |> handler.()
    |> maybe_attach_command(command)
  end

  # grep's description points to `execute` for a real regex only while the
  # call offers `execute`. A description set with `tool_descriptions` stays.
  defp with_grep_description(%ModelRequest{tools: tools} = request) when is_list(tools) do
    execute? = "execute" in Helpers.tool_names(tools)
    described = Enum.map(tools, &describe_grep(&1, execute?))

    if described == tools, do: request, else: ModelRequest.override(request, tools: described)
  end

  defp with_grep_description(request), do: request

  defp describe_grep(%Tool{name: "grep", description: description} = tool, execute?) do
    if description in [FilesystemTools.grep_description(true), FilesystemTools.grep_description(false)],
      do: %{tool | description: FilesystemTools.grep_description(execute?)},
      else: tool
  end

  defp describe_grep(tool, _execute?), do: tool

  @impl true
  def wrap_tool_call(%__MODULE__{} = middleware, %ToolCallRequest{} = request, handler) do
    if same_file_changed_earlier?(request) do
      same_file_error(request)
    else
      result = handler.(request)

      if evict_tool_result?(middleware, request),
        do: intercept_large_tool_result(middleware, result, request),
        else: result
    end
  end

  # The calls of one model reply run at the same time, so two changes to one
  # file would race: only the first of them runs.
  defp same_file_changed_earlier?(%ToolCallRequest{tool_call: call, state: state}) do
    with true <- file_change?(call),
         %Message{tool_calls: [_ | _] = calls} <- last_assistant_message(state) do
      path = changed_path(call)

      calls
      |> Enum.take_while(&(Helpers.tool_call_id(&1) != Helpers.tool_call_id(call)))
      |> Enum.any?(&(file_change?(&1) and changed_path(&1) == path))
    else
      _other -> false
    end
  end

  defp file_change?(call),
    do: tool_name(call) in @file_change_tools and match?({:ok, _path}, changed_path(call))

  defp changed_path(call), do: call |> MapAccess.get(:args, %{}) |> MapAccess.get(:file_path) |> clean_path()

  defp clean_path(path) when is_binary(path), do: FsPath.clean_path(path)
  defp clean_path(_path), do: :error

  defp last_assistant_message(state) do
    state
    |> MapAccess.get(:messages, [])
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find(&match?(%Message{role: :assistant}, &1))
  end

  defp same_file_error(%ToolCallRequest{tool_call: call}) do
    Message.tool(
      "Error: parallel file changes to the same path are not allowed; change the file again in a later turn.",
      tool_call_id: Helpers.tool_call_id(call),
      name: tool_name(call),
      metadata: %{status: "error", error_type: :parallel_file_changes}
    )
  end

  defp evict_tool_result?(%__MODULE__{tool_token_limit_before_evict: nil}, _request), do: false

  defp evict_tool_result?(%__MODULE__{}, %ToolCallRequest{tool_call: call}),
    do: tool_name(call) not in @tools_excluded_from_evict

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
        |> MapShape.put_present(middleware.state_key, files_update)

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

  # A result without a call id gets a name of its own, so the next one doesn't
  # find the path taken and stay inline.
  defp offload_tool_message(middleware, message, content, request, state_files_override) do
    tool_call_id = message.tool_call_id || tool_call_id(request.tool_call) || ID.uuidv7()

    file_path =
      middleware.large_tool_results_prefix <> "/" <> Offload.sanitize_tool_call_id(tool_call_id)

    opts =
      request
      |> backend_opts()
      |> Offload.maybe_put_state_files(middleware.state_key, state_files_override)

    case Filesystem.write(middleware.backend, file_path, content, opts) do
      %Filesystem.WriteResult{error: nil, files_update: files_update} ->
        replacement = Offload.tool_result_notice(tool_call_id, file_path, content)
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
    last_index = last_role_index(messages, :user)

    newly_evicted =
      if is_integer(last_index) do
        message = Enum.at(messages, last_index)
        evicted_to(message) in [nil, ""] and String.length(Message.text(message)) > threshold
      else
        false
      end

    cond do
      newly_evicted ->
        evict_latest_human_message(middleware, request, messages, last_index)

      Enum.any?(messages, &(match?(%Message{role: :user}, &1) and evicted_to(&1) not in [nil, ""])) ->
        {Enum.map(messages, &truncate_evicted_human_message/1), nil}

      true ->
        {messages, nil}
    end
  end

  defp evict_latest_human_message(middleware, request, messages, index) do
    message = Enum.at(messages, index)
    file_path = middleware.conversation_history_prefix <> "/" <> ID.uuidv7() <> ".md"
    content = Message.text(message)

    case Filesystem.write(middleware.backend, file_path, content, backend_opts(request)) do
      %Filesystem.WriteResult{error: nil, files_update: files_update} ->
        tagged = tag_evicted_human_message(message, file_path)
        tagged_messages = List.replace_at(messages, index, tagged)
        model_messages = Enum.map(tagged_messages, &truncate_evicted_human_message/1)

        update =
          MapShape.put_present(%{messages: Overwrite.new(tagged_messages)}, middleware.state_key, files_update)

        {model_messages, %Command{update: update}}

      _error ->
        {messages, nil}
    end
  end

  defp truncate_evicted_human_message(%Message{role: :user} = message) do
    case evicted_to(message) do
      path when is_binary(path) and path != "" ->
        {sample, notes} = message |> Message.text() |> Offload.preview()

        replacement =
          Offload.format_notice(@too_large_human_msg, file_path: path, preview_notes: notes, content_sample: sample)

        %{message | content: Offload.evicted_content(message, replacement)}

      _missing ->
        message
    end
  end

  defp truncate_evicted_human_message(message), do: message

  defp tag_evicted_human_message(%Message{} = message, file_path),
    do: %{message | id: message.id || ID.uuidv7(), metadata: Map.put(message.metadata, :offloaded_to, file_path)}

  defp evicted_to(%Message{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, :offloaded_to)

  defp evicted_to(_message), do: nil

  defp maybe_attach_command(result, nil), do: result

  defp maybe_attach_command({:ok, response}, command)
       when is_struct(response, ModelResponse) or is_struct(response, ExtendedModelResponse),
       do: maybe_attach_command(response, command)

  defp maybe_attach_command(%ModelResponse{} = response, %Command{} = command),
    do: %ExtendedModelResponse{model_response: response, command: command}

  defp maybe_attach_command(%ExtendedModelResponse{} = response, %Command{} = command),
    do: %{response | command: merge_commands(response.command, command)}

  defp maybe_attach_command(%Message{} = message, command),
    do: maybe_attach_command(%ModelResponse{messages: [message]}, command)

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

  defp system_prompt(%__MODULE__{system_prompt: prompt}, _request) when is_binary(prompt), do: prompt

  # The sections describe the tools this call offers, which `exclude_tools`
  # and other tool filters may have narrowed.
  defp system_prompt(%__MODULE__{} = middleware, %ModelRequest{} = request) do
    offered = Helpers.tool_names(request.tools || [])
    file_tools = Enum.filter(@file_tools, fn {name, _description} -> name in offered end)
    execute? = "execute" in offered

    sections = [
      (file_tools != [] or execute?) && @conventions_prompt,
      file_tools_prompt(file_tools),
      large_tool_results_prompt(middleware, offered),
      execute? && @execution_system_prompt
    ]

    case Enum.filter(sections, &is_binary/1) do
      [] -> nil
      sections -> Enum.map_join(sections, "\n\n", &String.trim/1)
    end
  end

  defp file_tools_prompt([]), do: nil

  defp file_tools_prompt(file_tools) do
    Offload.format_notice(@file_tools_prompt,
      tool_names: Enum.map_join(file_tools, ", ", fn {name, _description} -> "`#{name}`" end),
      tool_lines: Enum.map_join(file_tools, "\n", fn {name, description} -> "- #{name}: #{description}" end)
    )
  end

  # Only the tools that can read a saved result are named, and without one
  # there is nothing to say.
  defp large_tool_results_prompt(middleware, offered) do
    ways = for {name, how} <- @offloaded_result_readers, name in offered, do: how

    if ways != [] do
      @large_tool_results_prompt
      |> Offload.format_notice(how_to_read: Enum.join(ways, ", or "))
      |> Offload.format_notice(large_tool_results_prefix: middleware.large_tool_results_prefix)
    end
  end

  defp command_messages(update) when is_map(update) do
    cond do
      Map.has_key?(update, :messages) -> {:messages, Map.fetch!(update, :messages)}
      Map.has_key?(update, "messages") -> {"messages", Map.fetch!(update, "messages")}
      true -> {nil, nil}
    end
  end

  defp backend_opts(request) do
    Enum.reject([state: request.state || %{}, store: runtime_store(request.runtime), runtime: request.runtime], fn
      {_key, value} -> is_nil(value)
    end)
  end

  defp tool_name(call), do: to_string(MapAccess.get(call, :name))
end
