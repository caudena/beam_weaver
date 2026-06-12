defmodule BeamWeaver.Agent.Middleware.Helpers do
  @moduledoc false

  alias BeamWeaver.Core.Message

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

  def state_value(state, key, default \\ nil)

  def state_value(state, key, default) when is_map(state),
    do: Map.get(state, key, Map.get(state, to_string(key), default))

  def state_value(_state, _key, default), do: default

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
end
