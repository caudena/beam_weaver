defmodule BeamWeaver.TestSupport.Conformance.LLMCase do
  @moduledoc """
  Shared ExUnit checks for `BeamWeaver.Core.LLM` implementations.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Async
      alias BeamWeaver.Core.LanguageModel
      alias BeamWeaver.Core.LLM
      alias BeamWeaver.TestSupport.Conformance.Subject

      @beamweaver_subject Subject.new(opts, :llm)

      test "LLM returns a non-empty text completion" do
        model = build_subject()

        assert {:ok, completion} = LLM.complete(model, fixture(:prompt))
        assert is_binary(completion)
        assert completion != ""
      end

      test "LLM rejects non-string prompts before provider code runs" do
        model = build_subject()

        assert {:error, error} = LLM.complete(model, {:not, :a, :prompt})
        assert error.type == :invalid_prompt
      end

      test "LLM async API returns a text completion" do
        model = build_subject()

        assert {:ok, completion} =
                 model
                 |> LLM.async_complete(fixture(:prompt))
                 |> Async.await()

        assert is_binary(completion)
      end

      if Subject.capability?(@beamweaver_subject, :batch) do
        test "LLM async batch preserves ordered completions" do
          model = build_subject()

          handles = LLM.async_batch(model, ["first", "second"])
          assert [{:ok, first}, {:ok, second}] = Async.await_batch(handles)
          assert first =~ "first"
          assert second =~ "second"
        end
      end

      if Subject.capability?(@beamweaver_subject, :streaming) do
        test "LLM stream returns an enumerable of text chunks" do
          model = build_subject()

          assert {:ok, stream} = model.__struct__.stream(model, fixture(:prompt), [])
          assert Enum.join(stream) != ""
        end
      end

      if Subject.capability?(@beamweaver_subject, :standard_params) do
        test "LLM accepts declared standard params and forwards them to provider boundary" do
          model = build_subject()
          opts = fixture(:standard_param_opts, temperature: 0.1)

          assert {:ok, completion} = LLM.complete(model, fixture(:prompt), opts)
          assert completion != ""

          if fixture(:assert_forwarded_opts?, false) do
            assert_received {:fake_llm_call, _prompt, forwarded_opts}

            for {key, value} <- opts do
              assert Keyword.get(forwarded_opts, key) == value
            end
          end
        end
      end

      if Subject.capability?(@beamweaver_subject, :env_config_init) do
        test "LLM can be initialized from explicit env/config helper when supported" do
          {group, key, config_value} =
            fixture(:config, {:test_support, :fake_llm_prefix, "env llm"})

          BeamWeaver.TestSupport.ConfigHelper.merge_config(group, [{key, config_value}])

          model = fixture(:env_builder).()

          assert {:ok, completion} = LLM.complete(model, fixture(:prompt))
          assert completion =~ config_value
        end
      end

      if Subject.capability?(@beamweaver_subject, :exact_tokenizer) do
        test "LLM token counting uses an explicit tokenizer callback when available" do
          model = build_subject()

          assert {:ok, fixture(:expected_token_count, 2)} ==
                   LanguageModel.count_tokens(model, "hello world")
        end
      end

      if Subject.capability?(@beamweaver_subject, :param_validation) do
        test "LLM validates unsupported params when provider opts are checked" do
          model = build_subject()

          assert {:error, error} = LLM.complete(model, fixture(:prompt), temperature: 0.9)
          assert error.type == :unsupported_model_param
        end
      end

      defp build_subject, do: Subject.build(@beamweaver_subject)
      defp fixture(key, default \\ nil), do: Subject.fixture(@beamweaver_subject, key, default)
    end
  end
end
