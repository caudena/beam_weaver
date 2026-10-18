# Shared by the live examples. The model comes from BEAM_WEAVER_EXAMPLES_MODEL
# (default "openai:gpt-5.4-mini") and its key from the provider's environment
# variable, for example OPENAI_API_KEY or ANTHROPIC_API_KEY.
defmodule BeamWeaver.Examples.Support.ToolLog do
  @moduledoc false
  use BeamWeaver.Agent.Middleware

  defstruct [:owner]

  @impl true
  def wrap_tool_call(%__MODULE__{owner: owner}, request, handler) do
    result = handler.(request)

    if Enum.any?(
         BeamWeaver.Examples.Support.successful_tool_results(result),
         &(&1.tool_call_id == request.tool_call.id)
       ),
       do: send(owner, {:beam_weaver_example_tool_call, request.tool_call})

    result
  end
end

defmodule BeamWeaver.Examples.Support do
  @moduledoc false

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models

  # Some providers take close to a minute on the large prompts of the caching
  # examples; the limit catches hung calls, not slow ones.
  @live_model_timeout 120_000
  @prompt_cache_version "v1"

  @doc """
  Raises unless the agent successfully completed every expected tool. An entry
  is a tool name, `{name, expected_args}`, or a list when any one of them will
  do: `assert_tools_called!(messages, ["task", ["write_file", "edit_file"]])`.
  Before raising, it prints the conversation, one line per message.
  """
  def assert_tools_called!(messages, expected) do
    results = Enum.map(successful_tool_results(messages), & &1.tool_call_id)

    calls =
      for(%Message{role: :assistant, tool_calls: calls} <- messages, call <- calls || [], call.id in results, do: call) ++
        logged_tool_calls()

    called = Enum.map(calls, & &1.name)

    missing =
      for names <- expected,
          names = List.wrap(names),
          not Enum.any?(names, fn expected -> Enum.any?(calls, &matches_call?(&1, expected)) end),
          do: Enum.map_join(names, " or ", &inspect/1)

    if missing != [] do
      IO.puts(transcript(messages))

      raise "expected successful execution of #{Enum.join(missing, ", ")}; " <>
              "completed #{if called == [], do: "no tools", else: Enum.join(Enum.uniq(called), ", ")}"
    end

    IO.puts("Tools called: #{Enum.join(called, ", ")}")
    called
  end

  defp matches_call?(call, {name, check}) when is_function(check, 1), do: call.name == name and check.(call.args)
  defp matches_call?(call, {name, args}), do: call.name == name and Map.take(call.args, Map.keys(args)) == args
  defp matches_call?(call, name), do: call.name == name

  def successful_tool_results(%Message{role: :tool} = message) do
    if message.status in [:error, "error"] or
         (message.metadata || %{})[:status] in [:error, "error"], do: [], else: [message]
  end

  def successful_tool_results(%BeamWeaver.Graph.Command{update: update}) when is_map(update),
    do: successful_tool_results(update[:messages] || update["messages"] || [])

  def successful_tool_results({:ok, result}), do: successful_tool_results(result)
  def successful_tool_results(results) when is_list(results), do: Enum.flat_map(results, &successful_tool_results/1)
  def successful_tool_results(_result), do: []

  def assert_text!(%Message{} = message), do: assert_text!(Message.text(message))

  def assert_text!(text) when is_binary(text) do
    if String.trim(text) == "", do: raise("provider returned no answer text")
    text
  end

  def assert_files!(pattern) do
    files = Path.wildcard(pattern) |> Enum.filter(&File.regular?/1)
    if files == [], do: raise("expected generated files matching #{pattern}")
    Enum.each(files, &(File.read!(&1) |> assert_text!()))
    files
  end

  @doc """
  Middleware that reports every tool call to the process that runs the agent,
  so `assert_tools_called!/2` sees calls that summarization later removed
  from the messages. Declare it as `middleware [..., Support.tool_log()]`:
  declarations are evaluated when the agent runs, in the calling process.
  """
  def tool_log, do: %BeamWeaver.Examples.Support.ToolLog{owner: self()}

  defp logged_tool_calls do
    receive do
      {:beam_weaver_example_tool_call, call} -> [call | logged_tool_calls()]
    after
      0 -> []
    end
  end

  # The conversation, one shortened line per message, so a failed run's log shows what the model did.
  defp transcript(messages) do
    lines =
      for %Message{} = message <- messages do
        calls = for call <- message.tool_calls || [], do: " -> #{call.name} #{clip(inspect(call.args), 160)}"
        "#{message.role}: #{clip(Message.text(message), 200)}#{Enum.join(calls)}"
      end

    Enum.join(["\nTranscript:" | lines], "\n  ")
  end

  defp clip(text, max) do
    text = String.replace(text, ~r/\s+/, " ")
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  @doc "A directory for one example's files, one per provider so that runs on several providers don't collide."
  def tmp_dir(name), do: Path.join([System.tmp_dir!(), "beam_weaver_examples", provider(), name])

  def model do
    case Models.init_chat_model(model_id(), model_opts()) do
      {:ok, model} -> model
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def model_id, do: Config.get([:examples, :model]) || "openai:gpt-5.4-mini"

  def model_opts do
    [
      api_key: api_key(),
      max_tokens: 2048,
      timeout: @live_model_timeout
    ]
    |> maybe_put_zai_defaults()
  end

  def api_key do
    key = Config.get([:examples, :api_keys], %{}) |> Map.get(provider())

    if key in [nil, ""] do
      raise ArgumentError, "set #{String.upcase(provider())}_API_KEY to run the examples (model: #{model_id()})"
    end

    key
  end

  defp provider, do: model_id() |> String.split(":", parts: 2) |> hd()

  def prompt_cache_key(scope, static_prompt) do
    digest =
      static_prompt
      |> then(fn prompt -> :crypto.hash(:sha256, prompt) end)
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 20)

    scope_slug =
      scope
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")

    model_slug =
      model_id()
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
      |> String.slice(0, 16)

    "bwpc:#{@prompt_cache_version}:#{scope_slug}:#{model_slug}:#{digest}"
  end

  def prompt_cache_messages(%BeamWeaver.Anthropic.ChatModel{}, static_prompt, messages) do
    [
      Message.system([
        %{
          type: :text,
          text: static_prompt,
          cache_control: %{type: :ephemeral}
        }
      ])
      | messages
    ]
  end

  def prompt_cache_messages(_model, static_prompt, messages) do
    [Message.system(static_prompt) | messages]
  end

  def prompt_cache_opts(model, scope, static_prompt) do
    key = prompt_cache_key(scope, static_prompt)

    case model do
      %BeamWeaver.OpenAI.ChatModel{model: "gpt-5.6" <> _suffix} ->
        [
          prompt_cache_key: key,
          prompt_cache_options: %{mode: :implicit, ttl: "30m"}
        ]

      %BeamWeaver.OpenAI.ChatModel{} ->
        [prompt_cache_key: key, prompt_cache_retention: :in_memory]

      %BeamWeaver.XAI.ChatModel{} ->
        [prompt_cache_key: key]

      %BeamWeaver.Moonshot.ChatModel{} ->
        [prompt_cache_key: key]

      %BeamWeaver.Anthropic.ChatModel{} ->
        []

      %BeamWeaver.Google.ChatModel{} ->
        case Config.get([:examples, :cached_content]) do
          nil -> []
          cached_content -> [cached_content: cached_content]
        end

      _model ->
        []
    end
  end

  def cache_read_tokens(%Message{usage_metadata: metadata}) when is_map(metadata) do
    get_in(metadata, [:input_token_details, :cache_read]) || 0
  end

  def cache_read_tokens(_message), do: 0

  # GLM models think at their highest effort by default; "low" keeps example runs quick
  # on the models whose profile takes it. (GLM-5.3 models cannot turn thinking off, and
  # GLM-5.1 and older take no effort.)
  defp maybe_put_zai_defaults(opts) do
    with "zai" <- provider(),
         [_provider, id] <- String.split(model_id(), ":", parts: 2),
         {:ok, profile} <- BeamWeaver.Models.ProfileRegistry.fetch(:zai, id),
         true <- takes_effort?(profile, :low) do
      Keyword.put(opts, :reasoning_effort, "low")
    else
      _other -> opts
    end
  end

  defp takes_effort?(profile, effort) do
    efforts = profile.reasoning_effort_levels
    BeamWeaver.Models.Profile.supports_param?(profile, :reasoning_effort) and (efforts == [] or effort in efforts)
  end
end
