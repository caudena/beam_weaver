defmodule BeamWeaver.TestSupport.ConfigHelper do
  @moduledoc false

  def put_config(group, values) when is_atom(group) do
    previous = Application.get_env(:beam_weaver, group, :__beamweaver_missing__)

    Application.put_env(:beam_weaver, group, values)

    ExUnit.Callbacks.on_exit(fn ->
      restore_config(group, previous)
    end)

    :ok
  end

  def merge_config(group, values) when is_atom(group) do
    previous = Application.get_env(:beam_weaver, group, :__beamweaver_missing__)
    current = if previous == :__beamweaver_missing__, do: [], else: previous

    Application.put_env(:beam_weaver, group, Keyword.merge(current, values))

    ExUnit.Callbacks.on_exit(fn ->
      restore_config(group, previous)
    end)

    :ok
  end

  defp restore_config(group, :__beamweaver_missing__),
    do: Application.delete_env(:beam_weaver, group)

  defp restore_config(group, value), do: Application.put_env(:beam_weaver, group, value)
end
