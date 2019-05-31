defmodule BroadwayOts.Producer do
  @moduledoc """

    sdk implement by aliyun tunnel:

        * [tunnel sdk](https://help.aliyun.com/document_detail/107985.html?spm=a2c4g.11186623.4.1.34b41b50mN8eyX)

  """

  alias ExAliyunOts.TableStoreTunnel.CheckpointResponse
  alias ExAliyunOts.TableStoreTunnel.GetCheckpointResponse
  alias ExAliyunOts.TableStoreTunnel.ReadRecordsResponse
  alias Broadway.Message
  alias BroadwayOts.Backoff

  import ExAliyunOts.Client, only: [get_checkpoint: 2, read_records: 2, checkpoint: 2]

  @behaviour Broadway.Producer

  def init(channel_config) do
    state = %{
      instance: channel_config.instance,
      tunnel_id: channel_config.tunnel_id,
      client_id: channel_config.client_id,
      channel_id: channel_config.channel_id,
      customer_module: channel_config.customer_module,
      backoff: Backoff.new(),
      token: nil,
      sequence_number: nil
    }

    state = get_checkpoint(state)
    send(self(), :readrecords_schedule)
    {:producer, state}
  end

  defp get_checkpoint(state) do
    result =
      get_checkpoint(state.instance,
        tunnel_id: state.tunnel_id,
        client_id: state.client_id,
        channel_id: state.channel_id
      )

    case result do
      {:ok, %GetCheckpointResponse{checkpoint: checkpoint, sequence_number: seq}} ->
        %{state | token: checkpoint, sequence_number: seq}

      error ->
        raise ExAliyunOts.Error, "get_checkpoint error: #{inspect(error)}"
    end
  end

  # will be invoted by each processor
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end

  defp read_records(state) do
    result =
      read_records(state.instance,
        tunnel_id: state.tunnel_id,
        client_id: state.client_id,
        channel_id: state.channel_id,
        token: state.token
      )

    case result do
      {:ok, %ReadRecordsResponse{next_token: next_token, records: records}, size} ->
        {%{state | token: next_token}, records, size}

      error ->
        raise ExAliyunOts.Error, "read_records error: #{inspect(error)}"
    end
  end

  defp transformer(_, [], acc, acc2), do: {Enum.reverse(acc), acc2}

  defp transformer(token, [data | rest], acc, acc2) do
    ref = make_ref()
    ack = {__MODULE__, {self(), token}, :ok}
    acc = [%Message{data: data, acknowledger: ack, metadata: %{ref: ref}} | acc]
    acc2 = [ref | acc2]
    transformer(token, rest, acc, acc2)
  end

  @behaviour Broadway.Acknowledger

  # 被Broadway.Consumer调用
  @impl true
  def ack({pid, token}, successful, failed) do
    send(pid, {:ack, token, successful, failed})
  end

  # TODO 存在问题：
  #  processor 是否可以作为channel_connect?，固定间隔时间checkpoint？还是消费完毕后实时checkpoint？按批消费？如果允许多批同时消费，那么如果前面消费异常，则后面全部失效
  #  producer根据channels动态管理channel（CUD），同一channel，保证checkpoint有序
  #  消费端数据消费完，异常中断、导致tunnel数据位点没有更新。下次会出现再次取到上次业务层消费完的数据。结论：需要在消费端业务层做数据踢重处理
  # 每个channel进程，readrecords产生的数据可以被多个consumer进程同时处理，
  # consumer进程处理完成后会把处理结果返回给channel进程进行汇总，汇总结果没问题，然后进行下次readrecords
  def handle_info(:readrecords_schedule, %{backoff: backoff} = state) do
    {state, records, size} = read_records(state)
    {events, refs} = transformer(state.token, records, [], [])

    updated_backoff =
      if stream_full_data?(length(records), size) do
        Backoff.reset()
      else
        {next_backoff, sleep_ms} = Backoff.next_backoff_ms(backoff)
        Process.send_after(self(), :readrecords_schedule, sleep_ms)
        next_backoff
      end

    state = %{state | backoff: updated_backoff}
    Process.put(state.token, refs)
    {:noreply, events, state}
  end

  def handle_info({:ack, _token, _successful_messages, []} = ack, state) do
    state = do_checkpoint(ack, state)
    {:noreply, [], state}
  end

  def handle_info({:ack, _, _, failed_messages}, _state),
    do: raise(ExAliyunOts.Error, "consumer message error: #{inspect(failed_messages)}")

  def handle_info(_events, state) do
    {:noreply, [], state}
  end

  defp do_checkpoint({:ack, token, successful_messages, []}, state) do
    refs = Enum.reduce(successful_messages, [], fn x, acc -> [x.metadata.ref | acc] end)

    case Process.delete(token) -- refs do
      [_ | _] = rest_refs ->
        Process.put(token, rest_refs)
        state

      _ ->
        result =
          checkpoint(state.instance,
            tunnel_id: state.tunnel_id,
            client_id: state.client_id,
            channel_id: state.channel_id,
            checkpoint: state.token,
            sequence_number: state.sequence_number + 1
          )

        case result do
          {:ok, %CheckpointResponse{}} ->
            %{state | sequence_number: state.sequence_number + 1}

          error ->
            # TODO need to deal some error
            raise ExAliyunOts.Error, "checkpoint error: #{inspect(error)}"
        end
    end
  end

  @rpo_bar 500
  # 900 KB
  @rpo_size_bar 900 * 1024

  defp stream_full_data?(records_num, size) do
    records_num > @rpo_bar or size > @rpo_size_bar
  end

  #  defp check_sequence(instace, tunnel_id, client_id, channel_id) do
  #    result2 = get_checkpoint(instace, tunnel_id: tunnel_id, client_id: client_id, channel_id: channel_id)
  #
  #    case result2 do
  #      {:ok, %GetCheckpointResponse{sequence_number: sequence_number} = resp} ->
  #        {:ok, %{resp | sequence_number: sequence_number + 1}}
  #
  #      error ->
  #        error
  #    end
  #  end
end
