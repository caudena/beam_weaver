defmodule BeamWeaver.Agent.Subagent.StreamTransformerTest do
  use ExUnit.Case, async: true

  # Upstream reference:
  # - libs/deepagents/tests/unit_tests/test_subagent_transformer.py
  # - libs/deepagents/deepagents/_subagent_transformer.py

  alias BeamWeaver.Agent.Subagent.RunStream
  alias BeamWeaver.Agent.Subagent.StreamTransformer
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  test "nondeclared subagent type is ignored" do
    {:ok, transformer, []} =
      StreamTransformer.process_many(transformer(), [
        tools_start(parent_task_id: "abc", subagent_type: "plain_subagent", tool_call_id: "tc-1"),
        child_start(["tools:abc"])
      ])

    assert transformer.log == []
    assert transformer.handles == %{}
  end

  test "declared subagent yields typed handle metadata" do
    {:ok, transformer, [%RunStream{} = handle]} =
      StreamTransformer.process_many(transformer(), [
        tools_start(
          parent_task_id: "abc",
          subagent_type: "researcher",
          tool_call_id: "tc-1",
          description: "find sources"
        ),
        child_start(["tools:abc"])
      ])

    assert transformer.log == [handle]
    assert handle.path == ["tools:abc"]
    assert RunStream.name(handle) == "researcher"
    assert RunStream.cause(handle) == %{"type" => "toolCall", "tool_call_id" => "tc-1"}
    assert handle.task_input == "find sources"
    assert handle.status == :started
  end

  test "parent task result completes a subagent handle" do
    {:ok, transformer, _handles} =
      StreamTransformer.process_many(transformer(), [
        tools_start(parent_task_id: "x", subagent_type: "researcher", tool_call_id: "tc-1"),
        child_start(["tools:x"]),
        parent_tasks_result(parent_task_id: "x")
      ])

    assert [%{status: :completed, error: nil}] = transformer.log
  end

  test "failed parent result stores error" do
    {:ok, transformer, _handles} =
      StreamTransformer.process_many(transformer(), [
        tools_start(parent_task_id: "x", subagent_type: "researcher", tool_call_id: "tc-1"),
        child_start(["tools:x"]),
        parent_tasks_result(parent_task_id: "x", error: "boom")
      ])

    assert [%{status: :failed, error: "boom"}] = transformer.log
  end

  test "values under a subagent namespace are routed into the handle" do
    {:ok, transformer, _handles} =
      StreamTransformer.process_many(transformer(), [
        tools_start(parent_task_id: "x", subagent_type: "researcher", tool_call_id: "tc-1"),
        child_start(["tools:x"]),
        values(%{k: 1}, namespace: ["tools:x"]),
        values(%{k: 2}, namespace: ["tools:x"])
      ])

    assert [%{values: [%{k: 1}, %{k: 2}]} = handle] = transformer.log
    assert RunStream.output(handle) == %{k: 2}
  end

  test "root values do not leak into child handles" do
    {:ok, transformer, _handles} =
      StreamTransformer.process_many(transformer(), [
        tools_start(parent_task_id: "x", subagent_type: "researcher", tool_call_id: "tc-1"),
        child_start(["tools:x"]),
        values(%{k: "root"}, namespace: [])
      ])

    assert [%{values: []}] = transformer.log
  end

  test "nested declared subagents surface under the parent handle" do
    {:ok, transformer, _handles} =
      StreamTransformer.process_many(transformer(), [
        tools_start(parent_task_id: "p", subagent_type: "researcher", tool_call_id: "tc-p"),
        child_start(["tools:p"]),
        tools_start(
          namespace: ["tools:p"],
          parent_task_id: "c",
          subagent_type: "coder",
          tool_call_id: "tc-c"
        ),
        child_start(["tools:p", "tools:c"])
      ])

    assert [
             %{
               path: ["tools:p"],
               subagents: [
                 %{path: ["tools:p", "tools:c"], graph_name: "coder", trigger_call_id: "tc-c"}
               ]
             }
           ] = transformer.log
  end

  test "nested nondeclared subagents are not surfaced" do
    {:ok, transformer, _handles} =
      StreamTransformer.process_many(transformer(), [
        tools_start(parent_task_id: "p", subagent_type: "researcher", tool_call_id: "tc-p"),
        child_start(["tools:p"]),
        tools_start(
          namespace: ["tools:p"],
          parent_task_id: "c",
          subagent_type: "plain_nested",
          tool_call_id: "tc-c"
        ),
        child_start(["tools:p", "tools:c"])
      ])

    assert [%{subagents: []}] = transformer.log
  end

  test "finalize completes dangling handles and fail marks open handles" do
    {:ok, transformer, _handles} =
      StreamTransformer.process_many(transformer(), [
        tools_start(parent_task_id: "x", subagent_type: "researcher", tool_call_id: "tc-1"),
        child_start(["tools:x"])
      ])

    assert [%{status: :completed}] =
             transformer |> StreamTransformer.finalize() |> Map.fetch!(:log)

    assert [%{status: :interrupted, error: nil}] =
             transformer
             |> StreamTransformer.fail(Error.new(:graph_interrupt, "pause"))
             |> Map.fetch!(:log)

    assert [%{status: :failed, error: "kaboom"}] =
             transformer
             |> StreamTransformer.fail(RuntimeError.exception("kaboom"))
             |> Map.fetch!(:log)
  end

  test "BeamWeaver typed envelopes are accepted in addition to protocol maps" do
    parent =
      Stream.envelope(%Events.Task{
        kind: :start,
        node: "tools",
        task_id: "abc",
        payload: %{
          input: [
            %{
              name: "task",
              id: "tc-1",
              args: %{subagent_type: "researcher", description: "from typed envelope"}
            }
          ]
        }
      })

    child =
      Stream.envelope(%Events.Task{kind: :start, node: "before_agent", task_id: "child"},
        namespace: ["tools:abc"]
      )

    {:ok, transformer, [%RunStream{}]} =
      StreamTransformer.process_many(transformer(), [
        parent,
        child,
        Stream.envelope(%Events.GraphValue{value: %{done: true}}, namespace: ["tools:abc"])
      ])

    assert [%{task_input: "from typed envelope", values: [%{done: true}]}] = transformer.log
  end

  defp transformer do
    StreamTransformer.new(subagent_names: ["researcher", "coder"])
  end

  defp tools_start(opts) do
    namespace = Keyword.get(opts, :namespace, [])
    parent_task_id = Keyword.fetch!(opts, :parent_task_id)
    subagent_type = Keyword.fetch!(opts, :subagent_type)
    tool_call_id = Keyword.fetch!(opts, :tool_call_id)
    description = Keyword.get(opts, :description)

    %{
      "type" => "event",
      "method" => "tasks",
      "params" => %{
        "namespace" => namespace,
        "data" => %{
          "id" => parent_task_id,
          "name" => "tools",
          "input" => [
            %{
              "name" => "task",
              "args" => %{
                "subagent_type" => subagent_type,
                "description" => description
              },
              "id" => tool_call_id
            }
          ],
          "triggers" => []
        }
      }
    }
  end

  defp child_start(namespace) do
    %{
      "type" => "event",
      "method" => "tasks",
      "params" => %{
        "namespace" => namespace,
        "data" => %{
          "id" => "child-task",
          "name" => "PatchToolCallsMiddleware.before_agent",
          "input" => nil,
          "triggers" => []
        }
      }
    }
  end

  defp parent_tasks_result(opts) do
    parent_task_id = Keyword.fetch!(opts, :parent_task_id)
    error = Keyword.get(opts, :error)
    interrupts = Keyword.get(opts, :interrupts, [])

    %{
      "type" => "event",
      "method" => "tasks",
      "params" => %{
        "namespace" => Keyword.get(opts, :namespace, []),
        "data" => %{
          "id" => parent_task_id,
          "name" => "tools",
          "error" => error,
          "interrupts" => interrupts,
          "result" => %{}
        }
      }
    }
  end

  defp values(payload, opts) do
    %{
      "type" => "event",
      "method" => "values",
      "params" => %{
        "namespace" => Keyword.fetch!(opts, :namespace),
        "data" => payload
      }
    }
  end
end
