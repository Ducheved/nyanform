defmodule Nyanform.Protocol.Lifecycle do
  alias Nyanform.Protocol.Message

  @protocol_revision "2025-11-25"
  @previous_revision "2025-06-18"

  @spec supported_revisions :: [String.t()]
  def supported_revisions do
    [@protocol_revision, @previous_revision]
  end

  @spec negotiate_revision(String.t()) :: {:ok, String.t()} | {:error, :unsupported_revision}
  def negotiate_revision(requested) when requested in [@protocol_revision, @previous_revision] do
    {:ok, requested}
  end

  def negotiate_revision(_requested) do
    {:ok, @protocol_revision}
  end

  @spec build_initialize_result(String.t(), map()) :: map()
  def build_initialize_result(negotiated_revision, client_info) do
    %{
      "protocolVersion" => negotiated_revision,
      "capabilities" => server_capabilities(client_info),
      "serverInfo" => %{
        "name" => "nyanform",
        "version" => "0.1.0"
      }
    }
  end

  defp server_capabilities(_client_info) do
    %{
      "tools" => %{"listChanged" => true}
    }
  end

  @spec build_initialize_request(map()) :: Message.t()
  def build_initialize_request(client_info) do
    params = %{
      "protocolVersion" => @protocol_revision,
      "capabilities" => %{},
      "clientInfo" => client_info
    }

    Message.request(generate_id(), "initialize", params)
  end

  @spec generate_id :: String.t()
  def generate_id do
    :erlang.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end
end
