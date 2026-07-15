defmodule Nyanform.Protocol.MessageTest do
  use ExUnit.Case, async: true

  alias Nyanform.Protocol.Message

  describe "parse" do
    test "parses a request" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}})
      assert {:ok, msg} = Message.parse(json, 1_048_576)
      assert msg.kind == :request
      assert msg.id == 1
      assert msg.method == "tools/list"
    end

    test "parses a notification" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/initialized"})
      assert {:ok, msg} = Message.parse(json, 1_048_576)
      assert msg.kind == :notification
      assert msg.id == nil
      assert msg.method == "notifications/initialized"
    end

    test "parses a response" do
      json = ~s({"jsonrpc":"2.0","id":2,"result":{"tools":[]}})
      assert {:ok, msg} = Message.parse(json, 1_048_576)
      assert msg.kind == :response
      assert msg.id == 2
      assert msg.result == %{"tools" => []}
    end

    test "parses an error response" do
      json = ~s({"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"not found"}})
      assert {:ok, msg} = Message.parse(json, 1_048_576)
      assert msg.kind == :error
      assert msg.error.code == -32_601
      assert msg.error.message == "not found"
    end

    test "rejects malformed JSON" do
      assert {:error, {:parse_error, _}} = Message.parse("not json", 1_048_576)
    end

    test "rejects non-object JSON" do
      assert {:error, {:parse_error, _}} = Message.parse("[1,2,3]", 1_048_576)
    end

    test "rejects oversized messages" do
      big = String.duplicate("x", 200)
      assert {:error, {:message_too_large, _}} = Message.parse(big, 100)
    end
  end

  describe "encode" do
    test "encodes a request round-trips" do
      msg = Message.request(42, "tools/call", %{"name" => "foo"})
      {:ok, json} = Message.encode(msg)
      assert {:ok, parsed} = Message.parse(json, 1_048_576)
      assert parsed.kind == :request
      assert parsed.id == 42
      assert parsed.method == "tools/call"
    end

    test "encodes a notification" do
      msg = Message.notification("notifications/cancelled", %{"id" => 1})
      {:ok, json} = Message.encode(msg)
      assert {:ok, parsed} = Message.parse(json, 1_048_576)
      assert parsed.kind == :notification
    end

    test "encodes an error response" do
      msg = Message.error_response(5, -32_601, "not found", %{"detail" => "x"})
      {:ok, json} = Message.encode(msg)
      assert {:ok, parsed} = Message.parse(json, 1_048_576)
      assert parsed.kind == :error
      assert parsed.error.data == %{"detail" => "x"}
    end
  end

  describe "predicates" do
    test "request? returns true for requests" do
      assert Message.request?(Message.request(1, "x"))
      refute Message.request?(Message.notification("x"))
    end

    test "notification? returns true for notifications" do
      assert Message.notification?(Message.notification("x"))
      refute Message.notification?(Message.request(1, "x"))
    end
  end
end
