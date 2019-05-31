# BroadwayOts

  A AliyunOts Tunnel connector for Broadway.
  It allows developers to consume data efficiently from AliyunOts Tunnel according to define one or more instances.
  
## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `broadway_ots` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:broadway_ots, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/broadway_ots](https://hexdocs.pm/broadway_ots).


 ## Features
   - Automatically acknowledges messages.
   - Handles request data sources using backoff.
 ## Usage
 In order to use Tunnel, you need to:
   1. Define your instance configuration,you can see more in `ex_aliyun_ots/README.md`
   2. Define your tunnel configuration
   3. Define a customer module to process data
   4. Add it to your application's supervision tree
 ### Simple Example
 Here the simplest example to show how to use tunnel sdk.
 Please define required configuration in `your_project/configs/xxx.exs`,mostly like this:
 First, define your instance configuration
 ```elixir
 config :ex_aliyun_ots, MyInstance
   name: "MyInstanceName",
   endpoint: "MyInstanceEndpoint",
   access_key_id: "MyAliyunRAMKeyID",
   access_key_secret: "MyAliyunRAMKeySecret",
   pool_size: 100, # Optional
   pool_max_overflow: 20, # Optional
   tunnel: []
 config :ex_aliyun_ots,
   instances: [MyInstance],
   debug: false # Optional
 ```
 Second, define your tunnel configuration
 ```elixir
 config :broadway_ots,
   tunnels: [CustomerExample]
 config :broadway_ots, CustomerExample,
   tunnel_config: %{
     instance: EDCEXTestInstance,
     table_name: "pxy_test",
     tunnel_name: "add2"
   }
 ```
 Third,define a consumer module for process business logic of aliyunOts' records.
 like this:
  ```elixir
   defmodule CustomerExample do
     @moduledoc false
     alias Broadway.Message
     # called by Broadway.Processor
     def handle_message(_, message, _) do
       message
       |> Message.update_data(&process_data/1)
     end
     defp process_data(data) do
       # Do some calculations, generate a JSON representation, etc.
       data
     end
     # called by Broadway.Consumer
     def handle_batch(_batcher_key, messages, _batch_info, _context) do
       # do some batch operation
       messages
     end
   end
  ```
 ### Advanced Example
 Here the example to show how to use tunnel sdk with multi batcher_key.
 Please define required configuration in `your_project/configs/xxx.exs`
 First, the same as Simple Example
 Second, define your tunnel configuration, the batchers_config is optional,you can see more in `Broadway`'s Batchers options
 
 ```elixir
 config :broadway_ots,
   tunnels: [CustomerExample]
 config :broadway_ots, CustomerExample,
   tunnel_config: %{
     instance: EDCEXTestInstance,
     table_name: "pxy_test",
     tunnel_name: "add2",
     heartbeat_timeout: 30,
     heartbeat_interval: 10,
     worker_size: 2,
   },
   batchers_config: [
     sqs: [
       stages: 2,
       batch_size: 20
     ],
     s3: [
       stages: 1
     ]
   ]
 ```
 Third,define a consumer module for process business logic of aliyunOts' records.
 like this:
 
 ```elixir
   defmodule CustomerExample do
     @moduledoc false
   
     alias Broadway.Message
   
     import Integer
   
     # 被Broadway.Processor调用
     def handle_message(_, message, _) do
       message
       |> Message.update_data(&process_data/1)
       |> put_batcher()
     end
   
     defp process_data(data) do
       # Do some calculations, generate a JSON representation, etc.
       data
     end
   
     defp put_batcher(%Message{data: {_, [{_, v, _} | _]}} = message) when is_even(v) do
       Message.put_batcher(message, :sqs)
     end
   
     defp put_batcher(%Message{data: {_, [{_, v, _} | _]}} = message) when is_odd(v) do
       Message.put_batcher(message, :s3)
     end
   
     # 被Broadway.Consumer调用
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
 ```
 The advanced configuration above defines a pipeline with:
   * 1 instance
   * 2 worker(tunnel client with the same tunnel_id)
      * 1 producer
      * 2 processors
      * 1 batcher named `:sqs` with 2 consumers
      * 1 batcher named `:s3` with 1 consumer
 Here is how this pipeline would be represented:
 ```asciidoc
                             [instance]
                                / \
                               /   \
                              /     \
                             /       \
                       [worker_1] [worker_2]
                           |          .
                           |          .
                           |          .
                      [producer_1]
                          / \
                         /   \
                        /     \
                       /       \
              [processor_1] [processor_2]   <- process each message
                       /\     /\
                      /  \   /  \
                     /    \ /    \
                    /      x      \
                   /      / \      \
                  /      /   \      \
                 /      /     \      \
            [batcher_sqs]    [batcher_s3]
                 /\                  \
                /  \                  \
               /    \                  \
              /      \                  \
  [consumer_sqs_1] [consumer_sqs_2]  [consumer_s3_1] <- process each batch
 ```
 
 ## Tunnel's full configuration
 Include tunnel_config and batchers_config
  
 ### tunnel_config(Required)
   * `:instance` - Required. AliyunOts's Instacne
   * `:table_name` - Required. AliyunOts's Instance's table name
   * `:tunnel_name` - Required. AliyunOts's Instance's tunnel name
   * `:customer_module` - Required. The customer module name for consumer tunnel data
   * `:worker_size` - Optional. The tunnel client num with same tunnel name.default: 1
   * `:heartbeat_timeout` - Optional. The tunnel client heartbeat connect timeout.default: 300(second)
   * `:heartbeat_interval` - Optional. The tunnel client heartbeat interval.default: 30(second)
 ### batchers_config(Optional)
 Full detail,you can see `Batchers options` in the document of the `Broadway`