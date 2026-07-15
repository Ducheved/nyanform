defmodule Nyanform.Transport.DownstreamStdio do
  alias Nyanform.Protocol.Message
  alias Nyanform.Session.Thread

  @spec run(
          Nyanform.Transport.UpstreamShrine.transport_config(),
          String.t(),
          atom(),
          keyword() | map()
        ) :: integer() | {:error, term()}
  def run(upstream_config, profile, policy, opts \\ [])

  def run(upstream_config, profile, policy, tool_filters) when is_map(tool_filters) do
    run(upstream_config, profile, policy, tool_filters: tool_filters)
  end

  def run(upstream_config, profile, policy, opts) when is_list(opts) do
    session_id = generate_session_id()
    tool_filters = Keyword.get(opts, :tool_filters, %{})

    max_message_size =
      Keyword.get(
        opts,
        :max_message_size,
        Application.get_env(:nyanform, :max_message_size, 1_048_576)
      )

    case Thread.initialize(session_id, upstream_config, profile, policy, tool_filters) do
      {:ok, _pid} ->
        start_proxy_loop(session_id, max_message_size)

      {:error, reason} ->
        IO.write(:stderr, "nyanform: upstream initialization failed: #{inspect(reason)}\n")
        {:error, reason}
    end
  end

  defp start_proxy_loop(session_id, max_message_size) do
    case Thread.subscribe_upstream(session_id, self()) do
      :ok ->
        {reader_pid, reader_ref} = start_stdin_reader()
        loop(session_id, max_message_size, reader_pid, reader_ref)

      {:error, reason} ->
        Thread.stop(session_id)
        {:error, reason}
    end
  end

  defp start_stdin_reader do
    parent = self()
    :erlang.spawn_opt(fn -> read_stdin(parent) end, [:link, :monitor])
  end

  defp read_stdin(parent) do
    case IO.read(:stdio, :line) do
      :eof ->
        send(parent, {:nyanform_stdin, self(), :eof})

      {:error, reason} ->
        send(parent, {:nyanform_stdin, self(), {:error, reason}})

      line ->
        send(parent, {:nyanform_stdin, self(), {:line, line}})
        read_stdin(parent)
    end
  end

  defp loop(session_id, max_message_size, reader_pid, reader_ref) do
    receive do
      {:nyanform_stdin, ^reader_pid, {:line, line}} ->
        handle_line(trim_line_ending(line), session_id, max_message_size)
        loop(session_id, max_message_size, reader_pid, reader_ref)

      {:nyanform_upstream, %Message{} = message} ->
        write_message(message)
        loop(session_id, max_message_size, reader_pid, reader_ref)

      {:nyanform_stdin, ^reader_pid, :eof} ->
        Process.demonitor(reader_ref, [:flush])
        Thread.sync_upstream(session_id)
        drain_upstream_messages()
        stop_session(session_id)
        0

      {:nyanform_stdin, ^reader_pid, {:error, reason}} ->
        IO.write(:stderr, "nyanform: stdin error: #{inspect(reason)}\n")
        Process.demonitor(reader_ref, [:flush])
        stop_session(session_id)
        1

      {:DOWN, ^reader_ref, :process, ^reader_pid, :normal} ->
        stop_session(session_id)
        0

      {:DOWN, ^reader_ref, :process, ^reader_pid, reason} ->
        IO.write(:stderr, "nyanform: stdin reader stopped: #{inspect(reason)}\n")
        stop_session(session_id)
        1
    end
  end

  defp stop_session(session_id) do
    Thread.unsubscribe_upstream(session_id, self())
    Thread.stop(session_id)
  end

  defp drain_upstream_messages do
    receive do
      {:nyanform_upstream, %Message{} = message} ->
        write_message(message)
        drain_upstream_messages()
    after
      0 -> :ok
    end
  end

  defp trim_line_ending(line) do
    line |> String.trim_trailing("\n") |> String.trim_trailing("\r")
  end

  defp handle_line(line, session_id, max_message_size) when byte_size(line) > 0 do
    case Message.parse(line, max_message_size) do
      {:ok, message} ->
        handle_message(message, session_id)

      {:error, {:parse_error, reason}} ->
        send_error(:parse_error, reason)

      {:error, {:message_too_large, size}} ->
        send_error(:message_too_large, size)
    end
  end

  defp handle_line(_empty, _session_id, _max_message_size), do: :ok

  defp handle_message(%Message{kind: :request} = message, session_id) do
    case Thread.handle_downstream(session_id, message) do
      {:reply, response} ->
        write_message(response)

      {:error, reason} ->
        error = Message.error_response(message.id, -32_603, "session error: #{inspect(reason)}")
        write_message(error)
    end
  end

  defp handle_message(%Message{kind: :notification} = message, session_id) do
    Thread.handle_downstream(session_id, message)
    :ok
  end

  defp handle_message(%Message{kind: :response} = message, session_id) do
    Thread.handle_downstream(session_id, message)
    :ok
  end

  defp handle_message(%Message{kind: :error} = message, session_id) do
    Thread.handle_downstream(session_id, message)
    :ok
  end

  defp write_message(%Message{} = message) do
    {:ok, encoded} = Message.encode(message)
    IO.write(:stdio, encoded <> "\n")
  end

  defp send_error(:parse_error, reason) do
    error = Message.error_response(nil, -32_700, "Parse error: #{reason}")
    write_message(error)
  end

  defp send_error(:message_too_large, size) do
    error = Message.error_response(nil, -32_700, "Message too large: #{size} bytes")
    write_message(error)
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
