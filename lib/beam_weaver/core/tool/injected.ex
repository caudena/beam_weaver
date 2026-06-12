defmodule BeamWeaver.Core.Tool.Injected do
  @moduledoc false

  alias BeamWeaver.Core.Error

  def normalize(nil), do: {:ok, %{}}
  def normalize(injected) when injected == %{}, do: {:ok, %{}}

  def normalize(injected) when is_list(injected) do
    if Enum.all?(injected, &match?({_key, _source}, &1)) do
      injected |> Map.new() |> normalize()
    else
      invalid_injected(injected)
    end
  end

  def normalize(injected) when is_map(injected) do
    Enum.reduce_while(injected, {:ok, %{}}, fn {key, source}, {:ok, acc} ->
      with :ok <- validate_key(key),
           {:ok, source} <- normalize_source(source) do
        {:cont, {:ok, Map.put(acc, key, source)}}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  def normalize(injected), do: invalid_injected(injected)

  def normalize!(injected) do
    case normalize(injected) do
      {:ok, injected} -> injected
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp invalid_injected(injected) do
    {:error,
     Error.new(:invalid_tool, "tool injected args must be a map or keyword list", %{
       injected: inspect(injected)
     })}
  end

  defp validate_key(key) when is_atom(key) or is_binary(key), do: :ok

  defp validate_key(key) do
    {:error,
     Error.new(:invalid_tool, "tool injected arg names must be atoms or strings", %{
       key: inspect(key)
     })}
  end

  defp normalize_source(source)
       when source in [
              :state,
              :store,
              :runtime,
              :tool_runtime,
              :tool_call_id,
              :context,
              :config,
              :checkpointer
            ],
       do: {:ok, source}

  defp normalize_source("state"), do: {:ok, :state}
  defp normalize_source("store"), do: {:ok, :store}
  defp normalize_source("runtime"), do: {:ok, :runtime}
  defp normalize_source("tool_runtime"), do: {:ok, :tool_runtime}
  defp normalize_source("tool_call_id"), do: {:ok, :tool_call_id}
  defp normalize_source("context"), do: {:ok, :context}
  defp normalize_source("config"), do: {:ok, :config}
  defp normalize_source("checkpointer"), do: {:ok, :checkpointer}

  defp normalize_source({state, field_or_path})
       when state in [:state, "state"] do
    if valid_state_field_or_path?(field_or_path) do
      {:ok, {:state, field_or_path}}
    else
      invalid_state_source(field_or_path)
    end
  end

  defp normalize_source(source) do
    {:error,
     Error.new(:invalid_tool, "tool injected arg source is not supported", %{
       source: inspect(source),
       supported: [
         :state,
         :store,
         :runtime,
         :tool_runtime,
         :tool_call_id,
         :context,
         :config,
         :checkpointer,
         "{:state, field_or_path}"
       ]
     })}
  end

  defp valid_state_field_or_path?(field) when is_atom(field) or is_binary(field), do: true

  defp valid_state_field_or_path?(path) when is_list(path) and path != [] do
    Enum.all?(path, &(is_atom(&1) or is_binary(&1)))
  end

  defp valid_state_field_or_path?(_field_or_path), do: false

  defp invalid_state_source(field_or_path) do
    {:error,
     Error.new(:invalid_tool, "state injected source must name a field or non-empty path", %{
       source: inspect({:state, field_or_path})
     })}
  end
end
