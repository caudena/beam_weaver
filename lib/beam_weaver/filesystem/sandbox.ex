defmodule BeamWeaver.Filesystem.Sandbox do
  @moduledoc "Adapter from `BeamWeaver.Sandbox` implementations to DeepAgents backends."

  use BeamWeaver.Filesystem
  use BeamWeaver.Filesystem.Executable

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.Utils

  @max_binary_bytes 500 * 1024
  @max_output_bytes 500 * 1024
  @truncation_msg "\n\n[Output was truncated due to size limits. This paginated read result exceeded the sandbox stdout limit. Continue reading with a larger offset or smaller limit to inspect the rest of the file.]"

  defstruct [:sandbox]

  def new(opts \\ []), do: %__MODULE__{sandbox: Keyword.fetch!(opts, :sandbox)}

  def max_binary_bytes, do: @max_binary_bytes
  def max_output_bytes, do: @max_output_bytes
  def truncation_msg, do: @truncation_msg

  @impl BeamWeaver.Filesystem.Executable
  def id(%__MODULE__{sandbox: sandbox}), do: Map.get(sandbox, :id) || inspect(sandbox)

  @impl BeamWeaver.Filesystem.Executable
  def execute(%__MODULE__{sandbox: sandbox}, command, opts) do
    result = BeamWeaver.Sandbox.execute(sandbox, command, opts)

    %Executable.ExecuteResult{
      exit_code: result.exit_code,
      output: result.output || "",
      error: result.error,
      truncated: result.truncated == true,
      metadata: result.metadata || %{}
    }
  end

  @impl BeamWeaver.Filesystem
  def ls(%__MODULE__{sandbox: sandbox}, path, opts),
    do: sandbox |> BeamWeaver.Sandbox.ls(path, opts) |> list_result()

  @impl BeamWeaver.Filesystem
  def read(%__MODULE__{sandbox: sandbox}, path, opts),
    do: sandbox |> BeamWeaver.Sandbox.read(path, opts) |> read_result()

  @impl BeamWeaver.Filesystem
  def write(%__MODULE__{sandbox: sandbox}, path, content, opts),
    do: sandbox |> BeamWeaver.Sandbox.write(path, content, opts) |> write_result()

  @impl BeamWeaver.Filesystem
  def edit(%__MODULE__{sandbox: sandbox}, path, old, new, opts),
    do: sandbox |> BeamWeaver.Sandbox.edit(path, old, new, opts) |> edit_result()

  @impl BeamWeaver.Filesystem
  def glob(%__MODULE__{sandbox: sandbox}, pattern, opts),
    do: sandbox |> BeamWeaver.Sandbox.glob(pattern, opts) |> glob_result()

  @impl BeamWeaver.Filesystem
  def grep(%__MODULE__{sandbox: sandbox}, pattern, opts),
    do: sandbox |> BeamWeaver.Sandbox.grep(pattern, opts) |> grep_result()

  @impl BeamWeaver.Filesystem
  def upload_files(%__MODULE__{sandbox: sandbox}, files, opts) do
    sandbox
    |> BeamWeaver.Sandbox.upload_files(files, opts)
    |> Enum.map(&%Filesystem.UploadResult{path: &1.path, error: &1.error})
  end

  @impl BeamWeaver.Filesystem
  def download_files(%__MODULE__{sandbox: sandbox}, paths, opts) do
    sandbox
    |> BeamWeaver.Sandbox.download_files(paths, opts)
    |> Enum.map(&%Filesystem.DownloadResult{path: &1.path, content: &1.content, error: &1.error})
  end

  defp list_result(%{entries: entries, error: nil}),
    do: %Filesystem.LsResult{
      entries: Enum.map(entries || [], &struct(Filesystem.FileInfo, atomize(&1)))
    }

  defp list_result(%{error: error}), do: %Filesystem.LsResult{error: error}

  defp read_result(%{file_data: data, error: nil}),
    do: %Filesystem.ReadResult{file_data: Utils.normalize_file_data(data)}

  defp read_result(%{error: error}), do: %Filesystem.ReadResult{error: error}

  defp write_result(%{path: path, error: error}),
    do: %Filesystem.WriteResult{path: path, error: error}

  defp edit_result(%{path: path, occurrences: occurrences, error: error}),
    do: %Filesystem.EditResult{path: path, occurrences: occurrences, error: error}

  defp glob_result(%{matches: matches, error: nil}),
    do: %Filesystem.GlobResult{
      matches: Enum.map(matches || [], &struct(Filesystem.FileInfo, atomize(&1)))
    }

  defp glob_result(%{error: error}), do: %Filesystem.GlobResult{error: error}

  defp grep_result(%{matches: matches, error: nil}),
    do: %Filesystem.GrepResult{
      matches: Enum.map(matches || [], &struct(Filesystem.GrepMatch, atomize(&1)))
    }

  defp grep_result(%{error: error}), do: %Filesystem.GrepResult{error: error}

  defp atomize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {existing_atom_key(key), value} end)

  defp existing_atom_key(key) when is_atom(key), do: key

  defp existing_atom_key(key) do
    key
    |> to_string()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> key
  end
end
