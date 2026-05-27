defmodule BeamWeaver.Agent.HITL do
  @moduledoc """
  Framework-agnostic human-in-the-loop review payload helpers.

  These helpers deliberately avoid any web/server dependency. Phoenix, LiveView,
  CLI, or custom applications can render the plain data returned here and pass
  decisions back through `BeamWeaver.Agent.resume_review/3`.
  """

  alias BeamWeaver.Core.Error

  defmodule ActionRequest do
    @moduledoc "JSON-safe action request for human review."
    defstruct [:name, args: %{}, description: nil]

    @type t :: %__MODULE__{
            name: String.t() | atom() | nil,
            args: map(),
            description: String.t() | nil
          }
  end

  defmodule ReviewConfig do
    @moduledoc "JSON-safe decision policy for a review action."
    defstruct [:action_name, allowed_decisions: [], args_schema: nil]

    @type t :: %__MODULE__{
            action_name: String.t() | atom() | nil,
            allowed_decisions: [atom() | String.t()],
            args_schema: map() | nil
          }
  end

  defmodule Review do
    @moduledoc "Review payload built from a graph interrupt."
    defstruct [
      :id,
      :namespace,
      :node,
      :task_id,
      :step,
      action_requests: [],
      review_configs: [],
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            namespace: [term()] | nil,
            node: atom() | String.t() | nil,
            task_id: String.t() | nil,
            step: non_neg_integer() | nil,
            action_requests: [BeamWeaver.Agent.HITL.ActionRequest.t()],
            review_configs: [BeamWeaver.Agent.HITL.ReviewConfig.t()],
            metadata: map()
          }
  end

  defmodule Decision do
    @moduledoc "Human review decision."
    defstruct [:type, :message, :edited_action]

    @type t :: %__MODULE__{
            type: atom() | String.t() | nil,
            message: String.t() | nil,
            edited_action: map() | nil
          }
  end

  @spec from_interrupt(map() | struct()) :: {:ok, Review.t()} | {:error, Error.t()}
  def from_interrupt(interrupt) when is_map(interrupt) do
    value = Map.get(interrupt, :value, Map.get(interrupt, "value", %{}))

    with {:ok, actions} <- fetch_list(value, :action_requests),
         {:ok, configs} <- fetch_list(value, :review_configs) do
      {:ok,
       %Review{
         id: Map.get(interrupt, :id, Map.get(interrupt, "id")),
         namespace: Map.get(interrupt, :namespace, Map.get(interrupt, "namespace", [])),
         node: Map.get(interrupt, :node, Map.get(interrupt, "node")),
         task_id: Map.get(interrupt, :task_id, Map.get(interrupt, "task_id")),
         step: Map.get(interrupt, :step, Map.get(interrupt, "step")),
         action_requests: Enum.map(actions, &action_request/1),
         review_configs: Enum.map(configs, &review_config/1),
         metadata: Map.get(interrupt, :metadata, Map.get(interrupt, "metadata", %{})) || %{}
       }}
    end
  end

  def from_interrupt(_interrupt),
    do: {:error, Error.new(:invalid_hitl_review, "expected an interrupt map")}

  @spec to_map(Review.t() | Decision.t() | ActionRequest.t() | ReviewConfig.t()) :: map()
  def to_map(%Review{} = review) do
    %{
      id: review.id,
      namespace: review.namespace || [],
      node: review.node,
      task_id: review.task_id,
      step: review.step,
      action_requests: Enum.map(review.action_requests, &to_map/1),
      review_configs: Enum.map(review.review_configs, &to_map/1),
      metadata: review.metadata || %{}
    }
    |> reject_nil_values()
  end

  def to_map(%ActionRequest{} = request) do
    %{name: request.name, args: request.args || %{}, description: request.description}
    |> reject_nil_values()
  end

  def to_map(%ReviewConfig{} = config) do
    %{
      action_name: config.action_name,
      allowed_decisions: config.allowed_decisions || [],
      args_schema: config.args_schema
    }
    |> reject_nil_values()
  end

  def to_map(%Decision{} = decision) do
    %{type: decision.type, message: decision.message, edited_action: decision.edited_action}
    |> reject_nil_values()
  end

  @spec resume_value([Decision.t() | map()] | map()) :: map()
  def resume_value(%{decisions: decisions}),
    do: %{decisions: Enum.map(decisions, &decision_map/1)}

  def resume_value(%{"decisions" => decisions}),
    do: %{decisions: Enum.map(decisions, &decision_map/1)}

  def resume_value(decisions) when is_list(decisions),
    do: %{decisions: Enum.map(decisions, &decision_map/1)}

  def decision(type, opts \\ []) do
    %Decision{
      type: type,
      message: Keyword.get(opts, :message),
      edited_action: Keyword.get(opts, :edited_action)
    }
  end

  defp action_request(%ActionRequest{} = request), do: request

  defp action_request(%{} = request) do
    %ActionRequest{
      name: Map.get(request, :name, Map.get(request, "name")),
      args: Map.get(request, :args, Map.get(request, "args", %{})) || %{},
      description: Map.get(request, :description, Map.get(request, "description"))
    }
  end

  defp review_config(%ReviewConfig{} = config), do: config

  defp review_config(%{} = config) do
    %ReviewConfig{
      action_name: Map.get(config, :action_name, Map.get(config, "action_name")),
      allowed_decisions: Map.get(config, :allowed_decisions, Map.get(config, "allowed_decisions", [])) || [],
      args_schema: Map.get(config, :args_schema, Map.get(config, "args_schema"))
    }
  end

  defp fetch_list(map, key) when is_map(map) do
    value = Map.get(map, key, Map.get(map, Atom.to_string(key), []))

    if is_list(value) do
      {:ok, value}
    else
      {:error, Error.new(:invalid_hitl_review, "#{key} must be a list")}
    end
  end

  defp fetch_list(_value, _key),
    do: {:error, Error.new(:invalid_hitl_review, "interrupt value must be a map")}

  defp decision_map(%Decision{} = decision), do: to_map(decision)
  defp decision_map(%{} = decision), do: decision

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
