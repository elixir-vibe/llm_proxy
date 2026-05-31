defmodule LLMProxy.HTTP.RouteSpec do
  @moduledoc false

  @type route :: {String.t(), module()}

  @core_routes [
    {"/feedback", LLMProxy.HTTP.Routes.Feedback},
    {"/v1/feedback", LLMProxy.HTTP.Routes.Feedback},
    {"/v1/models", LLMProxy.HTTP.Routes.Models},
    {"/models", LLMProxy.HTTP.Routes.Models},
    {"/v1/chat", LLMProxy.HTTP.Routes.Chat},
    {"/chat", LLMProxy.HTTP.Routes.Chat},
    {"/v1/messages", LLMProxy.HTTP.Routes.Messages},
    {"/v1/responses", LLMProxy.HTTP.Routes.Responses},
    {"/v1/moderations", LLMProxy.HTTP.Routes.Moderations},
    {"/moderations", LLMProxy.HTTP.Routes.Moderations}
  ]

  @admin_routes [
    {"/keys", LLMProxy.HTTP.Routes.Keys},
    {"/tokens", LLMProxy.HTTP.Routes.Tokens},
    {"/stats", LLMProxy.HTTP.Routes.Stats}
  ]

  @setup_routes [
    {"/setup", LLMProxy.HTTP.Routes.Setup}
  ]

  @spec core_routes() :: [route()]
  def core_routes, do: @core_routes

  @spec admin_routes() :: [route()]
  def admin_routes, do: @admin_routes

  @spec setup_routes() :: [route()]
  def setup_routes, do: @setup_routes

  @spec routes(keyword()) :: [route()]
  def routes(opts \\ []) do
    []
    |> add_routes(@core_routes, Keyword.get(opts, :core, true))
    |> add_routes(@admin_routes, Keyword.get(opts, :admin, true))
    |> add_routes(@setup_routes, Keyword.get(opts, :setup, false))
  end

  defp add_routes(routes, _additional, false), do: routes
  defp add_routes(routes, additional, true), do: routes ++ additional
end
