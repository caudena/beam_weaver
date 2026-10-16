defmodule BeamWeaver.Agent.Middleware.Helpers do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Models.Profile

  # Call options the agent passes to whichever model answers a call: the run's
  # context and cache, the assistant's name, tracing, and checks that don't
  # depend on the model.
  @agent_call_options [
    :assistant_name,
    :cache,
    :context,
    :exporter,
    :exporter_opts,
    :run_id,
    :strict,
    :trace,
    :trace?,
    :trace_metadata,
    :unsupported
  ]

  def append_prompt(messages, nil), do: messages
  def append_prompt(messages, ""), do: messages
  def append_prompt(nil, prompt), do: Message.system(prompt)

  def append_prompt(%Message{role: :system, content: content} = message, prompt)
      when is_binary(content),
      do: %{message | content: content <> "\n\n" <> prompt}

  def append_prompt([%Message{role: :system, content: content} = first | rest], prompt)
      when is_binary(content),
      do: [%{first | content: content <> "\n\n" <> prompt} | rest]

  def append_prompt(other, prompt) when is_list(other), do: [Message.system(prompt) | other]
  def append_prompt(other, prompt), do: [Message.system(prompt), other]

  def runtime_store(%{store: store}), do: store
  def runtime_store(_runtime), do: nil

  def maybe_put_files_update(update, _state_key, nil), do: update

  def maybe_put_files_update(update, state_key, files_update),
    do: Map.put(update, state_key, files_update)

  def artifact_prefix(%{artifacts_root: root}, name) when is_binary(root) do
    root = String.trim_trailing(root, "/")
    if(root == "", do: "", else: root) <> "/" <> name
  end

  def artifact_prefix(_backend, name), do: "/" <> name

  # Moves a cut index so a tool result is never split from the assistant
  # message that called it: back to that message, or past the run of tool
  # results when the call is no longer in `messages`.
  def safe_cut_index(messages, index) when index >= length(messages), do: index

  def safe_cut_index(messages, index) do
    case Enum.at(messages, index) do
      %Message{role: :tool, tool_call_id: id} when is_binary(id) ->
        calling_index(messages, index, id) || skip_tool_results(messages, index)

      _message ->
        index
    end
  end

  # The id a tool call's result answers to (`Message.tool_call_id`).
  def tool_call_id(%{id: id}) when is_binary(id), do: id
  def tool_call_id(%{call_id: id}) when is_binary(id), do: id
  def tool_call_id(%{provider_id: id}) when is_binary(id), do: id
  def tool_call_id(%{"id" => id}) when is_binary(id), do: id
  def tool_call_id(%{"call_id" => id}) when is_binary(id), do: id
  def tool_call_id(%{"provider_id" => id}) when is_binary(id), do: id
  def tool_call_id(_call), do: nil

  defp calling_index(messages, index, tool_call_id) do
    messages
    |> Enum.take(index)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: :assistant, tool_calls: calls}, assistant_index} when is_list(calls) ->
        if Enum.any?(calls, &(tool_call_id(&1) == tool_call_id)), do: assistant_index

      _other ->
        nil
    end)
  end

  defp skip_tool_results(messages, index) do
    messages
    |> Enum.drop(index)
    |> Enum.take_while(&match?(%Message{role: :tool}, &1))
    |> length()
    |> Kernel.+(index)
  end

  # Index of the last message with `role`, or nil.
  def last_role_index(messages, role) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: ^role}, index} -> index
      _other -> nil
    end)
  end

  # The call options for `model` when it answers a request written for
  # `replaced`, such as a fallback: the options the agent passes to whichever
  # model answers, and the model parameters `model`'s profile takes (for every
  # API its profile lists). Everything else configures `replaced`, such as
  # its `api_key:`, `base_url:`, `transport:` or `extra_body:`, so `model`
  # keeps its own. A provider's built-in tools (maps in `tools:`) stay with a
  # model of the same kind.
  def call_options_for(opts, replaced, model) when is_list(opts) do
    profile = model_profile(model)
    same_kind? = model_module(replaced) == model_module(model)

    for {key, value} <- opts, key in @agent_call_options or accepted_param?(profile, key, value) do
      if key == :tools and not same_kind? and is_list(value),
        do: {key, Enum.reject(value, &(is_map(&1) and not is_struct(&1)))},
        else: {key, value}
    end
  end

  defp accepted_param?(profile, key, value) do
    ParamPolicy.standard_param?(key) and
      Enum.all?(param_apis(profile), &(ParamPolicy.validate(profile, [{key, value}], :strict, api: &1) == :ok))
  end

  defp param_apis(%Profile{supported_params_by_api: by_api}) when is_map(by_api), do: [nil | Map.keys(by_api)]
  defp param_apis(_profile), do: [nil]

  # Wrappers such as `Models.cached/3` keep the model they wrap in `:model`.
  defp model_profile(%{profile: %Profile{} = profile}), do: profile
  defp model_profile(%{model: %{} = model}), do: model_profile(model)
  defp model_profile(_model), do: nil

  defp model_module(%{model: %_{} = model}), do: model_module(model)
  defp model_module(%module{}), do: module
  defp model_module(_model), do: nil
end
