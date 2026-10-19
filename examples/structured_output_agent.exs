# Structured output: the agent looks the order up with a tool, then answers
# with a map that matches a schema, in `result.structured_response`.
#
#   mix run examples/structured_output_agent.exs

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.StructuredOutputAgent.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string, description: "The order id, like A-1001"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts),
    do: {:ok, "Order #{order_id} shipped on Monday with DHL and arrives in 2 days."}
end

defmodule BeamWeaver.Examples.StructuredOutputAgent.OrderStatus do
  use BeamWeaver.Schema

  title "order_status"
  strict true

  field :order_id, :string
  field :carrier, :string
  field :days_until_delivery, :integer
end

defmodule BeamWeaver.Examples.StructuredOutputAgent do
  use BeamWeaver.Agent

  model Support.model()
  system_prompt "You answer questions about orders. Look each order up with lookup_order."
  tools [BeamWeaver.Examples.StructuredOutputAgent.LookupOrder]
  response_schema BeamWeaver.Examples.StructuredOutputAgent.OrderStatus
end

{:ok, %{messages: messages, structured_response: status}} =
  BeamWeaver.Examples.StructuredOutputAgent.invoke(%{messages: ["Where is my order A-1001?"]})

IO.inspect(status, label: "structured_response")
%{"order_id" => "A-1001", "carrier" => "DHL", "days_until_delivery" => 2} = status
Support.assert_tools_called!(messages, [{"lookup_order", %{"order_id" => "A-1001"}}])
