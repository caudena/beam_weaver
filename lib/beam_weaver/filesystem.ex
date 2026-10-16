defmodule BeamWeaver.Filesystem do
  @moduledoc """
  Filesystem backend behaviour used by agent filesystem capabilities.

  Backends expose a virtual, POSIX-style filesystem to agent tools. Paths are
  always absolute from the agent perspective, even when the backing storage is
  graph state, a BeamWeaver memory store, local disk, Docker, or a remote
  sandbox service.
  """

  defmodule FileInfo do
    @moduledoc "Metadata for one virtual filesystem entry."
    defstruct [:path, :is_dir, :size, :modified_at]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            is_dir: boolean() | nil,
            size: non_neg_integer() | nil,
            modified_at: String.t() | nil
          }
  end

  defmodule GrepMatch do
    @moduledoc "One literal grep match."
    defstruct [:path, :line, :text]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            line: pos_integer() | nil,
            text: String.t() | nil
          }
  end

  defmodule FileData do
    @moduledoc "File content with its encoding (utf-8 text, or base64 for binary data) and timestamps."
    defstruct [:content, encoding: "utf-8", created_at: nil, modified_at: nil]

    @type t :: %__MODULE__{
            content: binary() | nil,
            encoding: String.t(),
            created_at: String.t() | nil,
            modified_at: String.t() | nil
          }
  end

  defmodule LsResult do
    @moduledoc "Result returned by filesystem directory listing calls."

    defstruct entries: nil, error: nil

    @type t :: %__MODULE__{
            entries: [FileInfo.t()] | nil,
            error: term()
          }
  end

  defmodule ReadResult do
    @moduledoc "Result returned by filesystem read calls."

    defstruct file_data: nil, error: nil

    @type t :: %__MODULE__{
            file_data: FileData.t() | nil,
            error: term()
          }
  end

  defmodule WriteResult do
    @moduledoc "Result returned by filesystem write calls."

    defstruct [:path, :files_update, error: nil]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            files_update: map() | nil,
            error: term()
          }
  end

  defmodule EditResult do
    @moduledoc "Result returned by filesystem edit calls."

    defstruct [:path, :files_update, occurrences: nil, error: nil]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            files_update: map() | nil,
            occurrences: non_neg_integer() | nil,
            error: term()
          }
  end

  defmodule GlobResult do
    @moduledoc "Result returned by filesystem glob calls."

    defstruct matches: nil, error: nil

    @type t :: %__MODULE__{
            matches: [String.t()] | nil,
            error: term()
          }
  end

  defmodule GrepResult do
    @moduledoc "Result returned by filesystem grep calls."

    defstruct matches: nil, error: nil

    @type t :: %__MODULE__{
            matches: [GrepMatch.t()] | nil,
            error: term()
          }
  end

  defmodule UploadResult do
    @moduledoc "Result returned for one uploaded file."

    defstruct [:path, :error]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            error: term()
          }
  end

  defmodule DownloadResult do
    @moduledoc "Result returned for one downloaded file."

    defstruct [:path, :content, :error]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            content: binary() | nil,
            error: term()
          }
  end

  @type t :: struct()

  @file_not_found "file_not_found"
  @invalid_path "invalid_path"
  @is_directory "is_directory"
  @permission_denied "permission_denied"

  def file_not_found, do: @file_not_found
  def invalid_path, do: @invalid_path
  def directory_error, do: @is_directory

  def permission_denied, do: @permission_denied

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Filesystem
    end
  end

  @callback ls(term(), String.t(), keyword()) :: LsResult.t()
  @callback read(term(), String.t(), keyword()) :: ReadResult.t()
  @callback write(term(), String.t(), iodata(), keyword()) :: WriteResult.t()
  @callback edit(term(), String.t(), String.t(), String.t(), keyword()) :: EditResult.t()
  @callback glob(term(), String.t(), keyword()) :: GlobResult.t()
  @callback grep(term(), String.t(), keyword()) :: GrepResult.t()
  @callback upload_files(term(), [{String.t(), iodata()}], keyword()) :: [UploadResult.t()]
  @callback download_files(term(), [String.t()], keyword()) :: [DownloadResult.t()]
  @callback canonical_paths(term(), [String.t()], keyword()) :: [{:ok, String.t()} | {:error, term()}]

  @optional_callbacks canonical_paths: 3

  # Each function calls the backend struct's module.
  def ls(%module{} = backend, path, opts \\ []), do: module.ls(backend, path, opts)
  def read(%module{} = backend, path, opts \\ []), do: module.read(backend, path, opts)
  def write(%module{} = backend, path, content, opts \\ []), do: module.write(backend, path, content, opts)
  def edit(%module{} = backend, path, old, new, opts \\ []), do: module.edit(backend, path, old, new, opts)
  def glob(%module{} = backend, pattern, opts \\ []), do: module.glob(backend, pattern, opts)
  def grep(%module{} = backend, pattern, opts \\ []), do: module.grep(backend, pattern, opts)
  def upload_files(%module{} = backend, files, opts \\ []), do: module.upload_files(backend, files, opts)
  def download_files(%module{} = backend, paths, opts \\ []), do: module.download_files(backend, paths, opts)

  @doc """
  The path of the file `backend` reaches for each of `paths`, in order.

  That is the path without `.` segments and repeated slashes and, on a backend
  with symlinks such as `BeamWeaver.Filesystem.Local`, with every symlink on
  the way followed: for a link `/notes/key.txt` to `/secrets/key.txt`, it is
  `/secrets/key.txt`. The part of a path that doesn't exist yet is kept, so a
  new file's path is its folder's path plus its name. `BeamWeaver.Filesystem.Permission`
  checks this path as well as the one the model wrote, so a link can't give a
  denied file an allowed name.

  Each result is `{:ok, path}`, or `{:error, reason}` for a path the backend
  can't resolve, such as a relative path or one through a symlink that is
  broken or leads out of the backend.

  The callback is optional: a backend without it has no links, and its paths
  come back cleaned. A backend that wraps another one should pass the call to
  it.
  """
  @spec canonical_paths(t(), [String.t()], keyword()) :: [{:ok, String.t()} | {:error, term()}]
  def canonical_paths(%module{} = backend, paths, opts \\ []) when is_list(paths) do
    if BeamWeaver.Behaviour.exported?(module, :canonical_paths, 3),
      do: module.canonical_paths(backend, paths, opts),
      else: Enum.map(paths, &BeamWeaver.Filesystem.Path.clean_path/1)
  end

  @doc "Whether `backend` is a struct whose module implements this behaviour."
  @spec backend?(term()) :: boolean()
  def backend?(%module{}), do: BeamWeaver.Behaviour.implemented_by?(module, __MODULE__)
  def backend?(_other), do: false

  def grep_raw(backend, pattern, opts \\ []) do
    case grep(backend, pattern, opts) do
      %GrepResult{error: nil, matches: matches} ->
        matches
        |> List.wrap()
        |> Enum.map_join("\n", fn %GrepMatch{} = match -> "#{match.path}:#{match.line}:#{match.text}" end)

      %GrepResult{error: error} ->
        "Error: #{error}"
    end
  end
