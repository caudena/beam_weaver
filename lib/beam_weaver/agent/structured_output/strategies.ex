defmodule BeamWeaver.Agent.StructuredOutput.AutoStrategy do
  @moduledoc """
  Strategy marker that lets BeamWeaver choose provider-native or tool-based structured output.
  """

  # `opts` keeps the declaration's `name`, `description`, `strict`,
  # `tool_message_content`, `handle_errors` and `max_retries`, so the strategy
  # the policy resolves to (provider or tool) is configured as declared.
  defstruct schema: nil, opts: []

  @type t :: %__MODULE__{schema: term(), opts: keyword()}
end

defmodule BeamWeaver.Agent.StructuredOutput.ToolStrategy do
  @moduledoc """
  Strategy that requests structured output through a synthetic tool call.

  With `handle_errors`, an answer that fails the schema goes back to the model
  as an error tool message, and the model answers again, up to `max_retries`
  times.
  """

  defstruct [:schema, :tool_message_content, handle_errors: true, max_retries: 2, schema_specs: []]

  @type t :: %__MODULE__{
          schema: term(),
          tool_message_content: String.t() | nil,
          handle_errors: boolean() | String.t() | atom() | [atom()] | (BeamWeaver.Core.Error.t() -> String.t()),
          max_retries: non_neg_integer(),
          schema_specs: [BeamWeaver.Agent.StructuredOutput.SchemaSpec.t()]
        }
end

defmodule BeamWeaver.Agent.StructuredOutput.ProviderStrategy do
  @moduledoc """
  Strategy that requests provider-native structured output.
  """

  defstruct [:schema, :schema_spec, strict: nil]

  @type t :: %__MODULE__{
          schema: term(),
          schema_spec: BeamWeaver.Agent.StructuredOutput.SchemaSpec.t() | nil,
          strict: boolean() | nil
        }
end

defmodule BeamWeaver.Agent.StructuredOutput.SchemaSpec do
  @moduledoc """
  Normalized schema metadata used by structured-output strategies.
  """

  defstruct [:schema, :name, :description, :json_schema, strict: nil]

  @type t :: %__MODULE__{
          schema: term(),
          name: String.t() | nil,
          description: String.t() | nil,
          json_schema: map() | nil,
          strict: boolean() | nil
        }
end
