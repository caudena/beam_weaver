# Module groups for the HexDocs sidebar, read by `docs/0` in mix.exs. They
# follow the guide sections in docs/SUMMARY.md, with one group per provider.
# A module goes to the first group that lists it or matches its pattern;
# test/docs_lint_test.exs checks that every public module has a group.
[
  Agents: [
    BeamWeaver,
    BeamWeaver.Agent,
    BeamWeaver.Agent.Built,
    BeamWeaver.Agent.Schema,
    BeamWeaver.Agent.Usage,
    BeamWeaver.Agent.ProviderProfile,
    BeamWeaver.Schema,
    ~r/^BeamWeaver\.Agent\.StructuredOutput/
  ],
  Testing: [
    BeamWeaver.Models.FakeChatModel,
    BeamWeaver.Models.FakeEmbeddingModel,
    BeamWeaver.Filesystem.Conformance,
    BeamWeaver.Agent.Middleware.ToolEmulator,
    BeamWeaver.Provider.Replay,
    BeamWeaver.Transport.Cassette,
    BeamWeaver.Transport.Replay
  ],
  "Models and Messages": [
    BeamWeaver.Models,
    ~r/^BeamWeaver\.Models\./,
    BeamWeaver.Core.ChatModel,
    BeamWeaver.Core.EmbeddingModel,
    BeamWeaver.Core.DecisionModel,
    BeamWeaver.Core.LanguageModel,
    BeamWeaver.Core.LLM,
    BeamWeaver.Core.Message,
    ~r/^BeamWeaver\.Core\.Messages/,
    BeamWeaver.Core.ContentBlock,
    BeamWeaver.Core.Error,
    BeamWeaver.Core.ID,
    BeamWeaver.Tokenizer,
    ~r/^BeamWeaver\.Tokenizer\./,
    BeamWeaver.Config
  ],
  Tools: [
    BeamWeaver.Tool,
    ~r/^BeamWeaver\.Tool\./,
    BeamWeaver.Core.Tool,
    BeamWeaver.Core.ToolResult,
    BeamWeaver.Core.ToolRuntime,
    BeamWeaver.ToolKit,
    BeamWeaver.Tools.Todo,
    BeamWeaver.Tools.Subagents
  ],
  Middleware: [
    BeamWeaver.Agent.Middleware,
    BeamWeaver.Agent.ModelRequest,
    BeamWeaver.Agent.ModelResponse,
    BeamWeaver.Agent.ExtendedModelResponse,
    BeamWeaver.Agent.ToolCallRequest,
    ~r/^BeamWeaver\.Agent\.Middleware\.(ContextEditing|DynamicPrompt|ModelCallLimit|ModelFallback|ModelRetry|PII|StructuredOutputRetry|ToolCallLimit|ToolCallNormalization|ToolChoice|ToolError|ToolRetry|ToolSelection|UnsupportedMedia)/,
    BeamWeaver.RetryPolicy,
    BeamWeaver.RetryPredicates
  ],
  Streaming: [
    BeamWeaver.Stream,
    ~r/^BeamWeaver\.Stream\./
  ],
  "Memory and Context": [
    BeamWeaver.Memory,
    ~r/^BeamWeaver\.Memory\./,
    BeamWeaver.Core.ChatHistory,
    ~r/^BeamWeaver\.Core\.ChatHistory\./,
    BeamWeaver.Agent.Middleware.Memory,
    BeamWeaver.Agent.Middleware.Summarization,
    BeamWeaver.Agent.Middleware.CompactConversation,
    BeamWeaver.Agent.Middleware.OverflowRecovery,
    BeamWeaver.ContextBudget
  ],
  "Oversight and Safety": [
    BeamWeaver.Agent.HITL,
    ~r/^BeamWeaver\.Agent\.HITL\./,
    BeamWeaver.Agent.Middleware.HumanInTheLoop,
    ~r/^BeamWeaver\.Agent\.Middleware\.HumanInTheLoop\./,
    BeamWeaver.Agent.Middleware.AutoMode
  ],
  "Deep Agents": [
    BeamWeaver.Agent.Middleware.TodoList,
    BeamWeaver.Agent.Middleware.Filesystem,
    BeamWeaver.Agent.Middleware.Skills,
    BeamWeaver.Agent.Middleware.Subagents,
    BeamWeaver.Agent.Middleware.SubagentOutputs,
    BeamWeaver.Agent.Middleware.AsyncSubagents,
    BeamWeaver.Agent.Middleware.ShellTool,
    BeamWeaver.Agent.GeneralPurposeSubagentProfile,
    BeamWeaver.Agent.CapabilityProfile,
    BeamWeaver.Agent.CapabilityProfileConfig,
    ~r/^BeamWeaver\.Agent\.Subagent\./,
    ~r/^BeamWeaver\.Agent\.Protocol\./,
    BeamWeaver.Skill,
    BeamWeaver.Filesystem,
    ~r/^BeamWeaver\.Filesystem\./,
    BeamWeaver.Tools.Filesystem,
    BeamWeaver.Tools.FileSearch,
    BeamWeaver.Tools.Shell,
    ~r/^BeamWeaver\.Tools\.Shell\./,
    BeamWeaver.ShellPolicy,
    BeamWeaver.Sandbox,
    ~r/^BeamWeaver\.Sandbox\./
  ],
  Graphs: [
    BeamWeaver.Graph,
    ~r/^BeamWeaver\.Graph\./,
    BeamWeaver.Checkpoint,
    ~r/^BeamWeaver\.Checkpoint\./,
    BeamWeaver.ExecutionPolicy,
    BeamWeaver.TimeoutPolicy,
    BeamWeaver.Runnable
  ],
  Retrieval: [
    BeamWeaver.Core.Document,
    BeamWeaver.TextSplitter,
    BeamWeaver.VectorStore,
    ~r/^BeamWeaver\.VectorStore\./,
    BeamWeaver.Retriever,
    BeamWeaver.RetrievalPolicy,
    BeamWeaver.Indexing,
    ~r/^BeamWeaver\.Indexing\./,
    BeamWeaver.Prompt,
    ~r/^BeamWeaver\.Prompt\./,
    BeamWeaver.OutputParser,
    BeamWeaver.ExampleSelector
  ],
  Production: [
    BeamWeaver.Tracing,
    ~r/^BeamWeaver\.Tracing\./,
    BeamWeaver.Diagnostics,
    BeamWeaver.Cache,
    ~r/^BeamWeaver\.Cache\./,
    BeamWeaver.CachePolicy,
    BeamWeaver.PromptCache,
    BeamWeaver.Agent.Middleware.PromptCaching,
    BeamWeaver.RateLimiter,
    ~r/^BeamWeaver\.RateLimiter\./,
    BeamWeaver.RateLimitPolicy,
    BeamWeaver.Migrations,
    BeamWeaver.Serialization,
    ~r/^BeamWeaver\.Serialization\./,
    BeamWeaver.Adapter.Retainable,
    BeamWeaver.Adapter.Sweepable,
    BeamWeaver.Compaction,
    ~r/^BeamWeaver\.Compaction\./,
    BeamWeaver.Transport,
    ~r/^BeamWeaver\.Transport\./
  ],
  Providers: [
    ~r/^BeamWeaver\.Provider\./,
    ~r/^Mix\.Tasks\./
  ],
  OpenAI: [BeamWeaver.OpenAI, ~r/^BeamWeaver\.OpenAI\./],
  Anthropic: [BeamWeaver.Anthropic, ~r/^BeamWeaver\.Anthropic\./],
  "Google Gemini": [BeamWeaver.Google, ~r/^BeamWeaver\.Google\./],
  DeepSeek: [BeamWeaver.DeepSeek, ~r/^BeamWeaver\.DeepSeek\./],
  "Moonshot (Kimi)": [BeamWeaver.Moonshot, ~r/^BeamWeaver\.Moonshot\./],
  xAI: [BeamWeaver.XAI, ~r/^BeamWeaver\.XAI\./],
  "Z.ai": [BeamWeaver.ZAI, ~r/^BeamWeaver\.ZAI\./],
  TypeSafe: [
    BeamWeaver.TypeSafe,
    ~r/^BeamWeaver\.TypeSafe\./,
    BeamWeaver.Agent.Middleware.TypeSafeModelRouter
  ]
]
