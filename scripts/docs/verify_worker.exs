# One scenario, one VM. The parent never passes credentials in arguments or files.
[request_path, result_path] = System.argv()
Code.require_file("../../support/doc_snippets.exs", __DIR__)
ExUnit.start(autorun: false)
alias BeamWeaver.TestSupport.DocSnippets, as: Snippets
request = request_path |> File.read!() |> :erlang.binary_to_term()
Snippets.configure_live_providers!()
{:ok, _applications} = Application.ensure_all_started(:beam_weaver)
tmp = Path.join(Path.dirname(result_path), "tmp")
File.mkdir_p!(tmp)
System.put_env("TMPDIR", tmp)

results =
  Snippets.verify_blocks(request.blocks, request.page, request.services,
    package_verified: Map.get(request, :package_verified, false)
  )

# Test modules shown in a testing guide are executed, not just declared.
tests = ExUnit.run()

results =
  if tests.failures == 0,
    do: results,
    else:
      results ++
        [
          %{
            file: inspect(request.page),
            line: 1,
            status: "fail",
            reason: "#{tests.failures} documented ExUnit tests failed"
          }
        ]

File.write!(result_path, :erlang.term_to_binary(results))
