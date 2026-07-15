defmodule Nyanform.Protocol.ErrorCodes do
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  @spec parse_error :: integer()
  def parse_error, do: @parse_error

  @spec invalid_request :: integer()
  def invalid_request, do: @invalid_request

  @spec method_not_found :: integer()
  def method_not_found, do: @method_not_found

  @spec invalid_params :: integer()
  def invalid_params, do: @invalid_params

  @spec internal_error :: integer()
  def internal_error, do: @internal_error
end
