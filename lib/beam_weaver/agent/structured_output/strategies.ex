defmodule BeamWeaver.Agent.StructuredOutput.AutoStrategy do
  @moduledoc false
  defstruct [:schema]

  @type t :: %__MODULE__{schema: term()}
end

defmodule BeamWeaver.Agent.StructuredOutput.ToolStrategy do
  @moduledoc false
  defstruct [:schema, :tool_message_content, handle_errors: true, schema_specs: []]

  @type t :: %__MODULE__{
          schema: term(),
          tool_message_content: String.t() | nil,
          handle_errors: boolean(),
          schema_specs: [BeamWeaver.Agent.StructuredOutput.SchemaSpec.t()]
        }
end

defmodule BeamWeaver.Agent.StructuredOutput.ProviderStrategy do
  @moduledoc false
  defstruct [:schema, :schema_spec, strict: nil]

  @type t :: %__MODULE__{
          schema: term(),
          schema_spec: BeamWeaver.Agent.StructuredOutput.SchemaSpec.t() | nil,
          strict: boolean() | nil
        }
end

defmodule BeamWeaver.Agent.StructuredOutput.SchemaSpec do
  @moduledoc false
  defstruct [:schema, :name, :description, :json_schema, strict: nil]

  @type t :: %__MODULE__{
          schema: term(),
          name: String.t() | nil,
          description: String.t() | nil,
          json_schema: map() | nil,
          strict: boolean() | nil
        }
end
