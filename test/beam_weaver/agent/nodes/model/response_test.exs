defmodule BeamWeaver.Agent.Nodes.Model.ResponseTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.Nodes.Model.Response
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Overwrite

  # Saves the thread as a summary of all but its newest message.
  defmodule Rewrite do
    use BeamWeaver.Agent.Middleware

    def wrap_model_call(_middleware, request, handler) do
      {:ok, response} = Response.normalize_model_result(handler.(request))
      kept = List.last(BeamWeaver.Agent.State.messages(request.state))

      %ExtendedModelResponse{
        model_response: response,
        command: %Command{update: %{messages: Overwrite.new([Message.user("Summary.", id: "summary"), kept])}}
      }
    end
  end

  # Saves a note with the reply, and an edit of each message of the thread.
  defmodule Annotate do
    use BeamWeaver.Agent.Middleware

    def wrap_model_call(_middleware, request, handler) do
      {:ok, response} = Response.normalize_model_result(handler.(request))
      edits = for message <- BeamWeaver.Agent.State.messages(request.state), do: %{message | content: "Edited."}

      %ExtendedModelResponse{
        model_response: response,
        command: %Command{update: %{messages: edits ++ [Message.user("Note.", id: "note")]}}
      }
    end
  end

  describe "to_update/2 with a message overwrite" do
    test "applies the response's other message writes to the new thread" do
      kept = Message.user("Kept.", id: "kept")
      summary = Message.user("Summary.", id: "summary")
      reply = Message.assistant("Reply.", id: "reply")

      response = %ModelResponse{
        messages: [reply],
        commands: [
          %Command{
            update: %{
              messages: [
                %{kept | content: "Kept, edited."},
                Message.user("Edited.", id: "old"),
                Message.user("Note.", id: "note")
              ],
              files: %{"/notes.md" => "x"}
            }
          },
          %Command{update: %{messages: Overwrite.new([summary, kept])}}
        ]
      }

      assert [%Command{update: %{messages: overwrite}}, base, %Command{update: other}] =
               Response.to_update(response, thread: [Message.user("Old.", id: "old"), kept])

      # The kept message takes its edit, the note is added, and the message
      # the overwrite removed stays removed.
      assert {:ok, messages} = Overwrite.get(overwrite)

      assert Enum.map(messages, &{&1.id, Message.text(&1)}) == [
               {"summary", "Summary."},
               {"kept", "Kept, edited."},
               {"note", "Note."},
               {"reply", "Reply."}
             ]

      refute Map.has_key?(base, :messages)
      assert other == %{files: %{"/notes.md" => "x"}}
    end
  end

  test "a middleware's messages saved with a reply survive another middleware rewriting the thread" do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: %BeamWeaver.Models.FakeChatModel{response: "Reply."},
        middleware: [Rewrite, Annotate]
      )

    assert {:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Old.", "First."]})

    # "Old." is summarized away, so its edit is dropped with it.
    assert Enum.map(result.messages, &Message.text/1) == ["Summary.", "Edited.", "Note.", "Reply."]
  end

  describe "attach_diagnostics/5 content clipping" do
    test "truncated multibyte content stays valid UTF-8 and serializable" do
      {details, content} = diagnosed("x" <> String.duplicate("é", 8_000))

      assert String.valid?(content)
      assert String.starts_with?(content, "xé")
      assert content =~ "truncated"
      assert {:ok, _encoded} = BeamWeaver.Serialization.dump_value(details)
    end

    test "ascii content under the limit is preserved unchanged" do
      assert {_details, "hello world"} = diagnosed("hello world")
    end
  end

  defp diagnosed(text) do
    message = Message.assistant(text)
    request = ModelRequest.new(model: "test-model", messages: [message])
    %Error{details: details} = Response.attach_diagnostics(Error.new(:model_error, "boom"), request, [message], [])
    {details, details.model_request.messages |> hd() |> Map.fetch!(:content)}
  end
end
