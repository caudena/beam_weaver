Code.require_file("../../support/doc_snippets.exs", __DIR__)
Code.require_file("verify.exs", __DIR__)
BeamWeaver.Docs.Verify.main(System.argv())
