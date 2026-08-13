defmodule BeamWeaver.Checkpoint.APITest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS
  alias BeamWeaver.Core.Error

  defmodule ErrorSaver do
    @behaviour BeamWeaver.Checkpoint.Saver

    defstruct []

    @impl true
    def fetch_tuple(_saver, _config), do: {:error, :storage_unavailable}

    @impl true
    def list_result(_saver, _config, _opts), do: {:error, :storage_unavailable}

    @impl true
    def get_tuple(_saver, _config), do: nil

    @impl true
    def list(_saver, _config, _opts), do: []

    @impl true
    def put(_saver, _config, _checkpoint, _metadata, _versions), do: {:error, :unsupported}

    @impl true
    def put_writes(_saver, _config, _writes, _task_id, _task_path),
      do: {:error, :unsupported}

    @impl true
    def get_delta_channel_history(_saver, _config, _channels, _opts), do: %{}

    @impl true
    def delete_thread(_saver, _thread_id), do: :ok

    @impl true
    def delete_for_runs(_saver, _run_ids), do: :ok

    @impl true
    def copy_thread(_saver, _source_thread_id, _target_thread_id), do: :ok

    @impl true
    def prune(_saver, _thread_ids, _opts), do: :ok

    @impl true
    def next_version(_saver, current, _channel), do: current
  end

  defmodule RaisingSaver do
    defstruct []

    def get_tuple(_saver, _config), do: raise("database disconnected")
    def list(_saver, _config, _opts), do: raise("database disconnected")
  end

  test "read APIs preserve adapter errors" do
    saver = %ErrorSaver{}

    assert {:error, :storage_unavailable} = Checkpoint.fetch_tuple(saver, config())
    assert {:error, :storage_unavailable} = Checkpoint.list_result(saver, config())

    assert_raise RuntimeError, ":storage_unavailable", fn ->
      Checkpoint.get_tuple(saver, config())
    end

    assert_raise RuntimeError, ":storage_unavailable", fn ->
      Checkpoint.list(saver, config())
    end
  end

  test "legacy saver exceptions become typed read errors" do
    saver = %RaisingSaver{}

    assert {:error, %Error{type: :checkpoint_read_failed, message: "database disconnected"}} =
             Checkpoint.fetch_tuple(saver, config())

    assert {:error, %Error{type: :checkpoint_read_failed, message: "database disconnected"}} =
             Checkpoint.list_result(saver, config())
  end

  test "combined persistence fails before writing when the saver is not atomic" do
    saver = ETS.new()
    config = config()
    checkpoint = %{"id" => "checkpoint-1", "channel_values" => %{"value" => 1}}

    assert {:error, %Error{type: :atomic_checkpoint_write_unsupported}} =
             Checkpoint.put_checkpoint_with_writes(
               saver,
               config,
               checkpoint,
               %{},
               %{},
               [{"value", 1}]
             )

    assert {:ok, nil} = Checkpoint.fetch_tuple(saver, config)
  end

  defp config do
    %{"configurable" => %{"thread_id" => "checkpoint-api-test"}}
  end
end
