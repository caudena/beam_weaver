defmodule BeamWeaver.Compaction.Semantic do
  @moduledoc """
  Structured, source-linked continuation state produced by portable compaction.

  The value has a closed schema for objectives, user requests, constraints,
  decisions, progress, critical context, errors, artifact references, and
  source coverage. Construction validates shape; the compaction engine also
  validates exact coverage, cited source IDs, direct-user excerpts, uniqueness,
  and the configured byte limit before returning a checkpoint.
  """

  alias BeamWeaver.Compaction.{Fields, Validator}
  alias BeamWeaver.Core.Error

  @fields [
    :version,
    :objective,
    :user_requests,
    :constraints,
    :decisions,
    :progress,
    :critical_context,
    :errors,
    :artifact_refs,
    :coverage
  ]
  @field_names Map.new(@fields, &{Atom.to_string(&1), &1})
  @bounds %{
    objective: 8,
    user_requests: 64,
    constraints: 64,
    decisions: 64,
    progress_completed: 128,
    progress_active: 64,
    progress_blocked: 64,
    progress_pending: 64,
    critical_context: 128,
    errors: 64,
    artifact_refs: 128,
    source_event_ids: 32,
    text_bytes: 4_000
  }

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @doc "Builds and shape-validates a closed semantic value."
  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = semantic), do: Validator.validate_shape(semantic)

  def new(%{} = attrs) do
    with {:ok, attrs} <- Fields.normalize(attrs, @field_names) do
      case Map.keys(attrs) -- @fields do
        [] ->
          {:ok, struct!(__MODULE__, attrs)}
          |> then(fn {:ok, semantic} -> Validator.validate_shape(semantic) end)

        unknown ->
          {:error, Error.new(:invalid_compaction_semantic, "unknown semantic fields", %{fields: unknown})}
      end
    else
      {:error, :duplicate_field} ->
        {:error, Error.new(:invalid_compaction_semantic, "semantic output has duplicate fields")}
    end
  rescue
    _error -> {:error, Error.new(:invalid_compaction_semantic, "required semantic fields are missing")}
  end

  def new(_attrs), do: {:error, Error.new(:invalid_compaction_semantic, "semantic output must be a map")}

  @doc "Converts semantic continuation state to its plain map representation."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = semantic), do: Map.from_struct(semantic)

  @doc "Returns the shared closed-schema collection and text bounds."
  @spec bounds() :: map()
  def bounds, do: @bounds

  @doc "Returns the authoritative top-level fields in canonical order."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "Returns the provider-neutral JSON Schema for the semantic contract."
  @spec json_schema() :: map()
  def json_schema do
    sourced = array_schema(sourced_schema(), @bounds.critical_context)

    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "additionalProperties" => false,
      "required" => Enum.map(@fields, &Atom.to_string/1),
      "properties" => %{
        "version" => %{"const" => 1},
        "objective" => array_schema(sourced_schema(), @bounds.objective),
        "user_requests" => array_schema(user_request_schema(), @bounds.user_requests),
        "constraints" => array_schema(sourced_schema(), @bounds.constraints),
        "decisions" => array_schema(decision_schema(), @bounds.decisions),
        "progress" => progress_schema(),
        "critical_context" => sourced,
        "errors" => array_schema(error_schema(), @bounds.errors),
        "artifact_refs" => array_schema(artifact_schema(), @bounds.artifact_refs),
        "coverage" =>
          closed_object(
            ["first_chat_seq", "last_chat_seq"],
            %{
              "first_chat_seq" => %{"type" => "integer", "minimum" => 1},
              "last_chat_seq" => %{"type" => "integer", "minimum" => 1}
            }
          )
      }
    }
  end

  defp sourced_schema do
    closed_object(["text", "source_event_ids"], %{
      "text" => text_schema(),
      "source_event_ids" => source_ids_schema(1)
    })
  end

  defp user_request_schema do
    closed_object(["source_event_id", "exact_excerpt", "secret_omission", "status"], %{
      "source_event_id" => uuid_schema(),
      "exact_excerpt" => %{"oneOf" => [text_schema(), %{"type" => "null"}]},
      "secret_omission" => %{
        "oneOf" => [
          closed_object(["class", "source_span_hash"], %{
            "class" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
            "source_span_hash" => hash_schema()
          }),
          %{"type" => "null"}
        ]
      },
      "status" => %{"enum" => ["active", "completed", "superseded"]}
    })
  end

  defp decision_schema do
    closed_object(["text", "rationale", "source_event_ids"], %{
      "text" => text_schema(),
      "rationale" => %{"oneOf" => [text_schema(), %{"type" => "null"}]},
      "source_event_ids" => source_ids_schema(1)
    })
  end

  defp progress_schema do
    item =
      closed_object(["text", "source_event_ids", "verification_event_ids"], %{
        "text" => text_schema(),
        "source_event_ids" => source_ids_schema(1),
        "verification_event_ids" => source_ids_schema(0)
      })

    closed_object(["completed", "active", "blocked", "pending"], %{
      "completed" => array_schema(item, @bounds.progress_completed),
      "active" => array_schema(item, @bounds.progress_active),
      "blocked" => array_schema(item, @bounds.progress_blocked),
      "pending" => array_schema(item, @bounds.progress_pending)
    })
  end

  defp error_schema do
    closed_object(["message", "status", "source_event_ids"], %{
      "message" => text_schema(),
      "status" => %{"enum" => ["open", "resolved"]},
      "source_event_ids" => source_ids_schema(1)
    })
  end

  defp artifact_schema do
    closed_object(["artifact_id", "purpose", "source_event_ids"], %{
      "artifact_id" => uuid_schema(),
      "purpose" => text_schema(),
      "source_event_ids" => source_ids_schema(1)
    })
  end

  defp source_ids_schema(minimum),
    do: %{
      "type" => "array",
      "minItems" => minimum,
      "maxItems" => @bounds.source_event_ids,
      "uniqueItems" => true,
      "items" => uuid_schema()
    }

  defp text_schema,
    do: %{"type" => "string", "minLength" => 1, "maxLength" => @bounds.text_bytes}

  defp uuid_schema,
    do: %{
      "type" => "string",
      "pattern" => "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    }

  defp hash_schema,
    do: %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"}

  defp array_schema(items, maximum),
    do: %{"type" => "array", "maxItems" => maximum, "items" => items}

  defp closed_object(required, properties),
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => properties
    }
end
