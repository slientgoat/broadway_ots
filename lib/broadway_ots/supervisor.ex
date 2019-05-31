defmodule BroadwayOts.Supervisor do
  @moduledoc false

  alias BroadwayOts.Worker

  use Supervisor

  @typedoc "The supervisor specification"
  @type tunnel_config :: %{
          required(:instance) => atom(),
          required(:table_name) => binary(),
          required(:tunnel_name) => binary(),
          required(:customer_module) => atom(),
          optional(:worker_size) => integer(),
          optional(:index) => integer(),
          optional(:heartbeat_timeout) => integer(),
          optional(:heartbeat_interval) => integer()
        }

  @app_name Mix.Project.config()[:app]

  def specs() do
    tunnels = Application.get_env(@app_name, :tunnels, [])
    Enum.map(tunnels, &build_worker_spec/1)
  end

  @doc """
  Starts a tunnel client linked to the current process.
  """
  @spec start_link(arg :: tunnel_config, GenServer.Option) :: Supervisor.on_start()
  def start_link(arg, opt) do
    Supervisor.start_link(__MODULE__, arg, opt)
  end

  defp build_worker_spec(customer_module) do
    tunnel_config =
      Application.get_env(@app_name, customer_module)[:tunnel_config]
      |> tunnel_config_validate()

    default_tunnel_config(customer_module)
    |> Map.merge(tunnel_config)
    |> supervisor_spec()
  end

  @required_options [:instance, :table_name, :tunnel_name]
  defp tunnel_config_validate(tunnel_config) do
    keys = Map.keys(tunnel_config)

    case @required_options -- keys do
      [] ->
        tunnel_config

      r ->
        raise ExAliyunOts.Error,
              "tunnel_config_validate error: options #{inspect(r)} are required"
    end
  end

  defp default_tunnel_config(customer_module) do
    %{
      customer_module: customer_module,
      heartbeat_timeout: 300,
      heartbeat_interval: 30,
      worker_size: 1,
      index: 1
    }
  end

  @impl true
  def init(tunnel_config) do
    children = worker_spec(tunnel_config)
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp supervisor_spec(tunnel_config) do
    id = gen_supervisor_name(tunnel_config)

    %{
      id: id,
      start: {__MODULE__, :start_link, [tunnel_config, [name: Module.concat(__MODULE__, id)]]}
    }
  end

  defp gen_supervisor_name(tunnel_config) do
    instance = tunnel_config.instance
    "#{instance}_#{tunnel_config.table_name}_#{tunnel_config.tunnel_name}"
  end

  def worker_spec(tunnel_config) do
    worker_size = tunnel_config.worker_size

    f = fn x ->
      id = gen_id(tunnel_config, x)
      tunnel_config = %{tunnel_config | index: x}

      %{
        id: id,
        start: {Worker, :start_link, [tunnel_config, [id: id]]},
        type: :worker
      }
    end

    Enum.map(1..worker_size, f)
  end

  defp gen_id(tunnel_config, x) do
    "#{gen_supervisor_name(tunnel_config)}_#{x}"
  end
end
