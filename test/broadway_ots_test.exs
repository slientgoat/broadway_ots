defmodule BroadwayOtsTest do
  use ExUnit.Case
  doctest BroadwayOts

  alias ExAliyunOts.TableStoreTunnel.Channel, as: C
  alias ExAliyunOts.Const.Tunnel.ChannelStatus, as: W
  require ExAliyunOts.Const.Tunnel.ChannelStatus

  def remote_source() do
    [
      %C{channel_id: "id0", version: 1, status: W.close()},
      %C{channel_id: "id1", version: 1, status: W.open()},
      %C{channel_id: "id2", version: 1, status: W.open()},
      %C{channel_id: "id3", version: 1, status: W.open()},
      %C{channel_id: "version_become_smaller", version: 2, status: W.open()},
      %C{channel_id: "same_version", version: 2, status: W.open()},
      %C{channel_id: "same_version_and_status", version: 2, status: W.open()}
    ]
  end

  def working() do
    [
      %C{channel_id: "id1", version: 1, status: W.open()},
      %C{channel_id: "id2", version: 1, status: W.open()},
      %C{channel_id: "id3", version: 1, status: W.open()},
      %C{channel_id: "version_become_smaller", version: 2, status: W.open()},
      %C{channel_id: "same_version", version: 2, status: W.open()},
      %C{channel_id: "same_version_and_status", version: 2, status: W.open()}
    ]
  end

  def changed() do
    [
      %C{channel_id: "id2", version: 2, status: W.open()},
      %C{channel_id: "id3", version: 2, status: W.closing()},
      %C{channel_id: "id4", version: 1, status: W.open()},
      %C{channel_id: "id5", version: 1, status: W.close()},
      %C{channel_id: "id6", version: 1, status: W.terminated()},
      %C{channel_id: "version_become_smaller", version: 1, status: W.terminated()},
      %C{channel_id: "same_version", version: 2, status: W.close()},
      %C{channel_id: "same_version_and_status", version: 2, status: W.open()}
    ]
  end

  def merged() do
    [
      %C{channel_id: "id1", version: 1 + 1, status: W.close()},
      %C{channel_id: "id2", version: 2, status: W.open()},
      %C{channel_id: "id3", version: 2, status: W.closing()},
      %C{channel_id: "id4", version: 1, status: W.open()},
      %C{channel_id: "same_version", version: 2, status: W.close()}
    ]
  end

  test "channel merge logic" do
    r = BroadwayOts.Worker.channels_merge([], remote_source())
    assert r == working()
    r2 = BroadwayOts.Worker.channels_merge(working(), changed())
    assert Enum.sort(r2) == Enum.sort(merged())
  end
end
