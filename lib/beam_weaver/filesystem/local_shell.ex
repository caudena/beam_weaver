defmodule BeamWeaver.Filesystem.LocalShell do
  @moduledoc """
  Unsafe local shell backend for trusted development workflows.

  Commands run on the host with the current OS user's permissions. This module
  is not a sandbox and must not be used for untrusted input.
  """

  use BeamWeaver.Filesystem
  use BeamWeaver.Filesystem.Executable

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.Local

  defstruct root: nil,
            env: %{},
            inherit_env: true,
            timeout: 120,
            max_output_bytes: 100_000

  def new(opts \\ []) do
    root = opts |> Keyword.get(:root, Keyword.get(opts, :root_dir, ".")) |> Path.expand()
    File.mkdir_p!(root)

    %__MODULE__{
      root: root,
      env:
        opts
        |> Keyword.get(:env, %{})
        |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end),
      inherit_env: Keyword.get(opts, :inherit_env, true),
      timeout: Keyword.get(opts, :timeout, 120),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, 100_000)
    }
  end

  @impl BeamWeaver.Filesystem.Executable
  def id(%__MODULE__{root: root}), do: "local-shell:#{root}"

  @impl BeamWeaver.Filesystem.Executable
  def execute(%__MODULE__{} = backend, command, opts) do
    case opts |> Keyword.get(:timeout, backend.timeout) |> timeout_ms() do
      {:ok, timeout} ->
        task =
          Task.async(fn ->
            {output, exit_code} =
              System.cmd("sh", ["-c", command],
                cd: backend.root,
                env: command_env(backend),
                stderr_to_stdout: true
              )

            {output, truncated?} = truncate(output, backend.max_output_bytes)
            {output, exit_code, truncated?}
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, exit_code, truncated?}} ->
            %Executable.ExecuteResult{
              exit_code: exit_code,
              output: output,
              truncated: truncated?
            }

          nil ->
            %Executable.ExecuteResult{
              exit_code: 124,
              output: "",
              error: "timeout",
              truncated: false
            }
        end

      {:error, error} ->
        %Executable.ExecuteResult{
          exit_code: nil,
          output: "",
          error: error,
          truncated: false
        }
    end
  rescue
    exception ->
      %Executable.ExecuteResult{
        exit_code: 1,
        output: "",
        error: Exception.message(exception),
        truncated: false
      }
  end

  @impl BeamWeaver.Filesystem
  def ls(%__MODULE__{} = backend, path, opts),
    do: backend |> filesystem() |> Filesystem.ls(path, opts)

  @impl BeamWeaver.Filesystem
  def read(%__MODULE__{} = backend, path, opts),
    do: backend |> filesystem() |> Filesystem.read(path, opts)

  @impl BeamWeaver.Filesystem
  def write(%__MODULE__{} = backend, path, content, opts),
    do: backend |> filesystem() |> Filesystem.write(path, content, opts)

  @impl BeamWeaver.Filesystem
  def edit(%__MODULE__{} = backend, path, old, new, opts),
    do: backend |> filesystem() |> Filesystem.edit(path, old, new, opts)

  @impl BeamWeaver.Filesystem
  def glob(%__MODULE__{} = backend, pattern, opts),
    do: backend |> filesystem() |> Filesystem.glob(pattern, opts)

  @impl BeamWeaver.Filesystem
  def grep(%__MODULE__{} = backend, pattern, opts),
    do: backend |> filesystem() |> Filesystem.grep(pattern, opts)

  @impl BeamWeaver.Filesystem
  def upload_files(%__MODULE__{} = backend, files, opts),
    do: backend |> filesystem() |> Filesystem.upload_files(files, opts)

  @impl BeamWeaver.Filesystem
  def download_files(%__MODULE__{} = backend, paths, opts),
    do: backend |> filesystem() |> Filesystem.download_files(paths, opts)

  defp filesystem(%__MODULE__{root: root}), do: Local.new(root: root)

  defp command_env(%__MODULE__{inherit_env: true, env: env}), do: Enum.to_list(env)

  defp command_env(%__MODULE__{inherit_env: false, env: env}) do
    inherited =
      System.get_env()
      |> Map.keys()
      |> Enum.map(&{&1, nil})

    inherited ++ Enum.to_list(env)
  end

  defp timeout_ms(timeout) when is_integer(timeout) and timeout in 1..3600,
    do: {:ok, timeout * 1_000}

  defp timeout_ms(_timeout), do: {:error, "timeout must be an integer between 1 and 3600 seconds"}

  defp truncate(output, :unlimited), do: {output, false}

  defp truncate(output, max_bytes) when is_integer(max_bytes) and byte_size(output) > max_bytes do
    {binary_part(output, 0, max_bytes) <> "\n\n... Output truncated at #{max_bytes} bytes.", true}
  end

  defp truncate(output, _max_bytes), do: {output, false}
end
