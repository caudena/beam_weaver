defmodule BeamWeaver.Filesystem do
  @moduledoc ~S"""
  Virtual filesystem operations used by workspace tools, memory files and skills.

  Paths are absolute from the agent perspective. Backends map them to thread
  state, namespaced memory, disk or a sandbox. Operations return typed result
  structs; inspect their error field before consuming content or claiming a write.

  The facade itself does not apply an agent's filesystem_permissions. Those rules
  belong to file-tool execution; direct application calls must enforce their own
  access policy. Shell execution is a separate capability and boundary.
  See [Filesystem](filesystem.md) for backend selection and lifetimes.
  """

  defmodule FileInfo do
    @moduledoc ~S"""
    Metadata for one virtual entry: path, directory flag, size and modification time. It contains no file contents.
    """
    defstruct [:path, :is_dir, :size, :modified_at]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            is_dir: boolean() | nil,
            size: non_neg_integer() | nil,
            modified_at: String.t() | nil
          }
  end

  defmodule GrepMatch do
    @moduledoc ~S"""
    One literal search hit with virtual path, one-based line number and matching text.
    """
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
    @moduledoc ~S"""
    Directory entries or an error. An empty successful list is different from a missing/denied directory.
    """

    defstruct entries: nil, error: nil

    @type t :: %__MODULE__{
            entries: [FileInfo.t()] | nil,
            error: term()
          }
  end

  defmodule ReadResult do
    @moduledoc ~S"""
    Read content in file_data or an error. Check encoding before treating binary data as text.
    """

    defstruct file_data: nil, error: nil

    @type t :: %__MODULE__{
            file_data: FileData.t() | nil,
            error: term()
          }
  end

  defmodule WriteResult do
    @moduledoc ~S"""
    Write outcome with path and error. A state-backed files_update must be merged into graph state by the caller/tool.
    """

    defstruct [:path, :files_update, error: nil]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            files_update: map() | nil,
            error: term()
          }
  end

  defmodule EditResult do
    @moduledoc ~S"""
    Exact-edit outcome with occurrence count, error and any state-backed files_update.
    """

    defstruct [:path, :files_update, occurrences: nil, error: nil]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            files_update: map() | nil,
            occurrences: non_neg_integer() | nil,
            error: term()
          }
  end

  defmodule GlobResult do
    @moduledoc ~S"""
    Matched FileInfo entries or an error; absence of matches is not a permission or backend failure.
    """

    defstruct matches: nil, error: nil

    @type t :: %__MODULE__{
            matches: [FileInfo.t()] | nil,
            error: term()
          }
  end

  defmodule GrepResult do
    @moduledoc ~S"""
    Literal GrepMatch entries or an error. Search truncation in model-facing tools is reported separately.
    """

    defstruct matches: nil, error: nil

    @type t :: %__MODULE__{
            matches: [GrepMatch.t()] | nil,
            error: term()
          }
  end

  defmodule UploadResult do
    @moduledoc ~S"""
    Outcome for one uploaded path. Check error for every batch entry; another file may have succeeded.
    """

    defstruct [:path, :error]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            error: term()
          }
  end

  defmodule DownloadResult do
    @moduledoc ~S"""
    Outcome for one downloaded path. content is present on success; check error before using it.
    """

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

  @doc """
  Lists entries immediately under a virtual path, returning LsResult.
  """
  @callback ls(term(), String.t(), keyword()) :: LsResult.t()
  @doc """
  Reads file data with line offset/limit options. Inspect ReadResult.error before file_data.
  """
  @callback read(term(), String.t(), keyword()) :: ReadResult.t()
  @doc """
  Creates or replaces file content. State backends return files_update for the caller to merge.
  """
  @callback write(term(), String.t(), iodata(), keyword()) :: WriteResult.t()
  @doc """
  Replaces exact nonempty text; ambiguous matches require replace_all. Returns occurrence count or error.
  """
  @callback edit(term(), String.t(), String.t(), String.t(), keyword()) :: EditResult.t()
  @doc """
  Finds paths using the backend's glob contract under opts[:path].
  """
  @callback glob(term(), String.t(), keyword()) :: GlobResult.t()
  @doc """
  Finds literal case-sensitive text with optional path/glob filtering, returning GrepMatch values.
  """
  @callback grep(term(), String.t(), keyword()) :: GrepResult.t()
  @doc """
  Writes a batch of {virtual_path, content} entries, returning one result per file. Uploads replace existing data.
  """
  @callback upload_files(term(), [{String.t(), iodata()}], keyword()) :: [UploadResult.t()]
  @doc """
  Reads a batch of virtual paths, returning one result per file, including individual errors.
  """
  @callback download_files(term(), [String.t()], keyword()) :: [DownloadResult.t()]
  @doc """
  Resolves requested paths to backend targets for permission checks. Wrappers must forward this for link-capable storage.
  """
  @callback canonical_paths(term(), [String.t()], keyword()) :: [{:ok, String.t()} | {:error, term()}]

  @optional_callbacks canonical_paths: 3

  # Each function calls the backend struct's module.
  @doc """
  Lists entries immediately under a virtual path, returning LsResult.
  """
  def ls(%module{} = backend, path, opts \\ []), do: module.ls(backend, path, opts)

  @doc """
  Reads file data with line offset/limit options. Inspect ReadResult.error before file_data.
  """
  def read(%module{} = backend, path, opts \\ []), do: module.read(backend, path, opts)

  @doc """
  Creates or replaces file content. State backends return files_update for the caller to merge.
  """
  def write(%module{} = backend, path, content, opts \\ []), do: module.write(backend, path, content, opts)

  @doc """
  Replaces exact nonempty text; ambiguous matches require replace_all. Returns occurrence count or error.
  """
  def edit(%module{} = backend, path, old, new, opts \\ []), do: module.edit(backend, path, old, new, opts)

  @doc """
  Finds paths using the backend's glob contract under opts[:path].
  """
  def glob(%module{} = backend, pattern, opts \\ []), do: module.glob(backend, pattern, opts)

  @doc """
  Finds literal case-sensitive text with optional path/glob filtering, returning GrepMatch values.
  """
  def grep(%module{} = backend, pattern, opts \\ []), do: module.grep(backend, pattern, opts)

  @doc """
  Writes a batch of {virtual_path, content} entries, returning one result per file. Uploads replace existing data.
  """
  def upload_files(%module{} = backend, files, opts \\ []), do: module.upload_files(backend, files, opts)

  @doc """
  Reads a batch of virtual paths, returning one result per file, including individual errors.
  """
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

  @doc """
  Renders literal grep results as path:line:text text, or an Error-prefixed string.
  """
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
  @moduledoc ~S"""
  Optional command-execution behavior for filesystem backends.

  Support for this interface says a backend can execute commands, not that it
  isolates them. LocalShell runs with host-user privileges. Sandbox backends
  inherit the configured container/service boundary. Agent file permissions do
  not constrain execute.

  Inspect error, exit_code and truncated output on ExecuteResult. A delivered
  nonzero command exit is not necessarily a failed tool transport. See
  [Sandboxes](sandboxes.md).
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

  def executable?(%module{} = backend) do
    BeamWeaver.Behaviour.implemented_by?(module, __MODULE__) and
      (not function_exported?(module, :executable?, 1) or module.executable?(backend) == true)
  end

  def executable?(_backend), do: false
end
