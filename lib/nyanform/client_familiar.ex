defmodule Nyanform.ClientFamiliar do
  @type detection :: %{
          profile: String.t(),
          confidence: :known | :unknown,
          client_name: String.t() | nil,
          client_version: String.t() | nil
        }

  @spec detect(map() | nil) :: detection()
  def detect(nil) do
    %{profile: "canonical", confidence: :unknown, client_name: nil, client_version: nil}
  end

  def detect(%{"name" => name} = client_info) do
    version = Map.get(client_info, "version")

    case classify(name) do
      {:known, profile} ->
        %{profile: profile, confidence: :known, client_name: name, client_version: version}

      :unknown ->
        %{profile: "canonical", confidence: :unknown, client_name: name, client_version: version}
    end
  end

  def detect(_client_info) do
    %{profile: "canonical", confidence: :unknown, client_name: nil, client_version: nil}
  end

  @client_patterns [
    {"claude", "claude"},
    {"cline", "claude"},
    {"cursor", "openai_strict"},
    {"continue", "openai_strict"},
    {"openai", "openai_strict"},
    {"gemini", "gemini"},
    {"vscode", "vscode"},
    {"vs code", "vscode"}
  ]

  defp classify(name) when is_binary(name) do
    lower = String.downcase(name)

    Enum.find_value(@client_patterns, :unknown, fn {pattern, profile} ->
      if String.contains?(lower, pattern), do: {:known, profile}
    end)
  end

  defp classify(_), do: :unknown

  @spec resolve(String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def resolve("auto", client_info) do
    detection = detect(client_info)
    {:ok, detection.profile}
  end

  def resolve(profile, _client_info) when is_binary(profile) do
    {:ok, profile}
  end
end
