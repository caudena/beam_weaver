defmodule BeamWeaver.Prompt.PartialsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Prompt.Partials
  alias BeamWeaver.Prompt.StringTemplate

  test "validate_input accepts a partial variable supplied alongside the input" do
    prompt = %StringTemplate{
      template: "{greeting} {name}",
      partials: %{"greeting" => "Hi"},
      validate?: true
    }

    assert :ok = Partials.validate_input(prompt, %{"name" => "Ada", "greeting" => "Hello"})
  end

  test "validate_input still rejects genuinely unexpected variables" do
    prompt = %StringTemplate{template: "{name}", partials: %{}, validate?: true}

    assert {:error, %Error{type: :prompt_extra_variable}} =
             Partials.validate_input(prompt, %{"name" => "Ada", "bogus" => 1})
  end
end
