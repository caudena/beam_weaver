defmodule BeamWeaver.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_weaver,
      version: "0.1.6",
      description:
        "Elixir-native LangChain, LangGraph, and DeepAgents for traceable LLM apps: OTP workflows, tools, memory, human-in-the-loop, streaming, custom clients/adapters, minimal deps, and WeaveScope tracing.",
      source_url: "https://github.com/caudena/beam_weaver",
      homepage_url: "https://github.com/caudena/beam_weaver",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      package: package(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :inets, :logger, :ssl],
      mod: {BeamWeaver.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.20"},
      {:req, "~> 0.6.1"},
      {:finch, "~> 0.23.0"},
      {:fastest_tiktoken, "~> 0.1.1"},
      {:telemetry, "~> 1.2"},
      {:yamerl, "~> 0.10.0"}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "master",
      source_url: "https://github.com/caudena/beam_weaver",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/getting_started.md",
        "docs/thinking_in_beamweaver.md",
        "docs/workflows_and_agents.md",
        "docs/persistence.md",
        "docs/memory.md",
        "docs/agent_harness.md",
        "docs/deep_agents_quickstart.md",
        "docs/customization.md",
        "docs/profiles.md",
        "docs/filesystem.md",
        "docs/permissions.md",
        "docs/skills.md",
        "docs/sandboxes.md",
        "docs/subagents.md",
        "docs/async_subagents.md",
        "docs/subgraphs.md",
        "docs/time_travel.md",
        "docs/durable_execution.md",
        "docs/fault_tolerance.md",
        "docs/semantic_dsl.md",
        "docs/agents.md",
        "docs/context_engineering.md",
        "docs/models.md",
        "docs/prompt_caching.md",
        "docs/messages.md",
        "docs/tools.md",
        "docs/middleware.md",
        "docs/custom_middleware.md",
        "docs/prebuilt_middleware.md",
        "docs/guardrails.md",
        "docs/human_in_the_loop.md",
        "docs/runtime.md",
        "docs/short_term_memory.md",
        "docs/long_term_memory.md",
        "docs/event_streaming.md",
        "docs/structured_output.md",
        "docs/graph.md",
        "docs/retrieval.md",
        "docs/prompts_parsers.md",
        "docs/adapters.md",
        "docs/core.md",
        "docs/partners.md",
        "docs/partners/openai.md",
        "docs/partners/anthropic.md",
        "docs/partners/google.md",
        "docs/partners/moonshot.md",
        "docs/partners/xai.md",
        "docs/partners/zai.md",
        "docs/replay.md",
        "docs/going_to_production.md",
        "docs/rate_limiting.md",
        "docs/tracing.md"
      ],
      groups_for_extras: [
        "Start Here": [
          "README.md",
          "CHANGELOG.md",
          "docs/getting_started.md",
          "docs/thinking_in_beamweaver.md",
          "docs/workflows_and_agents.md"
        ],
        Capabilities: [
          "docs/persistence.md",
          "docs/memory.md",
          "docs/agent_harness.md",
          "docs/deep_agents_quickstart.md",
          "docs/customization.md",
          "docs/profiles.md",
          "docs/filesystem.md",
          "docs/permissions.md",
          "docs/skills.md",
          "docs/sandboxes.md",
          "docs/subagents.md",
          "docs/async_subagents.md",
          "docs/subgraphs.md",
          "docs/time_travel.md",
          "docs/durable_execution.md",
          "docs/fault_tolerance.md",
          "docs/event_streaming.md"
        ],
        "Core Components": [
          "docs/semantic_dsl.md",
          "docs/agents.md",
          "docs/context_engineering.md",
          "docs/models.md",
          "docs/prompt_caching.md",
          "docs/messages.md",
          "docs/tools.md",
          "docs/middleware.md",
          "docs/custom_middleware.md",
          "docs/prebuilt_middleware.md",
          "docs/guardrails.md",
          "docs/human_in_the_loop.md",
          "docs/runtime.md",
          "docs/short_term_memory.md",
          "docs/long_term_memory.md",
          "docs/structured_output.md",
          "docs/graph.md"
        ],
        "Data And Retrieval": [
          "docs/retrieval.md",
          "docs/prompts_parsers.md",
          "docs/adapters.md",
          "docs/core.md"
        ],
        Partners: [
          "docs/partners.md",
          "docs/partners/openai.md",
          "docs/partners/anthropic.md",
          "docs/partners/google.md",
          "docs/partners/moonshot.md",
          "docs/partners/xai.md",
          "docs/partners/zai.md"
        ],
        Operations: [
          "docs/going_to_production.md",
          "docs/rate_limiting.md",
          "docs/replay.md",
          "docs/tracing.md"
        ]
      ],
      groups_for_modules: [
        "Core API": [
          BeamWeaver,
          BeamWeaver.Agent,
          BeamWeaver.Graph,
          BeamWeaver.Models,
          BeamWeaver.Core,
          BeamWeaver.Core.Message,
          BeamWeaver.Core.Tool,
          BeamWeaver.Core.ToolResult,
          BeamWeaver.Core.Error,
          BeamWeaver.Runnable
        ],
        "Agents And Middleware": [
          BeamWeaver.Agent.Builder,
          BeamWeaver.Agent.Built,
          BeamWeaver.Agent.Middleware,
          BeamWeaver.Agent.Middleware.TodoList,
          BeamWeaver.Agent.Middleware.Filesystem,
          BeamWeaver.Agent.Middleware.Skills,
          BeamWeaver.Agent.Middleware.Memory,
          BeamWeaver.Agent.Middleware.HumanInTheLoop,
          BeamWeaver.Agent.Middleware.Summarization,
          BeamWeaver.Agent.Middleware.ModelRetry,
          BeamWeaver.Agent.Middleware.ModelFallback,
          BeamWeaver.Agent.Middleware.ToolRetry,
          BeamWeaver.Agent.Middleware.ToolSelection,
          BeamWeaver.Agent.StructuredOutput,
          BeamWeaver.Agent.HITL
        ],
        "Graphs And Runtime": [
          BeamWeaver.Graph.StateGraph,
          BeamWeaver.Graph.Compiled,
          BeamWeaver.Graph.Command,
          BeamWeaver.Graph.Interrupt,
          BeamWeaver.Graph.Resume,
          BeamWeaver.Graph.Send,
          BeamWeaver.Graph.StateSnapshot,
          BeamWeaver.Graph.Channels.LastValue,
          BeamWeaver.Graph.Channels.Topic,
          BeamWeaver.Graph.Channels.BinaryOperatorAggregate,
          BeamWeaver.Graph.Channels.DeltaChannel,
          BeamWeaver.Runtime,
          BeamWeaver.Stream,
          BeamWeaver.Stream.Envelope,
          BeamWeaver.Stream.Events,
          BeamWeaver.Stream.Events.Token,
          BeamWeaver.Stream.Events.MessageChunk,
          BeamWeaver.Stream.Events.Message,
          BeamWeaver.Stream.Events.ToolCallChunk,
          BeamWeaver.Stream.Events.ToolStart,
          BeamWeaver.Stream.Events.ToolDelta,
          BeamWeaver.Stream.Events.ToolFinish,
          BeamWeaver.Stream.Events.ToolError,
          BeamWeaver.Stream.Events.GraphUpdate,
          BeamWeaver.Stream.Events.GraphValue,
          BeamWeaver.Stream.Events.Checkpoint,
          BeamWeaver.Stream.Events.Task,
          BeamWeaver.Stream.Events.Lifecycle,
          BeamWeaver.Stream.Events.Debug,
          BeamWeaver.Stream.Events.Custom,
          BeamWeaver.Stream.Events.Error,
          BeamWeaver.Stream.Events.Done
        ],
        "Memory, Storage, And Retrieval": [
          BeamWeaver.Checkpoint,
          BeamWeaver.Checkpoint.ETS,
          BeamWeaver.Checkpoint.Ecto,
          BeamWeaver.Memory,
          BeamWeaver.Memory.ETS,
          BeamWeaver.Memory.Ecto,
          BeamWeaver.Cache,
          BeamWeaver.Cache.ETS,
          BeamWeaver.Cache.Ecto,
          BeamWeaver.VectorStore,
          BeamWeaver.VectorStore.ETS,
          BeamWeaver.VectorStore.EctoPostgres,
          BeamWeaver.Indexing,
          BeamWeaver.Retriever,
          BeamWeaver.DocumentIndex
        ],
        "Models And Providers": [
          BeamWeaver.OpenAI,
          BeamWeaver.OpenAI.ChatModel,
          BeamWeaver.OpenAI.ResponsesModel,
          BeamWeaver.OpenAI.ChatCompletionsModel,
          BeamWeaver.OpenAI.EmbeddingModel,
          BeamWeaver.Anthropic,
          BeamWeaver.Anthropic.ChatModel,
          BeamWeaver.Google,
          BeamWeaver.Google.ChatModel,
          BeamWeaver.Google.Client,
          BeamWeaver.Google.Tools,
          BeamWeaver.Google.Error,
          BeamWeaver.XAI,
          BeamWeaver.XAI.ChatModel,
          BeamWeaver.XAI.ChatCompletionsModel,
          BeamWeaver.XAI.EmbeddingModel,
          BeamWeaver.ZAI,
          BeamWeaver.ZAI.ChatModel,
          BeamWeaver.ZAI.Client,
          BeamWeaver.ZAI.Tools,
          BeamWeaver.ZAI.Error,
          BeamWeaver.Models.FakeChatModel
        ],
        "Tools, Filesystems, And Sandboxes": [
          BeamWeaver.Tool,
          BeamWeaver.ToolKit,
          BeamWeaver.Tools.Todo,
          BeamWeaver.Tools.Filesystem,
          BeamWeaver.Tools.FileSearch,
          BeamWeaver.Tools.Shell,
          BeamWeaver.Filesystem,
          BeamWeaver.Filesystem.State,
          BeamWeaver.Filesystem.Local,
          BeamWeaver.Filesystem.LocalShell,
          BeamWeaver.Filesystem.Store,
          BeamWeaver.Filesystem.Composite,
          BeamWeaver.Filesystem.Sandbox,
          BeamWeaver.Filesystem.Permission,
          BeamWeaver.Sandbox,
          BeamWeaver.Sandbox.Local,
          BeamWeaver.Sandbox.Docker
        ],
        "Prompts, Parsing, And Serialization": [
          BeamWeaver.Prompt,
          BeamWeaver.OutputParser,
          BeamWeaver.OutputParser.JSON,
          BeamWeaver.OutputParser.XML,
          BeamWeaver.OutputParser.Schema,
          BeamWeaver.Tool.Schema,
          BeamWeaver.Serialization,
          BeamWeaver.Serialization.Encrypted,
          BeamWeaver.TextSplitter,
          BeamWeaver.Tokenizer
        ],
        Operations: [
          BeamWeaver.Tracing,
          BeamWeaver.Tracing.Exporter,
          BeamWeaver.Tracing.Exporters.Noop,
          BeamWeaver.RateLimiter,
          BeamWeaver.RateLimiter.TokenBucket,
          BeamWeaver.RetryPolicy,
          BeamWeaver.TimeoutPolicy,
          BeamWeaver.Transport,
          BeamWeaver.Transport.ReqFinch,
          BeamWeaver.Transport.Replay,
          BeamWeaver.Transport.Cassette
        ]
      ]
    ]
  end

  defp package do
    [
      name: "beam_weaver",
      files: [
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "docs",
        "examples",
        "lib",
        "mix.exs",
        "priv/openai"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://github.com/caudena/beam_weaver/blob/master/CHANGELOG.md",
        "GitHub" => "https://github.com/caudena/beam_weaver"
      }
    ]
  end
end
