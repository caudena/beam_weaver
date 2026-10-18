defmodule BeamWeaver.Filesystem.LocalShell do
  @moduledoc """
  Unsafe local shell backend for trusted development workflows.

  Commands run on the host with the current OS user's permissions. This module
  is not a sandbox and must not be used for untrusted input.

  Commands start from a minimal environment: `PATH`, `HOME`, `LANG`, the
  `LC_*` variables, `TMPDIR`, `USER` and `SHELL`, plus the variables in
  `:env`. Pass `inherit_env: true` to give them your application's whole
  environment instead.
  """

  use BeamWeaver.Filesystem
  use BeamWeaver.Filesystem.Executable

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Sandbox.CommandRunner
  alias BeamWeaver.Sandbox.OutputBuffer

  # `env` can carry credentials meant only for the commands.
  @derive {Inspect, except: [:env]}
  defstruct root: nil,
            env: %{},
            inherit_env: false,
            timeout: 120,
            max_output_bytes: 100_000

  def new(opts \\ []) do
    root = opts |> Keyword.get(:root, Keyword.get(opts, :root_dir, ".")) |> Path.expand()
    File.mkdir_p!(root)

    %__MODULE__{
      root: root,
      env: opts |> Keyword.get(:env, %{}) |> Map.new(fn {key, value} -> {to_string(key), value} end),
      inherit_env: Keyword.get(opts, :inherit_env, false),
      timeout: Keyword.get(opts, :timeout, 120),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, 100_000)
    }
  end

  @impl BeamWeaver.Filesystem.Executable
  def id(%__MODULE__{root: root}), do: "local-shell:#{root}"

  @impl BeamWeaver.Filesystem.Executable
  def execute(%__MODULE__{} = backend, command, opts) do
    with {:ok, timeout} <- opts |> Keyword.get(:timeout, backend.timeout) |> CommandRunner.timeout_ms() do
      case CommandRunner.run(command,
             shell: CommandRunner.shell(),
             cd: backend.root,
             env: backend.env,
             inherit_env: backend.inherit_env,
             timeout: timeout,
             into: %OutputBuffer{max_bytes: backend.max_output_bytes}
           ) do
        {:ok, {output, truncated?}, exit_code} ->
          %Executable.ExecuteResult{exit_code: exit_code, output: output, truncated: truncated?}

        {:timeout, _kill_attempted?} ->
          %Executable.ExecuteResult{exit_code: 124, output: "", error: "timeout", truncated: false}

        {:error, reason} ->
          %Executable.ExecuteResult{
            exit_code: 1,
            output: "",
            error: CommandRunner.error_message(reason),
            truncated: false
          }
      end
    else
      {:error, error} ->
        %Executable.ExecuteResult{exit_code: nil, output: "", error: error, truncated: false}
    end
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

  @impl BeamWeaver.Filesystem
  def canonical_paths(%__MODULE__{} = backend, paths, opts),
    do: backend |> filesystem() |> Filesystem.canonical_paths(paths, opts)

  defp filesystem(%__MODULE__{root: root}), do: Local.new(root: root)
end
