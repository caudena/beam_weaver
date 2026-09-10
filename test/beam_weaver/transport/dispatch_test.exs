defmodule BeamWeaver.Transport.DispatchTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  test "cold native reducers stream chunks instead of falling back to a buffered request" do
    module =
      cold_transport(:Reducer, """
      def stream_reduce(_request, _opts, acc, reducer) do
        acc = Enum.reduce(["first", "second"], acc, fn chunk, acc -> reducer.(acc, chunk) end)
        {:ok, %BeamWeaver.Transport.Response{status: 200, body: ""}, acc}
      end
      """)

    request = Request.new(method: :get, url: "https://example.test")
    assert :code.is_loaded(module) == false

    assert {:ok, %Response{status: 200}, ["first", "second"]} =
             Transport.stream_reduce(module, request, [], [], fn chunks, chunk -> chunks ++ [chunk] end)
  end

  test "cold stream callbacks are detected before request fallback" do
    module =
      cold_transport(:Callback, """
      def stream(_request, _opts, on_chunk) do
        Enum.each(["first", "second"], on_chunk)
        {:ok, %BeamWeaver.Transport.Response{status: 200, body: ""}}
      end
      """)

    request = Request.new(method: :get, url: "https://example.test")
    assert :code.is_loaded(module) == false
    assert {:ok, %Response{status: 200}} = Transport.stream(module, request, [], &send(self(), {:chunk, &1}))
    assert_received {:chunk, "first"}
    assert_received {:chunk, "second"}
    refute_received {:chunk, "buffered"}
  end

  defp cold_transport(suffix, callback) do
    module = Module.concat(__MODULE__, suffix)
    path = Path.join(System.tmp_dir!(), "beam_weaver_cold_transport_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    source = """
    defmodule #{inspect(module)} do
      def request(_request, _opts), do: {:ok, %BeamWeaver.Transport.Response{status: 200, body: "buffered"}}
      #{callback}
    end
    """

    [{^module, binary}] = Code.compile_string(source)
    File.write!(Path.join(path, Atom.to_string(module) <> ".beam"), binary)
    Code.prepend_path(path)
    :code.purge(module)
    :code.delete(module)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      Code.delete_path(path)
      File.rm_rf!(path)
    end)

    module
  end
end
