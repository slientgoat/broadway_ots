defmodule CustomerExample do
  @moduledoc false

  alias Broadway.Message

  import Integer

  # called by Broadway.Processor
  def handle_message(_, message, _) do
    message
    |> Message.update_data(&process_data/1)
    |> put_batcher()
  end

  defp process_data(data) do
    # Do some calculations, generate a JSON representation, etc.
    #    PlainBuffer.deserialize_row(data.record)
    data.record
  end

  defp put_batcher(%Message{data: {_, [{_, v, _} | _]}} = message) when is_even(v) do
    Message.put_batcher(message, :sqs)
  end

  defp put_batcher(%Message{data: {_, [{_, v, _} | _]}} = message) when is_odd(v) do
    Message.put_batcher(message, :s3)
  end

  # called by Broadway.Consumer
  def handle_batch(:sqs, messages, _batch_info, _context) do
    IO.inspect(messages |> Enum.map(& &1.data), label: "length,#{length(messages)}-sqs")
    messages
    # Send batch of messages to SQS
  end

  def handle_batch(:s3, messages, _batch_info, _context) do
    IO.inspect(messages |> Enum.map(& &1.data), label: "length,#{length(messages)}-s3")

    messages
    # Send batch of messages to S3
  end
end
