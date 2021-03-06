defmodule GenMagic.Server do
  @moduledoc """
  Provides access to the underlying libmagic client, which performs file introspection.

  The Server needs to be supervised, since it will terminate if it receives any unexpected error.
  """

  @behaviour :gen_statem
  alias GenMagic.Result
  alias GenMagic.Server.Data
  alias GenMagic.Server.Status
  import Kernel, except: [send: 2]
  require Logger

  @typedoc """
  Represents the reference to the underlying server, as returned by `:gen_statem`.
  """
  @type t :: :gen_statem.server_ref()

  @typedoc """
  Represents values accepted as startup options, which can be passed to `start_link/1`.

  - `:name`: If present, this will be the registered name for the underlying process.
    Note that `:gen_statem` requires `{:local, name}`, but given widespread GenServer convention,
    atoms are accepted and will be converted to `{:local, name}`.

  - `:startup_timeout`: Specifies how long the Server waits for the C program to initialise.
    However, if the underlying C program exits, then the process exits immediately.

    Can be set to `:infinity`.

  - `:process_timeout`: Specifies how long the Server waits for each request to complete.

    Can be set to `:infinity`.

    Please note that, if you have chosen a custom timeout value, you should also pass it when
    using `GenMagic.Server.perform/3`.

  - `:recycle_threshold`: Specifies the number of requests processed before the underlying C
    program is recycled.

    Can be set to `:infinity` if you do not wish for the program to be recycled.

  - `:database_patterns`: Specifies what magic databases to load; you can specify a list of either
    Path Patterns (see `Path.wildcard/2`) or `:default` to instruct the C program to load the
    appropriate databases.

    For example, if you have had to add custom magics, then you can set this value to:

        [:default, "path/to/my/magic"]
  """
  @database_patterns [:default]
  @type option ::
          {:name, atom() | :gen_statem.server_name()}
          | {:startup_timeout, timeout()}
          | {:process_timeout, timeout()}
          | {:recycle_threshold, non_neg_integer() | :infinity}
          | {:database_patterns, nonempty_list(:default | Path.t())}

  @type target :: Path.t() | {:bytes, binary()}
  @type result :: {:ok, Result.t()} | {:error, term() | String.t()}

  @typedoc """
  Current state of the Server:

  - `:pending`: This is the initial state; the Server will attempt to start the underlying Port
    and the libmagic client, then automatically transition to either Available or Crashed.

  - `:available`: This is the default state. In this state the Server is able to accept requests
    and they will be replied in the same order.

  - `:processing`: This is the state the Server will be in if it is processing requests. In this
    state, further requests can still be lodged and they will be processed when the Server is
    available again.

    For proper concurrency, use a process pool like Poolboy, Sbroker, etc.

  - `:recycling`: This is the state the Server will be in, if its underlying C program needs to be
    recycled. This state is triggered whenever the cycle count reaches the defined value as per
    `:recycle_threshold`.

    In this state, the Server is able to accept requests, but they will not be processed until the
    underlying C server program has been started again.
  """
  @type state :: :starting | :processing | :available | :recycling

  @spec child_spec([option()]) :: Supervisor.child_spec()
  @spec start_link([option()]) :: :gen_statem.start_ret()
  @spec perform(t(), target(), timeout()) :: result()
  @spec status(t(), timeout()) :: {:ok, Status.t()} | {:error, term()}
  @spec stop(t(), term(), timeout()) :: :ok

  @doc """
  Returns the default Child Specification for this Server for use in Supervisors.

  You can override this with `Supervisor.child_spec/2` as required.
  """
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Starts a new Server.

  See `t:option/0` for further details.
  """
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)

    case name do
      nil -> :gen_statem.start_link(__MODULE__, options, [])
      name when is_atom(name) -> :gen_statem.start_link({:local, name}, __MODULE__, options, [])
      {:global, _} -> :gen_statem.start_link(name, __MODULE__, options, [])
      {:via, _, _} -> :gen_statem.start_link(name, __MODULE__, options, [])
      {:local, _} -> :gen_statem.start_link(name, __MODULE__, options, [])
    end
  end

  @doc """
  Determines the type of the file provided.
  """
  def perform(server_ref, path, timeout \\ 5000) do
    case :gen_statem.call(server_ref, {:perform, path}, timeout) do
      {:ok, %Result{} = result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reloads a Server with a new set of databases.
  """
  def reload(server_ref, database_patterns \\ nil, timeout \\ 5000) do
    :gen_statem.call(server_ref, {:reload, database_patterns}, timeout)
  end

  @doc """
  Same as `reload/2,3` but with a full restart of the underlying C port.
  """
  def recycle(server_ref, database_patterns \\ nil, timeout \\ 5000) do
    :gen_statem.call(server_ref, {:recycle, database_patterns}, timeout)
  end

  @doc """
  Returns status of the Server.
  """
  def status(server_ref, timeout \\ 5000) do
    :gen_statem.call(server_ref, :status, timeout)
  end

  @doc """
  Stops the Server with reason `:normal` and timeout `:infinity`.
  """
  def stop(server_ref) do
    :gen_statem.stop(server_ref)
  end

  @doc """
  Stops the Server with the specified reason and timeout.
  """
  def stop(server_ref, reason, timeout) do
    :gen_statem.stop(server_ref, reason, timeout)
  end

  @impl :gen_statem
  def init(options) do
    import GenMagic.Config

    data = %Data{
      port_name: get_port_name(),
      database_patterns: Keyword.get(options, :database_patterns, []),
      port_options: get_port_options(options),
      startup_timeout: get_startup_timeout(options),
      process_timeout: get_process_timeout(options),
      recycle_threshold: get_recycle_threshold(options)
    }

    {:ok, :starting, data}
  end

  @impl :gen_statem
  def callback_mode do
    [:state_functions, :state_enter]
  end

  @doc false
  def starting(:enter, _, %{port: nil} = data) do
    port = Port.open(data.port_name, data.port_options)
    {:keep_state, %{data | port: port}, data.startup_timeout}
  end

  @doc false
  def starting(:enter, _, data) do
    {:keep_state_and_data, data.startup_timeout}
  end

  @doc false
  def starting({:call, from}, :status, data) do
    handle_status_call(from, :starting, data)
  end

  @doc false
  def starting({:call, _from}, {:perform, _path}, _data) do
    {:keep_state_and_data, :postpone}
  end

  @doc false
  def starting(:info, {port, {:data, ready}}, %{port: port} = data) do
    case :erlang.binary_to_term(ready) do
      :ready -> {:next_state, :loading, data}
    end
  end

  @doc false
  def starting(:info, {port, {:exit_status, code}}, %{port: port} = data) do
    error =
      case code do
        1 -> :bad_db
        2 -> :ei_error
        3 -> :ei_bad_term
        code -> {:unexpected_error, code}
      end

    {:stop, {:error, error}, data}
  end

  @doc false
  def loading(:enter, _old_state, data) do
    databases =
      Enum.flat_map(List.wrap(data.database_patterns || @database_patterns), fn
        :default -> [:default]
        pattern -> Path.wildcard(pattern)
      end)

    databases =
      if databases == [] do
        [:default]
      else
        databases
      end

    {:keep_state, {databases, data}, {:state_timeout, 0, :load}}
  end

  @doc false
  def loading(:state_timeout, :load_timeout, {[database | _], data}) do
    {:stop, {:error, {:database_loading_timeout, database}}, data}
  end

  @doc false
  def loading(:state_timeout, :load, {[], data}) do
    {:next_state, :available, data}
  end

  @doc false
  def loading(:state_timeout, :load, {[database | databases], data} = state) do
    command =
      case database do
        :default -> {:add_default_database, nil}
        path -> {:add_database, database}
      end

    send(data.port, command)
    {:keep_state, state, {:state_timeout, data.startup_timeout, :load_timeout}}
  end

  @doc false
  def loading(:info, {port, {:data, response}}, {[database | databases], %{port: port} = data}) do
    case :erlang.binary_to_term(response) do
      {:ok, :loaded} ->
        {:keep_state, {databases, data}, {:state_timeout, 0, :load}}
    end
  end

  @doc false
  def loading(:info, {port, {:exit_status, 1}}, {[database | _], %{port: port} = data}) do
    {:stop, {:error, {:database_not_found, database}}, data}
  end

  @doc false
  def loading({:call, from}, :status, {[database | _], data}) do
    handle_status_call(from, :loading, data)
  end

  @doc false
  def loading({:call, _from}, {:perform, _path}, _data) do
    {:keep_state_and_data, :postpone}
  end

  @doc false
  def available(:enter, _old_state, %{request: {:reload, from, _}}) do
    response = {:reply, from, :ok}
    {:keep_state_and_data, response}
  end

  @doc false
  def available(:enter, _old_state, %{request: nil}) do
    :keep_state_and_data
  end

  @doc false
  def available({:call, from}, {:perform, path}, data) do
    data = %{data | cycles: data.cycles + 1, request: {path, from, :erlang.now()}}

    arg =
      case path do
        path when is_binary(path) -> {:file, path}
        {:bytes, bytes} -> {:bytes, bytes}
      end

    send(data.port, arg)
    {:next_state, :processing, data}
  end

  @doc false
  def available({:call, from}, {:reload, databases}, data) do
    send(data.port, {:reload, :reload})

    {:next_state, :starting,
     %{
       data
       | database_patterns: databases || data.database_patterns,
         request: {:reload, from, :reload}
     }}
  end

  @doc false
  def available({:call, from}, {:recycle, databases}, data) do
    {:next_state, :recycling,
     %{
       data
       | database_patterns: databases || data.database_patterns,
         request: {:reload, from, :recycle}
     }}
  end

  @doc false
  def available({:call, from}, :status, data) do
    handle_status_call(from, :available, data)
  end

  @doc false
  def processing(:enter, _old_state, %{request: {_path, _from, _time}} = data) do
    {:keep_state_and_data, data.process_timeout}
  end

  @doc false
  def processing({:call, _from}, {:perform, _path}, _data) do
    {:keep_state_and_data, :postpone}
  end

  @doc false
  def processing({:call, from}, :status, data) do
    handle_status_call(from, :processing, data)
  end

  @doc false
  def processing(:state_timeout, _, %{port: port, request: {_, from, _}} = data) do
    response = {:reply, from, {:error, :timeout}}
    {:next_state, :recycling, %{data | request: nil}, [response, :hibernate]}
  end

  @doc false
  def processing(:info, {port, {:data, response}}, %{port: port, request: {_, from, _}} = data) do
    response = {:reply, from, handle_response(response)}
    next_state = (data.cycles >= data.recycle_threshold && :recycling) || :available
    {:next_state, next_state, %{data | request: nil}, [response, :hibernate]}
  end

  @doc false
  def recycling(:enter, _, %{port: port} = data) when is_port(port) do
    send(data.port, {:stop, :recycle})
    {:keep_state_and_data, {:state_timeout, data.startup_timeout, :stop}}
  end

  @doc false
  def recycling({:call, _from}, {:perform, _path}, _data) do
    {:keep_state_and_data, :postpone}
  end

  @doc false
  def recycling({:call, from}, :status, data) do
    handle_status_call(from, :recycling, data)
  end

  @doc false
  # In case of timeout, force close.
  def recycling(:state_timeout, :stop, data) do
    Kernel.send(data.port, {self(), :close})
    {:keep_state_and_data, {:state_timeout, data.startup_timeout, :close}}
  end

  @doc false
  def recycling(:state_timeout, :close, data) do
    {:stop, {:error, :port_close_failed}}
  end

  @doc false
  def recycling(:info, {port, :closed}, %{port: port} = data) do
    {:next_state, :starting, %{data | port: nil, cycles: 0}}
  end

  @doc false
  def recycling(:info, {port, {:exit_status, _}}, %{port: port} = data) do
    {:next_state, :starting, %{data | port: nil, cycles: 0}}
  end

  @doc false
  @impl :gen_statem
  def terminate(_, _, %{port: port}) do
    Kernel.send(port, {self(), :close})
  end

  @doc false
  def terminate(_, _, _) do
    :ok
  end

  defp send(port, command) do
    Kernel.send(port, {self(), {:command, :erlang.term_to_binary(command)}})
  end

  @errnos %{
    2 => :enoent,
    13 => :eaccess,
    20 => :enotdir,
    12 => :enomem,
    24 => :emfile,
    36 => :enametoolong
  }
  @errno Map.keys(@errnos)

  defp handle_response(data) do
    case :erlang.binary_to_term(data) do
      {:ok, {mime_type, encoding, content}} -> {:ok, Result.build(mime_type, encoding, content)}
      {:error, {errno, _}} when errno in @errno -> {:error, @errnos[errno]}
      {:error, {errno, string}} -> {:error, "#{errno}: #{string}"}
      {:error, _} = error -> error
    end
  end

  defp handle_status_call(from, state, data) do
    response = {:ok, %__MODULE__.Status{state: state, cycles: data.cycles}}
    {:keep_state_and_data, {:reply, from, response}}
  end
end
