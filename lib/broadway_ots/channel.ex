defmodule BroadwayOts.Channel do
  @moduledoc "管理tunnel的channel"

  use Broadway
  alias BroadwayOts.Producer
  @typedoc "The supervisor specification"
  @type channel_config :: %{
          required(:instance) => atom(),
          required(:customer_module) => atom(),
          required(:tunnel_id) => integer(),
          required(:client_id) => integer(),
          required(:channel_id) => integer()
        }

  @spec create(channel_config :: channel_config) :: {:ok, pid}
  def create(channel_config) do
    Broadway.start_link(
      __MODULE__,
      name: get_channel_identifier(channel_config),
      context: %{real_customer: channel_config.customer_module},
      producers: [
        default: [
          module: {Producer, channel_config},
          stages: 1
        ]
      ],
      processors: [
        default: []
      ],
      batchers: get_batchers_config(channel_config.customer_module)
    )
  end

  defp get_channel_identifier(channel_config) do
    Module.concat([Channel, channel_config.client_id])
  end

  def handle_message(processor_key, message, %{real_customer: customer_module} = context) do
    customer_module.handle_message(processor_key, message, context)
  end

  def handle_batch(batcher, messages, batch_info, %{real_customer: customer_module} = context) do
    customer_module.handle_batch(batcher, messages, batch_info, context)
  end

  defp default_batchers_config() do
    [
      default: []
    ]
  end

  @app_name Mix.Project.config()[:app]
  defp get_batchers_config(customer_module) do
    Application.get_env(@app_name, customer_module)[:batchers_config] || default_batchers_config()
  end
end
