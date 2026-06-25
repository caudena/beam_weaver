defmodule DemoRemoteProvider do
  @behaviour BeamWeaver.Sandbox.Provider

  alias BeamWeaver.Sandbox

  @impl true
  def build(spec, opts) do
    root =
      spec.config
      |> Map.get(:root, Path.join(System.tmp_dir!(), "beam_weaver_demo_#{Keyword.fetch!(opts, :sandbox_id)}"))
      |> Path.expand()

    {:ok, Sandbox.local(root: root)}
  end
end

alias BeamWeaver.Sandbox
alias BeamWeaver.Sandbox.Registry

{:ok, registry} =
  Registry.new(
    providers: [
      %{
        id: :demo_remote,
        module: DemoRemoteProvider,
        config: %{api_key: "sk-demo"},
        capabilities: %{sandbox_id: true, snapshot: true}
      }
    ]
  )

{:ok, sandbox} =
  Registry.build(registry, :demo_remote,
    sandbox_id: "sbx_demo",
    snapshot_id: "snap_demo"
  )

result =
  Sandbox.execute(sandbox, "printf 'sandbox ok'",
    command_id: "cmd_demo",
    metadata: %{
      provider_id: "demo_remote",
      sandbox_id: "sbx_demo",
      snapshot_id: "snap_demo",
      request_token: "secret"
    }
  )

IO.inspect(result, label: "sandbox result", pretty: true)
