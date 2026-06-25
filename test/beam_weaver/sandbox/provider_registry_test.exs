defmodule BeamWeaver.Sandbox.RegistryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Sandbox
  alias BeamWeaver.Sandbox.ProviderSpec
  alias BeamWeaver.Sandbox.Registry

  defmodule FakeProvider do
    @behaviour BeamWeaver.Sandbox.Provider

    alias BeamWeaver.Sandbox.RegistryTest.FakeRemoteSandbox

    @impl true
    def build(spec, opts) do
      {:ok,
       struct(FakeRemoteSandbox,
         provider_id: spec.id,
         sandbox_id: Keyword.get(opts, :sandbox_id),
         snapshot_id: Keyword.get(opts, :snapshot_id),
         mounts: Keyword.get(opts, :mounts, []),
         config: spec.config
       )}
    end
  end

  defmodule InvalidProvider do
  end

  defmodule NotASandboxProvider do
    @behaviour BeamWeaver.Sandbox.Provider

    @impl true
    def build(_spec, _opts), do: {:ok, %{not: :a_sandbox}}
  end

  defmodule FakeRemoteSandbox do
    use BeamWeaver.Sandbox

    alias BeamWeaver.Sandbox

    defstruct [
      :provider_id,
      :sandbox_id,
      :snapshot_id,
      mounts: [],
      config: %{}
    ]

    @impl true
    def execute(%__MODULE__{} = sandbox, command, opts) do
      %Sandbox.ExecuteResult{
        exit_code: 0,
        output: "remote:#{command}",
        metadata: %{
          provider_id: sandbox.provider_id,
          sandbox_id: sandbox.sandbox_id,
          snapshot_id: sandbox.snapshot_id,
          mounts: sandbox.mounts,
          reconnect_count: Keyword.get(opts, :reconnect_count, 0),
          access_token: "secret-token"
        }
      }
    end

    @impl true
    def write(_sandbox, path, _content, _opts), do: %Sandbox.WriteResult{path: path}

    @impl true
    def read(_sandbox, _path, _opts), do: %Sandbox.ReadResult{file_data: %{"encoding" => "utf-8", "content" => ""}}

    @impl true
    def edit(_sandbox, path, _old, _new, _opts), do: %Sandbox.EditResult{path: path, occurrences: 1}

    @impl true
    def ls(_sandbox, _path, _opts), do: %Sandbox.ListResult{entries: []}

    @impl true
    def glob(_sandbox, _pattern, _opts), do: %Sandbox.GlobResult{matches: []}

    @impl true
    def grep(_sandbox, _pattern, _opts), do: %Sandbox.GrepResult{matches: []}

    @impl true
    def upload_files(_sandbox, files, _opts),
      do: Enum.map(files, fn {path, _content} -> %Sandbox.UploadResult{path: path} end)

    @impl true
    def download_files(_sandbox, paths, _opts), do: Enum.map(paths, &%Sandbox.DownloadResult{path: &1, content: ""})
  end

  test "registry merges builtin and configured providers and redacts provider config" do
    assert {:ok, registry} =
             Registry.new(
               providers: [
                 %{
                   id: :remote,
                   module: FakeProvider,
                   config: %{api_key: "sk-secret", region: "us"},
                   capabilities: %{sandbox_id: true, snapshot: true, mounts: true},
                   metadata: %{credential_ref: "vault://secret", owner: "tests"}
                 }
               ]
             )

    assert ["local", "remote"] = registry |> Registry.list() |> Enum.map(& &1.id)

    assert {:ok, %ProviderSpec{} = remote} = Registry.fetch(registry, :remote)
    assert ProviderSpec.capability?(remote, :sandbox_id)
    assert ProviderSpec.capability?(remote, "snapshot")

    inspected = inspect(remote)
    assert inspected =~ "remote"
    assert inspected =~ "**REDACTED**"
    refute inspected =~ "sk-secret"
    refute inspected =~ "vault://secret"
  end

  test "registry rejects duplicate providers and invalid provider modules" do
    assert {:error, %Error{type: :duplicate_sandbox_provider}} =
             Registry.new(
               builtin: false,
               providers: [
                 %{id: :remote, module: FakeProvider},
                 %{id: "remote", module: FakeProvider}
               ]
             )

    assert {:error, %Error{type: :invalid_sandbox_provider}} =
             Registry.new(builtin: false, providers: [%{id: :bad, module: InvalidProvider}])
  end

  test "provider metadata gates lifecycle options and validates built sandbox backends" do
    assert {:ok, registry} =
             Registry.new(
               builtin: false,
               providers: [
                 %{
                   id: :limited,
                   module: FakeProvider,
                   capabilities: %{sandbox_id: false, snapshot: false, mounts: false}
                 },
                 %{id: :broken, module: NotASandboxProvider}
               ]
             )

    assert {:error, %Error{type: :unsupported_sandbox_provider_option, details: details}} =
             Registry.build(registry, :limited, sandbox_id: "sbx-1", snapshot_id: "snap-1", mounts: ["repo"])

    assert Enum.sort(details.options) == [:mounts, :sandbox_id, :snapshot_id]

    assert {:error, %Error{type: :invalid_sandbox_provider_backend}} =
             Registry.build(registry, :broken)
  end

  test "provider build returns normal sandbox backends with redacted execution metadata" do
    assert {:ok, registry} =
             Registry.new(
               builtin: false,
               providers: [
                 %{
                   id: :remote,
                   module: FakeProvider,
                   capabilities: %{sandbox_id: true, snapshot: true, mounts: true}
                 }
               ]
             )

    assert {:ok, sandbox} =
             Registry.build(registry, :remote,
               sandbox_id: "sbx-1",
               snapshot_id: "snap-1",
               mounts: [%{name: "repo", credential_token: "secret"}]
             )

    assert %Sandbox.ExecuteResult{output: "remote:echo ok", metadata: metadata} =
             Sandbox.execute(sandbox, "echo ok", command_id: "cmd-1", reconnect_count: 2)

    assert metadata.provider_id == "remote"
    assert metadata.sandbox_id == "sbx-1"
    assert metadata.snapshot_id == "snap-1"
    assert metadata.command_id == "cmd-1"
    assert metadata.reconnect_count == 2
    assert metadata.access_token == "**REDACTED**"
    assert [%{name: "repo", credential_token: "**REDACTED**"}] = metadata.mounts
  end
end
