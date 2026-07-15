defmodule Nyanform.Protocol.Message do
  @type id :: integer() | String.t() | nil
  @type method :: String.t()

  @type t :: %__MODULE__{
          kind: :request | :response | :notification | :error,
          id: id() | nil,
          method: method() | nil,
          params: map() | nil,
          result: term() | nil,
          error: error() | nil,
          jsonrpc: String.t()
        }

  @type error :: %{
          code: integer(),
          message: String.t(),
          data: term() | nil
        }

  defstruct [
    :id,
    :method,
    :params,
    :result,
    :error,
    kind: :notification,
    jsonrpc: "2.0"
  ]

  @spec request(id(), method(), map()) :: t()
  def request(id, method, params \\ %{}) do
    %__MODULE__{kind: :request, id: id, method: method, params: params}
  end

  @spec response(id(), term()) :: t()
  def response(id, result) do
    %__MODULE__{kind: :response, id: id, result: result}
  end

  @spec error_response(id(), integer(), String.t(), term() | nil) :: t()
  def error_response(id, code, message, data \\ nil) do
    %__MODULE__{
      kind: :error,
      id: id,
      error: %{code: code, message: message, data: data}
    }
  end

  @spec notification(method(), map()) :: t()
  def notification(method, params \\ %{}) do
    %__MODULE__{kind: :notification, method: method, params: params}
  end

  @spec parse(binary(), pos_integer()) ::
          {:ok, t()} | {:error, {:parse_error, String.t()} | {:message_too_large, pos_integer()}}
  def parse(line, max_size) do
    if byte_size(line) > max_size do
      {:error, {:message_too_large, byte_size(line)}}
    else
      case Jason.decode(line) do
        {:ok, decoded} when is_map(decoded) ->
          parse_message(decoded)

        {:ok, _} ->
          {:error, {:parse_error, "JSON-RPC message must be an object"}}

        {:error, %Jason.DecodeError{} = error} ->
          {:error, {:parse_error, Exception.message(error)}}
      end
    end
  end

  defp parse_message(decoded) do
    jsonrpc = Map.get(decoded, "jsonrpc", "2.0")
    id = Map.get(decoded, "id")

    cond do
      Map.has_key?(decoded, "method") and is_binary(Map.get(decoded, "method")) ->
        parse_method_message(decoded, id, jsonrpc)

      Map.has_key?(decoded, "error") and is_map(Map.get(decoded, "error")) ->
        error = parse_error(Map.get(decoded, "error"))

        {:ok,
         %__MODULE__{
           kind: :error,
           id: id,
           error: error,
           jsonrpc: jsonrpc
         }}

      Map.has_key?(decoded, "result") ->
        {:ok,
         %__MODULE__{
           kind: :response,
           id: id,
           result: Map.get(decoded, "result"),
           jsonrpc: jsonrpc
         }}

      true ->
        {:error, {:parse_error, "message is neither request, response, nor notification"}}
    end
  end

  defp parse_method_message(decoded, id, jsonrpc) do
    method = Map.get(decoded, "method")
    params = Map.get(decoded, "params")

    if params != nil and not is_map(params) and not is_list(params) do
      {:error, {:parse_error, "params must be an object or array"}}
    else
      kind = if id == nil, do: :notification, else: :request
      {:ok, %__MODULE__{kind: kind, id: id, method: method, params: params, jsonrpc: jsonrpc}}
    end
  end

  defp parse_error(nil), do: nil

  defp parse_error(error) when is_map(error) do
    %{
      code: Map.get(error, "code", -1),
      message: Map.get(error, "message", "unknown error"),
      data: Map.get(error, "data")
    }
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = message) do
    Jason.encode(to_wire(message))
  end

  @spec encode!(t()) :: binary()
  def encode!(%__MODULE__{} = message) do
    Jason.encode!(to_wire(message))
  end

  defp to_wire(%__MODULE__{kind: :request} = msg) do
    base = %{"jsonrpc" => msg.jsonrpc, "id" => msg.id, "method" => msg.method}

    if msg.params != nil do
      Map.put(base, "params", msg.params)
    else
      base
    end
  end

  defp to_wire(%__MODULE__{kind: :notification} = msg) do
    base = %{"jsonrpc" => msg.jsonrpc, "method" => msg.method}

    if msg.params != nil do
      Map.put(base, "params", msg.params)
    else
      base
    end
  end

  defp to_wire(%__MODULE__{kind: :response} = msg) do
    %{"jsonrpc" => msg.jsonrpc, "id" => msg.id, "result" => msg.result}
  end

  defp to_wire(%__MODULE__{kind: :error} = msg) do
    error = %{"code" => msg.error.code, "message" => msg.error.message}

    error =
      if msg.error.data != nil do
        Map.put(error, "data", msg.error.data)
      else
        error
      end

    %{"jsonrpc" => msg.jsonrpc, "id" => msg.id, "error" => error}
  end

  @spec request?(t()) :: boolean()
  def request?(%__MODULE__{kind: :request}), do: true
  def request?(%__MODULE__{}), do: false

  @spec notification?(t()) :: boolean()
  def notification?(%__MODULE__{kind: :notification}), do: true
  def notification?(%__MODULE__{}), do: false

  @spec response?(t()) :: boolean()
  def response?(%__MODULE__{kind: :response}), do: true
  def response?(%__MODULE__{}), do: false

  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{kind: :error}), do: true
  def error?(%__MODULE__{}), do: false
end