end

defmodule BeamWeaver.Filesystem.Executable do
  @moduledoc """
  Extension behaviour for filesystem backends that can also execute shell commands.

  This behaviour does not imply security. Local shell adapters are explicitly
  unsafe; real isolation must be provided by Docker/gVisor/Kata, Firecracker, or
  a managed sandbox service.
  """

  defmodule ExecuteResult do
    @moduledoc "Result returned by executable filesystem backends."

    defstruct [:exit_code, output: "", error: nil, truncated: false, metadata: %{}]

    @type t :: %__MODULE__{
            exit_code: non_neg_integer() | nil,
            output: String.t(),
            error: term(),
            truncated: boolean(),
            metadata: map()
          }
  end

  @callback id(term()) :: String.t()
  @callback execute(term(), String.t(), keyword()) :: ExecuteResult.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Filesystem.Executable
    end
  end

  def id(%module{} = backend), do: module.id(backend)
  def execute(%module{} = backend, command, opts \\ []), do: module.execute(backend, command, opts)

  def executable?(%module{} = backend),
    do: BeamWeaver.Behaviour.implemented_by?(module, __MODULE__) and executable_enabled?(backend)

  def executable?(_backend), do: false

  defp executable_enabled?(%{__struct__: module} = backend) do
    if function_exported?(module, :executable?, 1) do
      module.executable?(backend) == true
    else
      true
    end
  end
end
