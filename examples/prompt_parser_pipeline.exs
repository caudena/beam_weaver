alias BeamWeaver.OutputParser
alias BeamWeaver.Prompt

prompt = Prompt.string("Return JSON for {topic}")
parser = OutputParser.json()

{:ok, _rendered} = Prompt.format(prompt, %{topic: "BeamWeaver"})
response = ~s({"topic":"beam"})
{:ok, %{"topic" => "beam"}} = OutputParser.parse(parser, response)

IO.puts("beam")
