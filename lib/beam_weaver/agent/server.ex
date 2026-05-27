defmodule BeamWeaver.Agent.Server do
  @moduledoc false

  use GenServer

  def start_link(agent_module, opts \\ []) do
    GenServer.start_link(__MODULE__, {agent_module, opts}, name: opts[:name])
  end

  def invoke(server, input, opts \\ []) do
    GenServer.call(server, {:invoke, input, opts}, Keyword.get(opts, :timeout, 5_000))
  end

  def stream_events(server, input, opts \\ []) do
    GenServer.call(server, {:stream_events, input, opts}, Keyword.get(opts, :timeout, 5_000))
  end

  @impl true
  def init({agent_module, opts}) do
    {:ok, %{agent_module: agent_module, opts: opts}}
  end

  @impl true
  def handle_call({:invoke, input, opts}, _from, state) do
    {:reply, BeamWeaver.Agent.invoke(state.agent_module, input, Keyword.merge(state.opts, opts)), state}
  end

  def handle_call({:stream_events, input, opts}, _from, state) do
    {:reply, BeamWeaver.Agent.stream_events(state.agent_module, input, Keyword.merge(state.opts, opts)), state}
  end
end
