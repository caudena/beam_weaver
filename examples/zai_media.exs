# GLM-5.3-Flash reads images, PDFs and video, each as a URL or as base64 data.
# This script draws a small PNG and sends it as base64, sends a public PDF and
# a public video by URL, and asks about each.
#
#   ZAI_API_KEY=... mix run examples/zai_media.exs

alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.ContentBlock
alias BeamWeaver.Core.Message

{:ok, model} = BeamWeaver.Models.init_chat_model("zai:glm-5.3-flash", reasoning_effort: :low, timeout: 120_000)

# A 16x16 red square as a PNG: the signature, then chunks of length, type, data and CRC.
chunk = fn type, data -> <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>> end
pixels = :binary.copy(<<0>> <> :binary.copy(<<255, 0, 0>>, 16), 16)

png =
  <<137, "PNG\r\n", 26, "\n">> <>
    chunk.("IHDR", <<16::32, 16::32, 8, 2, 0, 0, 0>>) <>
    chunk.("IDAT", :zlib.compress(pixels)) <> chunk.("IEND", "")

questions = [
  {"Image (base64)", ContentBlock.image(data: Base.encode64(png), mime_type: "image/png"),
   "What colour is this image? One word."},
  {"PDF (URL)",
   ContentBlock.file(
     url: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf",
     mime_type: "application/pdf"
   ), "What does this PDF say? One sentence."},
  {"Video (URL)", ContentBlock.video(url: "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4"),
   "What happens in this video? One sentence."}
]

for {label, block, question} <- questions do
  {:ok, reply} = ChatModel.invoke(model, [Message.user([block, ContentBlock.text(question)])])
  IO.puts("#{label}: #{Message.text(reply)}")

  expected =
    case label do
      "Image (base64)" -> "red"
      "PDF (URL)" -> "dummy"
      "Video (URL)" -> "flower"
    end

  true = String.contains?(String.downcase(Message.text(reply)), expected)
end
