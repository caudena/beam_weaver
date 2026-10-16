defmodule BeamWeaver.Diagnostics do
  @moduledoc """
  Runtime diagnostics.

  Reports the BeamWeaver, Elixir and OTP versions and basic VM details, for
  example to include in a bug report. It returns plain data for callers and
  only prints when explicitly asked.
  """

  @doc """
  Returns BeamWeaver and VM runtime metadata.
  """
  @spec runtime_environment() :: map()
  def runtime_environment do
    %{
      "beam_weaver_version" => Application.spec(:beam_weaver, :vsn) |> to_string(),
      "elixir_version" => System.version(),
      "otp_release" => System.otp_release(),
      "erts_version" => :erlang.system_info(:version) |> to_string(),
      "system_architecture" => :erlang.system_info(:system_architecture) |> to_string(),
      "schedulers" => System.schedulers_online()
    }
  end

  @doc """
  Prints runtime diagnostics in a deterministic order.
  """
  @spec print_sys_info(keyword()) :: :ok
  def print_sys_info(opts \\ []) do
    output = Keyword.get(opts, :output, &IO.puts/1)

    runtime_environment()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.each(fn {key, value} -> output.("#{key}: #{value}") end)
  end
end
