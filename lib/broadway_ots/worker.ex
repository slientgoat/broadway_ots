defmodule BroadwayOts.Worker do
  @moduledoc false

  use GenServer
  alias BroadwayOts.Channel

  alias ExAliyunOts.TableStoreTunnel.DescribeTunnelResponse
  alias ExAliyunOts.TableStoreTunnel.ConnectResponse
  alias ExAliyunOts.TableStoreTunnel.HeartbeatResponse
  alias ExAliyunOts.Const.Tunnel.ChannelStatus, as: W
  require ExAliyunOts.Const.Tunnel.ChannelStatus

  import ExAliyunOts.Client,
    only: [
      describe_tunnel: 2,
      connect_tunnel: 2,
      heartbeat: 2,
      shutdown_tunnel: 2
    ]

  @client_tag Mix.Project.config()[:app]
              |> Atom.to_string()
  @status_open W.open()
  @status_closing W.closing()
  @status_close W.close()
  @status_terminated W.terminated()

  @err_client_not_exist "OTSResourceGone [tunnelservice] client not exist"

  def channels_merge([], new),
    do:
      new
      |> Enum.filter(&(&1.status == @status_open))

  def channels_merge(old, new) do
    filter_old(old, new)
    |> change_status_to_close()
    |> Enum.concat(filter_new(old, new))
  end

  def start_link(tunnel_config, opt) do
    GenServer.start_link(__MODULE__, tunnel_config, name: Module.concat(Worker, opt[:id]))
  end

  def init(tunnel_config) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)

    worker_config =
      %{tunnel_id: nil, client_id: nil}
      |> Map.merge(tunnel_config)
      |> Map.put(:heartbeat_interval, tunnel_config.heartbeat_interval * 1000)

    state = %{working_channels: %{}, worker_config: worker_config}
    {:ok, state}
  end

  def handle_info(:connect, state) do
    %{worker_config: worker_config} = state
    {tunnel, client_id} = connect(worker_config)

    worker_config =
      Map.put(worker_config, :tunnel_id, tunnel.tunnel_id)
      |> Map.put(:client_id, client_id)

    send(self(), :heartbeat)
    {:noreply, %{state | worker_config: worker_config}}
  end

  # 一个producer 对应一个tunnel client
  # TODO heartbeat、readrecords，多个producer时考虑热点
  def handle_info(:heartbeat, %{worker_config: worker_config} = state) do
    heartbeat_interval = worker_config.heartbeat_interval
    channels = convert_to_channels(state.working_channels) |> Enum.map(&Map.to_list/1)

    opt = [
      channels: channels,
      tunnel_id: worker_config.tunnel_id,
      client_id: worker_config.client_id
    ]

    case heartbeat(worker_config.instance, opt) do
      {:ok, %HeartbeatResponse{channels: []}} ->
        Process.send_after(self(), :heartbeat, heartbeat_interval)
        {:noreply, state}

      {:ok, %HeartbeatResponse{channels: new_channels}} ->
        state = batch_update_channel_state_machine(state, new_channels)
        Process.send_after(self(), :heartbeat, heartbeat_interval)
        {:noreply, state}
      {:error, @err_client_not_exist} ->
        {:stop, :normal, state}
      {:error, reason} ->
        {:stop, inspect(reason), state}
    end
  end

  def handle_info({:EXIT, channel_pid, _reason}, state) do
    {identifier, _} = Enum.find(state.working_channels, fn {_k, v} -> v.pid == channel_pid end)
    working_channels = remove_channel_broadway(identifier, state.working_channels)
    {:noreply, %{state | working_channels: working_channels}}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def terminate(:normal, state) do
    :ok
  end

  def terminate(_reason, state) do
    shutdown(state.worker_config)
    :ok
  end

  defp connect(worker_config) do
    instance = worker_config.instance
    table_name = worker_config.table_name
    tunnel_name = worker_config.tunnel_name

    opt = [table_name: table_name, tunnel_name: tunnel_name]
    {:ok, %DescribeTunnelResponse{tunnel: tunnel}} = describe_tunnel(instance, opt)

    heartbeat_timeout = worker_config.heartbeat_timeout

    opt = [
      tunnel_id: tunnel.tunnel_id,
      timeout: heartbeat_timeout,
      client_tag: @client_tag
    ]

    {:ok, %ConnectResponse{client_id: client_id}} = connect_tunnel(instance, opt)

    {tunnel, client_id}
  end

  def shutdown(worker_config) do
    shutdown_tunnel(worker_config.instance,
      tunnel_id: worker_config.tunnel_id,
      client_id: worker_config.client_id
    )
  end

  @required_channel_config [:instance, :customer_module, :tunnel_id, :client_id]
  defp create_channel_broadway(channel, worker_config, working_channels) do
    channel_config =
      Map.take(worker_config, @required_channel_config)
      |> Map.put(:channel_id, channel.channel_id)

    {:ok, pid} = Channel.create(channel_config)
    Map.put(working_channels, channel.channel_id, %{info: channel, pid: pid})
  end

  defp remove_channel_broadway(identifier, working_channels) do
    {channel, rest} = Map.pop(working_channels, identifier)
    if channel != nil and Process.alive?(channel.pid), do: GenServer.stop(channel.pid)
    rest
  end

  defp batch_update_channel_state_machine(state, new_channels) do
    %{worker_config: worker_config, working_channels: working_channels} = state

    working_channels =
      convert_to_channels(working_channels)
      |> channels_merge(new_channels)
      |> do_batch_update(worker_config, working_channels)

    %{state | working_channels: working_channels}
  end

  defp do_batch_update([], _, working_channels), do: working_channels

  defp do_batch_update([%{status: status} = c | t], worker_config, working_channels)
       when status in [@status_close, @status_closing, @status_terminated] do
    working_channels = remove_channel_broadway(c.channel_id, working_channels)

    do_batch_update(t, worker_config, working_channels)
  end

  defp do_batch_update([%{status: status} = c | t], worker_config, working_channels)
       when status == @status_open do
    working_channels = create_channel_broadway(c, worker_config, working_channels)

    do_batch_update(t, worker_config, working_channels)
  end

  defp convert_to_channels(working_channels) do
    Enum.map(working_channels, &elem(&1, 1).info)
  end

  defp filter_new(old, new) do
    f = fn n ->
      o = Enum.find(old, fn o -> n.channel_id == o.channel_id end)

      if o == nil do
        n.status == @status_open
      else
        cond do
          n.version > o.version ->
            true

          n.version == o.version ->
            n.status != o.status

          true ->
            false
        end
      end
    end

    Enum.filter(new, f)
  end

  defp filter_old(old, new) do
    f = fn o ->
      n = Enum.find(new, fn n -> n.channel_id == o.channel_id end)

      if n == nil do
        o.status == @status_open
      else
        false
      end
    end

    Enum.filter(old, f)
  end

  defp change_status_to_close(old) do
    Enum.map(old, fn x -> %{x | status: @status_close, version: x.version + 1} end)
  end
end
